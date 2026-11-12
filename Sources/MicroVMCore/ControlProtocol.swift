import Foundation

/// CLI ↔ daemon frames. One request per connection, except an exec that streams
/// stdin may send stdin frames until EOF, and may send signal and resize frames, while the daemon writes output.
///
///	u32 length
///	u8  type
///	payload
public enum ControlMessage: Equatable {
    case run(RunRequest)
    case exec(ExecCommand)
    case ps
    case destroy(String)
    case shutdown
    case ping
    case task(TaskCommand)
    case transfer(TransferCommand)
    case result(Data)
    case stdout(Data)
    case stderr(Data)
    case exit(code: Int32, signal: Int32)
    case error(String)
    case stdin(Data)
    case stdinEOF
    case signal(Int32)
    case resize(TerminalSize)
}

public enum ControlType {
    public static let run: UInt8 = 1
    public static let exec: UInt8 = 2
    public static let ps: UInt8 = 3
    public static let destroy: UInt8 = 4
    public static let shutdown: UInt8 = 5
    public static let ping: UInt8 = 6
    public static let task: UInt8 = 7
    public static let transfer: UInt8 = 8
    public static let result: UInt8 = 16
    public static let stdout: UInt8 = 17
    public static let stderr: UInt8 = 18
    public static let exit: UInt8 = 19
    public static let error: UInt8 = 20
    public static let stdin: UInt8 = 21
    public static let stdinEOF: UInt8 = 22
    public static let signal: UInt8 = 23
    public static let resize: UInt8 = 24
}

public enum ControlCodec {
    public static func encode(_ message: ControlMessage) throws -> Data {
        let payload: Data
        let type: UInt8
        switch message {
        case .task(let command):
            type = ControlType.task
            payload = try JSONEncoder().encode(command)
        case .transfer(let command):
            type = ControlType.transfer
            payload = try JSONEncoder().encode(command)
        case .run(let request):
            type = ControlType.run
            payload = try JSONEncoder().encode(request)
        case .exec(let command):
            type = ControlType.exec
            payload = try JSONEncoder().encode(command)
        case .ps:
            type = ControlType.ps
            payload = Data()
        case .destroy(let name):
            type = ControlType.destroy
            payload = try JSONEncoder().encode(NameBody(name: name))
        case .shutdown:
            type = ControlType.shutdown
            payload = Data()
        case .ping:
            type = ControlType.ping
            payload = Data()
        case .result(let data):
            type = ControlType.result
            payload = data
        case .stdout(let data):
            type = ControlType.stdout
            payload = data
        case .stderr(let data):
            type = ControlType.stderr
            payload = data
        case .exit(let code, let signal):
            type = ControlType.exit
            var body = Data()
            body.appendI32(code)
            body.appendI32(signal)
            payload = body
        case .error(let text):
            type = ControlType.error
            payload = Data(text.utf8)
        case .stdin(let data):
            type = ControlType.stdin
            payload = data
        case .stdinEOF:
            type = ControlType.stdinEOF
            payload = Data()
        case .signal(let signal):
            guard signal > 0, signal < 64 else { throw MicroVMError("unsupported signal \(signal)") }
            type = ControlType.signal
            var body = Data()
            body.appendI32(signal)
            payload = body
        case .resize(let size):
            type = ControlType.resize
            var body = Data()
            body.appendU16(size.rows)
            body.appendU16(size.cols)
            payload = body
        }
        var out = Data()
        out.appendU32(UInt32(1 + payload.count))
        out.append(type)
        out.append(payload)
        return out
    }

    public static func decode(_ frame: Data) throws -> ControlMessage {
        var cursor = Cursor(frame)
        let n = Int(try cursor.u32())
        guard n > 0, n <= GuestProtocol.maxFrame else { throw MicroVMError("control frame exceeds limit") }
        let body = try cursor.bytes(n)
        guard cursor.remaining == 0, !body.isEmpty else { throw MicroVMError("bad control frame") }
        let type = body[body.startIndex]
        let payload = body.dropFirst()
        switch type {
        case ControlType.task:
            return .task(try JSONDecoder().decode(TaskCommand.self, from: Data(payload)))
        case ControlType.transfer:
            return .transfer(try JSONDecoder().decode(TransferCommand.self, from: Data(payload)))
        case ControlType.run:
            return .run(try JSONDecoder().decode(RunRequest.self, from: Data(payload)))
        case ControlType.exec:
            return .exec(try JSONDecoder().decode(ExecCommand.self, from: Data(payload)))
        case ControlType.ps:
            return .ps
        case ControlType.destroy:
            return .destroy(try JSONDecoder().decode(NameBody.self, from: Data(payload)).name)
        case ControlType.shutdown:
            return .shutdown
        case ControlType.ping:
            return .ping
        case ControlType.result:
            return .result(Data(payload))
        case ControlType.stdout:
            return .stdout(Data(payload))
        case ControlType.stderr:
            return .stderr(Data(payload))
        case ControlType.exit:
            var c = Cursor(Data(payload))
            let code = try c.i32()
            let signal = try c.i32()
            try c.expectEnd()
            return .exit(code: code, signal: signal)
        case ControlType.error:
            guard let text = String(data: Data(payload), encoding: .utf8) else {
                throw MicroVMError("error frame is not utf-8")
            }
            return .error(text)
        case ControlType.stdin:
            return .stdin(Data(payload))
        case ControlType.stdinEOF:
            guard payload.isEmpty else { throw MicroVMError("stdin EOF frame is not empty") }
            return .stdinEOF
        case ControlType.signal:
            var c = Cursor(Data(payload))
            let signal = try c.i32()
            try c.expectEnd()
            guard signal > 0, signal < 64 else { throw MicroVMError("unsupported signal \(signal)") }
            return .signal(signal)
        case ControlType.resize:
            var c = Cursor(Data(payload))
            let size = TerminalSize(rows: try c.u16(), cols: try c.u16())
            try c.expectEnd()
            return .resize(size)
        default:
            throw MicroVMError("unknown control type \(type)")
        }
    }

    public static func read(_ fd: Int32) throws -> ControlMessage {
        let lenBytes = try POSIX.readFull(fd, 4)
        var cursor = Cursor(lenBytes)
        let n = Int(try cursor.u32())
        guard n > 0, n <= GuestProtocol.maxFrame else { throw MicroVMError("control frame exceeds limit") }
        var frame = lenBytes
        frame.append(try POSIX.readFull(fd, n))
        return try decode(frame)
    }

    public static func write(_ fd: Int32, _ message: ControlMessage) throws {
        try POSIX.writeAll(fd, try encode(message))
    }
}

struct NameBody: Codable {
    var name: String
}

public struct StatusResult: Codable, Equatable {
    public var name: String
    public var phase: String

    public var network: NetworkMode?
    public var ttlSeconds: Int?

    public init(name: String, phase: String, network: NetworkMode? = nil, ttlSeconds: Int? = nil) {
        self.network = network
        self.ttlSeconds = ttlSeconds
        self.name = name
        self.phase = phase
    }
}

public struct PSResult: Codable, Equatable {
    public var vms: [VMRecord]

    public init(vms: [VMRecord]) {
        self.vms = vms
    }
}

public struct OKResult: Codable, Equatable {
    public var ok: Bool

    public init(ok: Bool) {
        self.ok = ok
    }
}

public struct ExecOutcome: Equatable {
    public var code: Int32
    public var signal: Int32
    public var stdout: Data
    public var stderr: Data

    public init(code: Int32, signal: Int32, stdout: Data, stderr: Data) {
        self.code = code
        self.signal = signal
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct PolicyCapabilities: Codable {
    public var ok: Bool = true
    public var isolationPolicyVersion: Int = IsolationPolicy.version
    public var executionLogsVersion: Int? = 1
    public var inspectionVersion: Int? = 1
    public var taskManagementVersion: Int? = 1
    public var taskVersion: Int? = 1
    public var transferVersion: Int? = 1
    public var execStreamVersion: Int? = 1
    public var execSignalVersion: Int? = 1
    public var execTerminalVersion: Int? = 1
}

public func validateExecTerminalCapability(_ data: Data) throws {
    guard let capability = try? JSONDecoder().decode(PolicyCapabilities.self, from: data),
        capability.execTerminalVersion == 1
    else {
        throw MicroVMError(
            "daemon cannot allocate guest terminals; rebuild and restart it",
            code: .incompatibleDaemon,
            recovery: "Rebuild microvm, stop the running daemon, and retry; or drop --tty to run without a terminal.")
    }
}

public func validateExecSignalCapability(_ data: Data) throws {
    guard let capability = try? JSONDecoder().decode(PolicyCapabilities.self, from: data),
        capability.execSignalVersion == 1
    else {
        throw MicroVMError(
            "daemon cannot forward guest signals; rebuild and restart it",
            code: .incompatibleDaemon)
    }
}

public func validateExecStreamCapability(_ data: Data) throws {
    guard let capability = try? JSONDecoder().decode(PolicyCapabilities.self, from: data),
        capability.execStreamVersion == 1
    else {
        throw MicroVMError(
            "daemon lacks exec stream v1; rebuild and restart it",
            code: .incompatibleDaemon)
    }
}

public struct TransferCommand: Codable, Equatable {
    public var name: String
    public var direction: String
    public var localPath: String
    public var guestPath: String
    public var requireOffline: Bool?
    public init(name: String, direction: String, localPath: String, guestPath: String, requireOffline: Bool? = nil) {
        self.name = name
        self.direction = direction
        self.localPath = localPath
        self.guestPath = guestPath
        self.requireOffline = requireOffline
    }
}
