import Foundation

public struct RunRequest: Codable, Equatable {
    public var runtimeDirectory: String?
    public var workspaceDisk: String?
    public var name: String
    public var cpus: Int
    public var memoryMB: Int
    public var ttlSeconds: Int?
    public var bootTimeoutSeconds: Int
    public var network: NetworkMode?
    public var filteredRepositoryHost: String?

    public init(name: String, cpus: Int, memoryMB: Int, ttlSeconds: Int?, bootTimeoutSeconds: Int, network: NetworkMode? = nil) {
        self.name = name
        self.cpus = cpus
        self.memoryMB = memoryMB
        self.ttlSeconds = ttlSeconds
        self.bootTimeoutSeconds = bootTimeoutSeconds
        self.network = network
    }
}

public struct ExecCommand: Codable, Equatable {
    public var name: String
    public var argv: [String]
    public var env: [String]
    public var cwd: String
    public var timeoutSeconds: Int
    public var requireOffline: Bool?
    public var permitFiltered: Bool?

    public init(
        name: String, argv: [String], env: [String], cwd: String, timeoutSeconds: Int,
        requireOffline: Bool? = nil, permitFiltered: Bool? = nil
    ) {
        self.name = name
        self.argv = argv
        self.env = env
        self.cwd = cwd
        self.timeoutSeconds = timeoutSeconds
        self.requireOffline = requireOffline
        self.permitFiltered = permitFiltered
    }
}

public enum CLIOutput: Equatable {
    case human
    case json
}

public enum CLICommand: Equatable {
    case help(topic: [String])
    case version
    case daemon
    case ps
    case ls
    case managed(TaskCommand)
    case run(RunRequest)
    case exec(ExecCommand)
    case destroy(String)
    case task(TaskCommand)
    case runtimePrepare(RuntimePreparation)
}

public struct CLIInvocation: Equatable {
    public var home: URL?
    public var output: CLIOutput
    public var verbose: Bool
    public var command: CLICommand

    public init(home: URL?, command: CLICommand, output: CLIOutput = .human, verbose: Bool = false) {
        self.home = home
        self.output = output
        self.verbose = verbose
        self.command = command
    }
}
