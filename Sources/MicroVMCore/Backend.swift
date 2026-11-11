import Foundation

public struct BootRequest: Equatable {
    public var runtimeDirectory: URL?
    public var workspaceDisk: URL?
    public var name: String
    public var cpus: Int
    public var memoryMB: Int
    public var kernelURL: URL
    public var initrdURL: URL
    public var consoleLogURL: URL
    public var generation: UUID
    public var network: NetworkMode
    public var filteredRepositoryHost: String?
    public var bootTimeoutSeconds: Int

    public init(
        name: String,
        cpus: Int,
        memoryMB: Int,
        kernelURL: URL,
        initrdURL: URL,
        consoleLogURL: URL,
        bootTimeoutSeconds: Int,
        network: NetworkMode = .none,
        generation: UUID = UUID(),
        runtimeDirectory: URL? = nil, workspaceDisk: URL? = nil,
        filteredRepositoryHost: String? = nil
    ) {
        self.runtimeDirectory = runtimeDirectory
        self.workspaceDisk = workspaceDisk
        self.name = name
        self.cpus = cpus
        self.memoryMB = memoryMB
        self.kernelURL = kernelURL
        self.initrdURL = initrdURL
        self.consoleLogURL = consoleLogURL
        self.generation = generation
        self.network = network
        self.filteredRepositoryHost = filteredRepositoryHost
        self.bootTimeoutSeconds = bootTimeoutSeconds
    }
}

public struct ExecRequest: Equatable {
    public var stdinFile: URL?
    /// When true, the backend leaves guest stdin open until writeStdin/closeStdin.
    public var streamStdin = false
    public var name: String
    public var id: UInt32
    public var argv: [String]
    public var env: [String]
    public var cwd: String
    public var timeoutSeconds: Int

    public init(name: String, id: UInt32, argv: [String], env: [String], cwd: String, timeoutSeconds: Int) {
        self.name = name
        self.id = id
        self.argv = argv
        self.env = env
        self.cwd = cwd
        self.timeoutSeconds = timeoutSeconds
    }
}

public enum ExecEvent: Equatable {
    case stdout(Data)
    case stderr(Data)
    case finished(code: Int32, signal: Int32)
    case failed(String)
}

public protocol VMBackend: AnyObject {
    var onGuestExit: ((String, UUID, String?) -> Void)? { get set }
    func boot(_ request: BootRequest, completion: @escaping (Result<Void, Error>) -> Void)
    func exec(_ request: ExecRequest, emit: @escaping (ExecEvent) -> Void)
    func writeStdin(name: String, id: UInt32, data: Data) throws
    func closeStdin(name: String, id: UInt32) throws
    func cancelExec(name: String, id: UInt32)
    func destroy(name: String, completion: @escaping (Result<Void, Error>) -> Void)
}

extension VMBackend {
    public func writeStdin(name: String, id: UInt32, data: Data) throws {}
    public func closeStdin(name: String, id: UInt32) throws {}
}

/// Used on non-macOS builds and in tests that only exercise the control plane.
public final class UnsupportedBackend: VMBackend {
    public var onGuestExit: ((String, UUID, String?) -> Void)?

    public init() {}

    public func boot(_ request: BootRequest, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(
            .failure(
                MicroVMError(
                    "Linux microVMs require macOS 13 or later and the com.apple.security.virtualization entitlement. This host cannot boot \(request.name)."
                )))
    }

    public func exec(_ request: ExecRequest, emit: @escaping (ExecEvent) -> Void) {
        emit(.failed("VM \(request.name) has no virtualization backend on this host"))
    }

    public func cancelExec(name: String, id: UInt32) {}

    public func destroy(name: String, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }
}
