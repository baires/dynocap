import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The running CLI. A shell PATH lookup sets argv[0] to the bare name `dynocap`, which is not a path.
public enum CLIExecutable {
    public static func current() -> URL? {
        #if canImport(Darwin)
        var size = UInt32(1024)
        var buffer = [Int8](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&buffer, &size) != 0 {
            buffer = [Int8](repeating: 0, count: Int(size))
            guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().standardizedFileURL
        #else
        let link = "/proc/self/exe"
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link) else { return nil }
        let path = target.hasPrefix("/")
            ? target
            : URL(fileURLWithPath: link).deletingLastPathComponent().appendingPathComponent(target).path
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        #endif
    }

    /// Keep an explicit path, including one that does not exist yet. A bare command name means this process.
    public static func resolve(argument: String) -> URL {
        let candidate = URL(fileURLWithPath: argument).standardizedFileURL.resolvingSymlinksInPath()
        if argument.contains("/") || argument.hasPrefix(".") {
            return candidate
        }
        return current() ?? candidate
    }
}

public enum DynoCapErrorCode: String, Codable {
    case usage = "invalid_usage"
    case operationFailed = "operation_failed"
    case notFound = "not_found"
    case invalidPhase = "invalid_phase"
    case daemonUnavailable = "daemon_unavailable"
    case commandTimeout = "command_timeout"
    case incompatibleDaemon = "incompatible_daemon"

    public var recovery: String {
        switch self {
        case .usage: return "Run dynocap help to find the command, then dynocap COMMAND --help to check its arguments."
        case .notFound: return "Run dynocap ls to find an available sandbox name or ID."
        case .invalidPhase: return "Run dynocap ls to check the phase; create a new sandbox if it has stopped."
        case .daemonUnavailable: return "Check the selected --home and daemon.log; run dynocap daemon --home PATH to diagnose startup."
        case .commandTimeout: return "Retry with a larger --timeout while the sandbox TTL still permits it."
        case .incompatibleDaemon: return "Rebuild dynocap and manually restart the daemon with the matching binary."
        case .operationFailed: return "Check the operation's inputs and prerequisites; use --verbose for diagnostic context."
        }
    }
}

public struct DynoCapError: Error, Equatable, CustomStringConvertible, Codable {
    public var message: String
    public var exitCode: Int32
    public var code: DynoCapErrorCode
    public var recovery: String

    public init(_ message: String, exitCode: Int32 = 1, code: DynoCapErrorCode? = nil, recovery: String? = nil) {
        self.message = message
        self.exitCode = exitCode
        self.code = code ?? (exitCode == 2 ? .usage : .operationFailed)
        self.recovery = recovery ?? self.code.recovery
    }

    public var description: String { message }
}

/// Error frames remain UTF-8. New daemons carry versioned typed metadata in that payload.
func daemonErrorText(_ error: Error) -> String {
    let failure = error as? DynoCapError ?? DynoCapError("The daemon operation failed.")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(failure), let text = String(data: data, encoding: .utf8) else {
        return failure.message
    }
    return "dynocap-error-v1:" + text
}

func daemonError(_ text: String) -> DynoCapError {
    let prefix = "dynocap-error-v1:"
    if text.hasPrefix(prefix),
       let error = try? JSONDecoder().decode(DynoCapError.self, from: Data(text.dropFirst(prefix.count).utf8)) {
        return error
    }
    // Older daemons provide no reliable classification. Never infer status from prose.
    return DynoCapError(text)
}

public enum DynoCapInfo {
    public static let version = "0.1.1"
    /// Guest vsock port. The host connects; the agent listens.
    public static let guestPort: UInt32 = 5252
    public static let protocolVersion: UInt32 = 1

    public static var virtualizationAvailable: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    public static func describe() -> String {
        let vz = virtualizationAvailable ? "available" : "unavailable (requires macOS 13+)"
        return """
        dynocap \(version)
        guest-arch: \(HostArch.guest)
        virtualization: \(vz)

        """
    }
}

public enum HostArch {
    #if arch(arm64)
    public static let guest = "aarch64"
    #elseif arch(x86_64)
    public static let guest = "x86_64"
    #else
    public static let guest = "unsupported"
    #endif
}

public func unixNow() -> Int64 {
    Int64(Date().timeIntervalSince1970)
}

public func formatAge(_ seconds: Int64) -> String {
    let s = max(0, seconds)
    if s < 60 { return "\(s)s" }
    if s < 3600 {
        return String(format: "%dm%02ds", s / 60, s % 60)
    }
    let hours = s / 3600
    let mins = (s % 3600) / 60
    return String(format: "%dh%02dm", hours, mins)
}

public func tailText(_ text: String, lines: Int) -> String {
    var parts = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if parts.last == "" {
        parts.removeLast()
    }
    if parts.count <= lines { return text }
    let tail = parts.suffix(lines).joined(separator: "\n")
    return text.hasSuffix("\n") ? tail + "\n" : tail
}

public func tailFile(_ url: URL, lines: Int) -> String {
    guard let data = try? Data(contentsOf: url),
          let text = String(data: data, encoding: .utf8) else {
        return ""
    }
    return tailText(text, lines: lines)
}

public func validateVMName(_ name: String) throws {
    let scalars = Array(name.unicodeScalars)
    guard (1...63).contains(scalars.count) else {
        throw DynoCapError("VM name must be 1-63 characters: \(name)")
    }
    func ok(_ scalar: Unicode.Scalar, first: Bool) -> Bool {
        if scalar >= "0" && scalar <= "9" { return true }
        if scalar >= "a" && scalar <= "z" { return true }
        if scalar >= "A" && scalar <= "Z" { return true }
        if !first && (scalar == "-" || scalar == "_" || scalar == ".") { return true }
        return false
    }
    for (i, scalar) in scalars.enumerated() where !ok(scalar, first: i == 0) {
        throw DynoCapError("VM name \(name) must match [A-Za-z0-9][A-Za-z0-9._-]*")
    }
}

enum POSIX {
    static var pid: Int32 { getpid() }

    static func errnoString() -> String {
        guard let raw = strerror(errno) else { return "errno \(errno)" }
        return String(cString: raw)
    }

    static func socketpair() throws -> (Int32, Int32) {
        var fds = [Int32](repeating: -1, count: 2)
        let rc = fds.withUnsafeMutableBufferPointer { buf -> Int32 in
            DarwinOrGlibc.socketpair(AF_UNIX, socketStream, 0, buf.baseAddress)
        }
        guard rc == 0 else { throw DynoCapError("socketpair: \(errnoString())") }
        return (fds[0], fds[1])
    }

    static func listenUnix(_ path: String) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, socketStream, 0)
        guard fd >= 0 else { throw DynoCapError("socket: \(errnoString())") }
        var addr = try unixAddress(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            close(fd)
            throw DynoCapError("bind \(path): \(errnoString())")
        }
        guard listen(fd, 64) == 0 else {
            close(fd)
            throw DynoCapError("listen: \(errnoString())")
        }
        chmod(path, 0o600)
        return fd
    }

    static func connectUnix(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, socketStream, 0)
        guard fd >= 0 else { throw DynoCapError("socket: \(errnoString())") }
        #if os(macOS)
        // The daemon may close an exec as soon as the guest exits, while stdin or EOF is still being
        // sent. That write must fail with EPIPE rather than kill the CLI (Linux uses MSG_NOSIGNAL).
        var noSigPipe: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            close(fd)
            throw DynoCapError("socket: \(errnoString())")
        }
        #endif
        var addr = try unixAddress(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let err = errnoString()
            close(fd)
            throw DynoCapError("connect \(path): \(err)")
        }
        return fd
    }

    static func connectUnix(_ path: String, timeoutSeconds: Int) throws -> Int32 {
        let fd = socket(AF_UNIX, socketStream, 0)
        guard fd >= 0 else { throw DynoCapError("cannot create daemon probe socket") }
        var connected = false
        defer { if !connected { close(fd) } }
        #if os(macOS)
        var noSigPipe: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw DynoCapError("cannot configure daemon probe writes")
        }
        #endif
        var address = try unixAddress(path)
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw DynoCapError("cannot configure daemon probe") }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { throw DynoCapError("daemon socket is unreachable") }
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&descriptor, 1, Int32(timeoutSeconds * 1000)) > 0 else { throw DynoCapError("daemon connect deadline elapsed") }
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0, socketError == 0 else {
                throw DynoCapError("daemon socket connection failed")
            }
        }
        guard fcntl(fd, F_SETFL, flags) == 0 else { throw DynoCapError("cannot restore daemon probe flags") }
        connected = true
        return fd
    }

    static func accept(_ fd: Int32) -> Int32 {
        DarwinOrGlibc.accept(fd, nil, nil)
    }

    static func readFull(_ fd: Int32, _ count: Int) throws -> Data {
        var data = Data(count: count)
        var got = 0
        while got < count {
            let n: Int = data.withUnsafeMutableBytes { raw in
                let ptr = raw.baseAddress!.advanced(by: got)
                return DarwinOrGlibc.read(fd, ptr, count - got)
            }
            if n == 0 { throw DynoCapError("connection closed") }
            if n < 0 {
                if errno == EINTR { continue }
                throw DynoCapError("read: \(errnoString())")
            }
            got += n
        }
        return data
    }

    static func setWriteTimeout(_ fd: Int32, seconds: Int) throws {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw DynoCapError("setsockopt SO_SNDTIMEO: \(errnoString())")
        }
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws {
        if data.isEmpty { return }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off < raw.count {
                let n = send(fd, base.advanced(by: off), raw.count - off, sendFlags)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw DynoCapError("write: \(errnoString())")
                }
                if n == 0 { throw DynoCapError("short write") }
                off += n
            }
        }
    }

    static func openLock(_ path: String) throws -> Int32 {
        let fd = open(path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw DynoCapError("open \(path): \(errnoString())") }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            throw DynoCapError("another dynocap daemon holds \(path)")
        }
        return fd
    }

    static func unlock(_ fd: Int32) {
        _ = flock(fd, LOCK_UN)
    }

    /// Linux glibc imports `SOCK_STREAM` as an enum; Darwin imports it as `Int32`.
    private static var socketStream: Int32 {
        #if os(Linux)
        return Int32(SOCK_STREAM.rawValue)
        #else
        return SOCK_STREAM
        #endif
    }

    private static var sendFlags: Int32 {
        #if os(Linux)
        return Int32(MSG_NOSIGNAL)
        #else
        return 0
        #endif
    }

    private static func unixAddress(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        #if os(macOS)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= 104 else {
            throw DynoCapError("socket path is too long: \(path)")
        }
        try withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            guard let dest = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw DynoCapError("socket address is unusable")
            }
            for (i, byte) in bytes.enumerated() {
                dest[i] = byte
            }
        }
        return addr
    }
}

/// Renames that keep call sites shorter when Darwin and Glibc share a symbol
/// the Swift overlay also declares.
private enum DarwinOrGlibc {
    static func socketpair(_ domain: Int32, _ type: Int32, _ proto: Int32, _ fds: UnsafeMutablePointer<Int32>?) -> Int32 {
        #if canImport(Darwin)
        return Darwin.socketpair(domain, type, proto, fds)
        #else
        return Glibc.socketpair(domain, type, proto, fds)
        #endif
    }

    static func accept(_ fd: Int32, _ addr: UnsafeMutablePointer<sockaddr>?, _ len: UnsafeMutablePointer<socklen_t>?) -> Int32 {
        #if canImport(Darwin)
        return Darwin.accept(fd, addr, len)
        #else
        return Glibc.accept(fd, addr, len)
        #endif
    }

    static func read(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ n: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.read(fd, buf, n)
        #else
        return Glibc.read(fd, buf, n)
        #endif
    }
}
