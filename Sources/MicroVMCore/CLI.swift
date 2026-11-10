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

public enum CLICommand: Equatable {
    case help
    case version
    case daemon
    case ps
    case run(RunRequest)
    case exec(ExecCommand)
    case destroy(String)
    case task(TaskCommand)
    case runtimePrepare(RuntimePreparation)
}

public struct CLIInvocation: Equatable {
    public var home: URL?
    public var command: CLICommand

    public init(home: URL?, command: CLICommand) {
        self.home = home
        self.command = command
    }
}

public let helpText = """
    microvm \(MicroVMInfo.version) — local Linux microVMs on macOS

    USAGE
      microvm run --name <name> [--cpus N] [--memory MB] [--ttl SEC] [--network none|nat|filtered] [--boot-timeout SEC]
      microvm exec <name> [--timeout SEC] [--cwd DIR] [--env KEY=VAL] -- <command> [args...]
      microvm runtime prepare [REPO] [--runtime node:22]
      microvm task start PATH|URL [--runtime node:22] [--network none|nat|filtered] [--ttl SEC] [--ref NAME]
                    [--git-token-env VAR] [--ssh-key PATH]
      microvm task exec ID -- COMMAND [ARGS...]
      microvm task finish ID
      microvm ps
      microvm destroy <name>
      microvm daemon
      microvm version

    EXAMPLES
      microvm run --name demo --cpus 2 --memory 1024
      microvm exec demo -- uname -a
      microvm exec demo -- sh -c 'echo hello'
      microvm ps
      microvm destroy demo

    Images are built with scripts/fetch-image.sh and stored under $MICROVM_HOME
    (default ~/.microvm). The CLI starts a per-user daemon if one is not running.
    Network defaults to none (no virtual NIC). nat explicitly enables unrestricted outbound access.
    filtered allows HTTPS only to registry.npmjs.org and, for a repository URL, that URL's host.
    A repository URL is cloned inside the guest and requires nat or filtered.
    --git-token-env or --ssh-key is held for that guest fetch and is not imported.
    An ssh URL requires nat.
    TTL defaults to 1800 seconds, including boot; allowed range is 1–86400, with no unlimited mode.
    VMs do not outlive that daemon; the next command reaps leftover records.

    """

public func parseCommand(_ args: [String]) throws -> CLIInvocation {
    var rest = Array(args.dropFirst())
    var home: String?
    while let flag = rest.first, flag.hasPrefix("-"), flag != "--" {
        switch flag {
        case "--help", "-h":
            return CLIInvocation(home: nil, command: .help)
        case "--version":
            return CLIInvocation(home: nil, command: .version)
        case "--home":
            rest.removeFirst()
            guard let value = rest.first, !value.hasPrefix("-") else {
                throw MicroVMError("--home requires a path")
            }
            home = value
            rest.removeFirst()
        default:
            throw MicroVMError("unknown flag \(flag)")
        }
    }
    let homeURL = home.map { URL(fileURLWithPath: $0) }
    guard let sub = rest.first else {
        return CLIInvocation(home: homeURL, command: .help)
    }
    rest.removeFirst()
    switch sub {
    case "runtime":
        guard rest.first == "prepare" else { throw MicroVMError("usage: microvm runtime prepare [REPO] [--runtime NAME:VERSION]") }
        var repo = FileManager.default.currentDirectoryPath
        var runtimes = RuntimeArtifact.defaultRuntimes
        var i = 1
        if i < rest.count && !rest[i].hasPrefix("--") {
            repo = rest[i]
            i += 1
        }
        if i < rest.count {
            guard rest.count == i + 2, rest[i] == "--runtime" else {
                throw MicroVMError("usage: microvm runtime prepare [REPO] [--runtime NAME:VERSION]")
            }
            let parts = rest[i + 1].split(separator: ":")
            guard parts.count == 2 else { throw MicroVMError("runtime must be NAME:VERSION") }
            runtimes = [RuntimeSelection(name: String(parts[0]), version: String(parts[1]))]
        }
        return CLIInvocation(home: homeURL, command: .runtimePrepare(RuntimePreparation(repo: repo, runtimes: runtimes)))
    case "task":
        return CLIInvocation(home: homeURL, command: .task(try parseTask(rest)))
    case "help", "-h", "--help":
        return CLIInvocation(home: homeURL, command: .help)
    case "version", "--version":
        return CLIInvocation(home: homeURL, command: .version)
    case "daemon":
        guard rest.isEmpty else { throw MicroVMError("daemon takes no arguments") }
        return CLIInvocation(home: homeURL, command: .daemon)
    case "ps":
        guard rest.isEmpty else { throw MicroVMError("ps takes no arguments") }
        return CLIInvocation(home: homeURL, command: .ps)
    case "destroy":
        guard rest.count == 1 else { throw MicroVMError("usage: microvm destroy <name>") }
        try validateVMName(rest[0])
        return CLIInvocation(home: homeURL, command: .destroy(rest[0]))
    case "run":
        return CLIInvocation(home: homeURL, command: .run(try parseRun(rest)))
    case "exec":
        return CLIInvocation(home: homeURL, command: .exec(try parseExec(rest)))
    default:
        throw MicroVMError("unknown command \(sub)\n\n\(helpText)")
    }
}

private func parseRun(_ args: [String]) throws -> RunRequest {
    var name: String?
    var cpus = 1
    var memory = 1024
    var ttl: Int?
    var network: NetworkMode?
    var bootTimeout = 60
    var i = 0
    while i < args.count {
        let flag = args[i]
        switch flag {
        case "--name":
            name = try takeValue(args, &i, flag)
        case "--cpus":
            cpus = try takeInt(args, &i, flag, min: 1)
        case "--memory":
            memory = try takeInt(args, &i, flag, min: 128)
        case "--ttl":
            ttl = try takeInt(args, &i, flag, min: 1)
        case "--network":
            let value = try takeValue(args, &i, flag)
            guard let mode = NetworkMode(rawValue: value) else { throw MicroVMError("network must be none, nat, or filtered") }
            network = mode
        case "--boot-timeout":
            bootTimeout = try takeInt(args, &i, flag, min: 1)
        default:
            throw MicroVMError("unknown flag \(flag)")
        }
    }
    guard let name else { throw MicroVMError("run requires --name") }
    try validateVMName(name)
    _ = try IsolationPolicy.ttl(ttl)
    return RunRequest(name: name, cpus: cpus, memoryMB: memory, ttlSeconds: ttl, bootTimeoutSeconds: bootTimeout, network: network)
}

private func parseExec(_ args: [String]) throws -> ExecCommand {
    var name: String?
    var timeout = 60
    var cwd = ""
    var env: [String] = []
    var argv: [String] = []
    var i = 0
    while i < args.count {
        let arg = args[i]
        if arg == "--" {
            argv = Array(args[(i + 1)...])
            break
        }
        if arg.hasPrefix("--") {
            switch arg {
            case "--timeout":
                timeout = try takeInt(args, &i, arg, min: 1)
            case "--cwd":
                cwd = try takeValue(args, &i, arg)
            case "--env":
                let entry = try takeValue(args, &i, arg)
                guard GuestProtocol.validEnv(entry) else {
                    throw MicroVMError("--env expects KEY=VAL, got \(entry)")
                }
                env.append(entry)
            default:
                throw MicroVMError("unknown flag \(arg)")
            }
            continue
        }
        if name == nil {
            name = arg
            i += 1
            continue
        }
        argv = Array(args[i...])
        break
    }
    guard let name else { throw MicroVMError("usage: microvm exec <name> -- <command>") }
    try validateVMName(name)
    guard !argv.isEmpty, !argv[0].isEmpty else {
        throw MicroVMError("exec requires a command. Example: microvm exec \(name) -- uname -a")
    }
    return ExecCommand(name: name, argv: argv, env: env, cwd: cwd, timeoutSeconds: timeout)
}

private func takeValue(_ args: [String], _ index: inout Int, _ flag: String) throws -> String {
    index += 1
    guard index < args.count else { throw MicroVMError("\(flag) requires a value") }
    let value = args[index]
    index += 1
    return value
}

private func takeInt(_ args: [String], _ index: inout Int, _ flag: String, min: Int) throws -> Int {
    let raw = try takeValue(args, &index, flag)
    guard let value = Int(raw), value >= min else {
        throw MicroVMError("\(flag) expects an integer >= \(min)")
    }
    return value
}

private func parseTask(_ args: [String]) throws -> TaskCommand {
    guard let op = args.first else {
        throw MicroVMError("usage: microvm task start PATH|URL [--network none|nat|filtered] | finish ID | exec ID -- COMMAND")
    }
    if op == "start", args.count >= 2 {
        var cmd = TaskCommand(op: "start")
        if isRepositoryArgument(args[1]) {
            cmd.repositoryUrl = args[1]
        } else {
            cmd.projectPath = URL(fileURLWithPath: args[1]).path
        }
        var i = 2
        while i < args.count {
            guard i + 1 < args.count else { throw MicroVMError("missing task option value") }
            let value = args[i + 1]
            switch args[i] {
            case "--network":
                guard let network = NetworkMode(rawValue: value) else { throw MicroVMError("network must be none, nat, or filtered") }
                cmd.network = network
            case "--ttl":
                guard let ttl = Int(value) else { throw MicroVMError("invalid TTL") }
                cmd.ttlSeconds = ttl
            case "--runtime":
                let parts = value.split(separator: ":")
                guard parts.count == 2 else { throw MicroVMError("runtime must be NAME:VERSION") }
                cmd.runtimes = [RuntimeSelection(name: String(parts[0]), version: String(parts[1]))]
            case "--ref":
                cmd.ref = value
            case "--ssh-key":
                cmd.sshKeyPath = value
            case "--git-token-env":
                guard let token = ProcessInfo.processInfo.environment[value], !token.isEmpty else {
                    throw MicroVMError("\(value) is empty")
                }
                cmd.gitToken = token
            default: throw MicroVMError("unknown task option")
            }
            i += 2
        }
        return cmd
    }
    if op == "finish", args.count == 2 {
        var cmd = TaskCommand(op: op)
        cmd.id = args[1]
        return cmd
    }
    if op == "exec", args.count >= 4, args[2] == "--" {
        var cmd = TaskCommand(op: op)
        cmd.id = args[1]
        cmd.argv = Array(args.dropFirst(3))
        return cmd
    }
    throw MicroVMError("invalid task command")
}
