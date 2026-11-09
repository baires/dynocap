import Foundation

/// CLI ↔ daemon frames. One request per connection.
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
    case result(Data)
    case stdout(Data)
    case stderr(Data)
    case exit(code: Int32, signal: Int32)
    case error(String)
}

public enum ControlType {
    public static let run: UInt8 = 1
    public static let exec: UInt8 = 2
    public static let ps: UInt8 = 3
    public static let destroy: UInt8 = 4
    public static let shutdown: UInt8 = 5
    public static let ping: UInt8 = 6
    public static let result: UInt8 = 16
    public static let stdout: UInt8 = 17
    public static let stderr: UInt8 = 18
    public static let exit: UInt8 = 19
    public static let error: UInt8 = 20
}

public enum ControlCodec {
    public static func encode(_ message: ControlMessage) throws -> Data {
        let payload: Data
        let type: UInt8
        switch message {
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

    public init(name: String, phase: String) {
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
