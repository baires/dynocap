import Foundation

/// Host/guest exec stream. Bytes match guest/internal/protocol and testdata/protocol-vectors.json.
public enum GuestMessage: Equatable {
    case hello(version: UInt32, agent: String)
    case exec(ExecStart)
    case stdin(id: UInt32, data: Data)
    case stdinEOF(id: UInt32)
    case kill(id: UInt32)
    case shutdown
    case started(id: UInt32)
    case stdout(id: UInt32, data: Data)
    case stderr(id: UInt32, data: Data)
    case exit(id: UInt32, code: Int32, signal: Int32)
    case error(id: UInt32, message: String)

    public var id: UInt32? {
        switch self {
        case .exec(let start): return start.id
        case .stdin(let id, _), .stdinEOF(let id), .kill(let id), .started(let id),
             .stdout(let id, _), .stderr(let id, _), .exit(let id, _, _), .error(let id, _):
            return id
        case .hello, .shutdown:
            return nil
        }
    }
}

public struct ExecStart: Equatable {
    public var id: UInt32
    public var timeoutMS: UInt32
    public var argv: [String]
    public var env: [String]
    public var cwd: String

    public init(id: UInt32, timeoutMS: UInt32, argv: [String], env: [String], cwd: String) {
        self.id = id
        self.timeoutMS = timeoutMS
        self.argv = argv
        self.env = env
        self.cwd = cwd
    }
}

public enum GuestProtocol {
    public static let version: UInt32 = MicroVMInfo.protocolVersion
    public static let port: UInt32 = MicroVMInfo.guestPort
    public static let maxFrame = 1 << 20
    static let maxString = 32 << 10
    static let maxArgs = 256
    static let maxChunk = 256 << 10

    public static let hello: UInt8 = 0x01
    public static let exec: UInt8 = 0x02
    public static let stdin: UInt8 = 0x03
    public static let stdinEOF: UInt8 = 0x04
    public static let kill: UInt8 = 0x05
    public static let shutdown: UInt8 = 0x06
    public static let started: UInt8 = 0x10
    public static let stdout: UInt8 = 0x11
    public static let stderr: UInt8 = 0x12
    public static let exit: UInt8 = 0x13
    public static let error: UInt8 = 0x14

    public static func encodeFrame(_ message: GuestMessage) throws -> Data {
        let payload = try encode(message)
        var out = Data()
        out.appendU32(UInt32(payload.count))
        out.append(payload)
        return out
    }

    public static func decodeFrame(_ frame: Data) throws -> GuestMessage {
        var cursor = Cursor(frame)
        let n = Int(try cursor.u32())
        let payload = try cursor.bytes(n)
        guard cursor.remaining == 0 else { throw MicroVMError("trailing bytes after guest frame") }
        guard payload.count == n else { throw MicroVMError("short guest frame") }
        return try decode(payload)
    }

    public static func encode(_ message: GuestMessage) throws -> Data {
        var out = Data()
        switch message {
        case .hello(let version, let agent):
            guard version != 0 else { throw MicroVMError("hello version is required") }
            out.append(hello)
            out.appendU32(version)
            try out.appendString16(agent)
        case .exec(let start):
            guard let argv0 = start.argv.first, !argv0.isEmpty else {
                throw MicroVMError("argv is empty")
            }
            guard start.argv.count <= maxArgs, start.env.count <= maxArgs else {
                throw MicroVMError("too many strings")
            }
            for entry in start.env where !validEnv(entry) {
                throw MicroVMError("env entry must be KEY=VAL")
            }
            out.append(exec)
            out.appendU32(start.id)
            out.appendU32(start.timeoutMS)
            try out.appendStrings(start.argv)
            try out.appendStrings(start.env)
            try out.appendString16(start.cwd)
        case .stdin(let id, let data):
            guard data.count <= maxChunk else { throw MicroVMError("chunk too large") }
            out.append(stdin)
            out.appendU32(id)
            out.appendU32(UInt32(data.count))
            out.append(data)
        case .stdinEOF(let id):
            out.append(stdinEOF)
            out.appendU32(id)
        case .kill(let id):
            out.append(kill)
            out.appendU32(id)
        case .shutdown:
            out.append(shutdown)
        case .started(let id):
            out.append(started)
            out.appendU32(id)
        case .stdout(let id, let data), .stderr(let id, let data):
            guard data.count <= maxChunk else { throw MicroVMError("chunk too large") }
            out.append(message.isStdout ? stdout : stderr)
            out.appendU32(id)
            out.appendU32(UInt32(data.count))
            out.append(data)
        case .exit(let id, let code, let signal):
            out.append(exit)
            out.appendU32(id)
            out.appendI32(code)
            out.appendI32(signal)
        case .error(let id, let text):
            out.append(error)
            out.appendU32(id)
            try out.appendString16(text)
        }
        return out
    }

    public static func decode(_ payload: Data) throws -> GuestMessage {
        var c = Cursor(payload)
        let type = try c.u8()
        switch type {
        case hello:
            let version = try c.u32()
            let agent = try c.string16()
            try c.expectEnd()
            return .hello(version: version, agent: agent)
        case exec:
            let id = try c.u32()
            let timeout = try c.u32()
            let argv = try c.strings(max: maxArgs)
            let env = try c.strings(max: maxArgs)
            let cwd = try c.string16()
            try c.expectEnd()
            guard let argv0 = argv.first, !argv0.isEmpty else { throw MicroVMError("argv is empty") }
            for entry in env where !validEnv(entry) {
                throw MicroVMError("env entry must be KEY=VAL")
            }
            return .exec(ExecStart(id: id, timeoutMS: timeout, argv: argv, env: env, cwd: cwd))
        case stdin, stdout, stderr:
            let id = try c.u32()
            let n = Int(try c.u32())
            guard n <= maxChunk else { throw MicroVMError("chunk too large") }
            let data = try c.bytes(n)
            try c.expectEnd()
            if type == stdin { return .stdin(id: id, data: data) }
            if type == stdout { return .stdout(id: id, data: data) }
            return .stderr(id: id, data: data)
        case stdinEOF:
            let id = try c.u32()
            try c.expectEnd()
            return .stdinEOF(id: id)
        case kill:
            let id = try c.u32()
            try c.expectEnd()
            return .kill(id: id)
        case shutdown:
            try c.expectEnd()
            return .shutdown
        case started:
            let id = try c.u32()
            try c.expectEnd()
            return .started(id: id)
        case exit:
            let id = try c.u32()
            let code = try c.i32()
            let signal = try c.i32()
            try c.expectEnd()
            return .exit(id: id, code: code, signal: signal)
        case error:
            let id = try c.u32()
            let text = try c.string16()
            try c.expectEnd()
            return .error(id: id, message: text)
        default:
            throw MicroVMError("unknown guest frame type \(type)")
        }
    }

    static func validEnv(_ entry: String) -> Bool {
        guard let idx = entry.firstIndex(of: "="), idx != entry.startIndex else { return false }
        return true
    }
}

private extension GuestMessage {
    var isStdout: Bool {
        if case .stdout = self { return true }
        return false
    }
}

struct Cursor {
    var data: Data
    var index = 0
    init(_ data: Data) { self.data = data }
    var remaining: Int { data.count - index }

    mutating func u8() throws -> UInt8 {
        guard index < data.count else { throw MicroVMError("short frame") }
        let value = data[index]
        index += 1
        return value
    }

    mutating func u16() throws -> UInt16 {
        let b = try bytes(2)
        return (UInt16(b[0]) << 8) | UInt16(b[1])
    }

    mutating func u32() throws -> UInt32 {
        let b = try bytes(4)
        return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }

    mutating func i32() throws -> Int32 {
        Int32(bitPattern: try u32())
    }

    mutating func bytes(_ n: Int) throws -> Data {
        guard n >= 0, index + n <= data.count else { throw MicroVMError("short frame") }
        let slice = data.subdata(in: index..<(index + n))
        index += n
        return slice
    }

    mutating func string16() throws -> String {
        let n = Int(try u16())
        guard n <= GuestProtocol.maxString else { throw MicroVMError("string too long") }
        let raw = try bytes(n)
        guard let text = String(data: raw, encoding: .utf8) else { throw MicroVMError("payload is not utf-8") }
        return text
    }

    mutating func strings(max: Int) throws -> [String] {
        let n = Int(try u16())
        guard n <= max else { throw MicroVMError("too many strings") }
        var out: [String] = []
        out.reserveCapacity(n)
        for _ in 0..<n {
            out.append(try string16())
        }
        return out
    }

    func expectEnd() throws {
        guard remaining == 0 else { throw MicroVMError("trailing bytes") }
    }
}

extension Data {
    mutating func appendU32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendI32(_ value: Int32) {
        appendU32(UInt32(bitPattern: value))
    }

    mutating func appendString16(_ text: String) throws {
        let raw = Data(text.utf8)
        guard raw.count <= GuestProtocol.maxString else { throw MicroVMError("string too long") }
        append(UInt8((raw.count >> 8) & 0xff))
        append(UInt8(raw.count & 0xff))
        append(raw)
    }

    mutating func appendStrings(_ values: [String]) throws {
        guard values.count <= 0xffff else { throw MicroVMError("too many strings") }
        append(UInt8((values.count >> 8) & 0xff))
        append(UInt8(values.count & 0xff))
        for value in values {
            try appendString16(value)
        }
    }
}
