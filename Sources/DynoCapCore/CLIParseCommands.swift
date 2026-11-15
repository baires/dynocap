import Foundation

func parseClone(_ args: [String], _ prefix: inout InvocationPrefix) throws -> TaskCommand {
    var command = TaskCommand(op: "start")
    var positionals: [String] = []
    var reader = OptionReader(args: args)
    while let token = try reader.next() {
        if prefix.help || prefix.version { return command }
        switch token {
        case .separator:
            throw usageError("unexpected argument --")
        case .positional(let value):
            positionals.append(value)
        case .flag(let name, let inline):
            if try consumeGlobal(name, inline, reader: &reader, prefix: &prefix) { continue }
            guard knownFlag(["clone"], name) else { throw usageError("unknown flag \(name)") }
            try applyStartFlag(&command, name, try reader.value(name, inline), allowName: false)
        }
    }
    if prefix.help || prefix.version { return command }
    guard positionals.count >= 2 else { throw usageError("usage: dynocap clone SOURCE NAME [OPTIONS]") }
    if positionals.count > 2 { throw usageError("unexpected argument \(positionals[2])") }
    try rethrowUsage { try validateTaskName(positionals[1]) }
    command.name = positionals[1]
    if isRepositoryArgument(positionals[0]) {
        command.repositoryUrl = positionals[0]
    } else {
        command.projectPath = URL(fileURLWithPath: positionals[0]).path
    }
    return command
}

func parseTask(_ args: [String], _ prefix: inout InvocationPrefix) throws -> CLICommand {
    var index = 0
    while index < args.count {
        let token = args[index]
        if token == "--" || token == "-" { break }
        guard let (name, inline) = try flagParts(token), isGlobalFlag(name) else { break }
        index = try applyGlobal(name, inline, tokens: args, index: index, prefix: &prefix)
        if prefix.help || prefix.version { return .task(TaskCommand(op: "start")) }
    }
    guard index < args.count else {
        throw usageError("usage: dynocap task start PATH|URL | finish ID | exec ID -- COMMAND")
    }
    let op = args[index]
    let tail = Array(args[(index + 1)...])
    switch op {
    case "start":
        return .task(try parseTaskStart(tail, &prefix))
    case "finish":
        return .task(try parseTaskFinish(tail, &prefix))
    case "exec":
        return .taskExec(try parseExec(tail, &prefix, path: ["task", "exec"]))
    default:
        if op.hasPrefix("-") { throw usageError("unknown flag \(op)") }
        throw usageError("unknown command task \(op)")
    }
}

func parseTaskStart(_ args: [String], _ prefix: inout InvocationPrefix) throws -> TaskCommand {
    var command = TaskCommand(op: "start")
    var positionals: [String] = []
    var reader = OptionReader(args: args)
    while let token = try reader.next() {
        if prefix.help || prefix.version { return command }
        switch token {
        case .separator:
            throw usageError("unexpected argument --")
        case .positional(let value):
            positionals.append(value)
        case .flag(let name, let inline):
            if try consumeGlobal(name, inline, reader: &reader, prefix: &prefix) { continue }
            guard knownFlag(["task", "start"], name) else { throw usageError("unknown flag \(name)") }
            try applyStartFlag(&command, name, try reader.value(name, inline), allowName: true)
        }
    }
    if prefix.help || prefix.version { return command }
    guard let source = positionals.first else { throw usageError("usage: dynocap task start PATH|URL [OPTIONS]") }
    if positionals.count > 1 { throw usageError("unexpected argument \(positionals[1])") }
    if isRepositoryArgument(source) {
        command.repositoryUrl = source
    } else {
        command.projectPath = URL(fileURLWithPath: source).path
    }
    return command
}

func parseTaskFinish(_ args: [String], _ prefix: inout InvocationPrefix) throws -> TaskCommand {
    var id: String?
    var reader = OptionReader(args: args)
    while let token = try reader.next() {
        if prefix.help || prefix.version { return TaskCommand(op: "finish") }
        switch token {
        case .separator:
            throw usageError("unexpected argument --")
        case .positional(let value):
            if id == nil {
                id = value
            } else {
                throw usageError("unexpected argument \(value)")
            }
        case .flag(let name, let inline):
            if try consumeGlobal(name, inline, reader: &reader, prefix: &prefix) { continue }
            throw usageError("unknown flag \(name)")
        }
    }
    if prefix.help || prefix.version { return TaskCommand(op: "finish") }
    guard let id else { throw usageError("usage: dynocap task finish ID") }
    var command = TaskCommand(op: "finish")
    command.id = id
    return command
}

func parseRun(_ args: [String], _ prefix: inout InvocationPrefix) throws -> RunRequest {
    var name: String?
    var cpus = 1
    var memory = 1024
    var ttl: Int?
    var network: NetworkMode?
    var bootTimeout = 60
    var reader = OptionReader(args: args)
    while let token = try reader.next() {
        if prefix.help || prefix.version { break }
        switch token {
        case .separator:
            throw usageError("unexpected argument --")
        case .positional(let value):
            throw usageError("unexpected argument \(value)")
        case .flag(let flag, let inline):
            if try consumeGlobal(flag, inline, reader: &reader, prefix: &prefix) { continue }
            guard knownFlag(["run"], flag) else { throw usageError("unknown flag \(flag)") }
            let raw = try reader.value(flag, inline)
            switch flag {
            case "--name":
                name = raw
            case "--cpus":
                cpus = try integerFlag(flag, raw, min: 1)
            case "--memory":
                memory = try integerFlag(flag, raw, min: 128)
            case "--ttl":
                ttl = try ttlValue(raw)
            case "--network":
                network = try networkMode(raw)
            case "--boot-timeout":
                bootTimeout = try integerFlag(flag, raw, min: 1)
            default:
                throw usageError("unknown flag \(flag)")
            }
        }
    }
    if prefix.help || prefix.version {
        return RunRequest(name: "", cpus: cpus, memoryMB: memory, ttlSeconds: ttl, bootTimeoutSeconds: bootTimeout)
    }
    guard let name else { throw usageError("run requires --name") }
    try rethrowUsage { try validateVMName(name) }
    try rethrowUsage { _ = try IsolationPolicy.ttl(ttl) }
    return RunRequest(
        name: name, cpus: cpus, memoryMB: memory, ttlSeconds: ttl, bootTimeoutSeconds: bootTimeout, network: network
    )
}

/// `exec` and `task exec` share this parser, so their flags, defaults, and errors cannot drift.
func parseExec(_ args: [String], _ prefix: inout InvocationPrefix, path: [String] = ["exec"]) throws -> ExecCommand {
    var name: String?
    var timeout = 60
    var cwd = ""
    var env: [String] = []
    var argv: [String] = []
    var input: String?
    var terminal = false
    var reader = OptionReader(args: args)
    while let token = try reader.next() {
        if prefix.help || prefix.version { break }
        switch token {
        case .separator:
            argv = reader.remaining()
            reader.index = reader.args.count
        case .positional(let value):
            if name == nil {
                name = value
            } else {
                argv = [value] + reader.remaining()
                reader.index = reader.args.count
            }
        case .flag(let flag, let inline):
            if try consumeGlobal(flag, inline, reader: &reader, prefix: &prefix) { continue }
            // -it and -ti are the familiar spelling of -i -t.
            if flag == "-it" || flag == "-ti" {
                if inline != nil { throw usageError("\(flag) does not take a value") }
                if input == "none" { throw usageError("--tty cannot be combined with --no-input") }
                input = "interactive"
                terminal = true
                continue
            }
            guard knownFlag(path, flag) else { throw usageError("unknown flag \(flag)") }
            switch flag {
            case "--timeout":
                timeout = try integerFlag(flag, try reader.value(flag, inline), min: 1)
            case "--cwd":
                cwd = try reader.value(flag, inline)
            case "--env":
                let entry = try reader.value(flag, inline)
                guard GuestProtocol.validEnv(entry) else { throw usageError("--env expects KEY=VAL, got \(entry)") }
                env.append(entry)
            case "-i", "--interactive":
                if inline != nil { throw usageError("\(flag) does not take a value") }
                if input == "none" { throw usageError("--interactive cannot be combined with --no-input") }
                input = "interactive"
            case "--no-input":
                if inline != nil { throw usageError("--no-input does not take a value") }
                if input == "interactive" { throw usageError("--no-input cannot be combined with --interactive") }
                if terminal { throw usageError("--no-input cannot be combined with --tty") }
                input = "none"
            case "-t", "--tty":
                if inline != nil { throw usageError("\(flag) does not take a value") }
                if input == "none" { throw usageError("--tty cannot be combined with --no-input") }
                terminal = true
            default:
                throw usageError("unknown flag \(flag)")
            }
        }
    }
    if prefix.help || prefix.version {
        return ExecCommand(name: name ?? "help", argv: ["true"], env: env, cwd: cwd, timeoutSeconds: timeout, input: input)
    }
    let usage = path.joined(separator: " ")
    guard let name else { throw usageError("usage: dynocap \(usage) NAME_OR_ID -- COMMAND") }
    try rethrowUsage { try validateVMName(name) }
    guard !argv.isEmpty, !argv[0].isEmpty else {
        throw usageError("\(usage) requires a command. Example: dynocap \(usage) \(name) -- uname -a")
    }
    var command = ExecCommand(name: name, argv: argv, env: env, cwd: cwd, timeoutSeconds: timeout, input: input)
    if terminal {
        // A terminal always carries live input. The CLI fills in the host size before sending.
        command.input = "interactive"
        command.terminal = TerminalSize(rows: 0, cols: 0)
    }
    return command
}

/// Runs root's shell from /etc/passwd when it is executable and not a refusal, otherwise /bin/sh.
/// It is not started as a login shell, so a profile cannot replace the exec environment.
let guestShellArgv = [
    "/bin/sh", "-c",
    #"shell=$(awk -F: '$1 == "root" { print $7; exit }' /etc/passwd 2>/dev/null); "#
        + #"case "$shell" in */nologin | */false) shell= ;; esac; [ -x "$shell" ] || shell=/bin/sh; exec "$shell""#,
    "dynocap-shell",
]

func parseShell(_ args: [String], _ prefix: inout InvocationPrefix) throws -> ExecCommand {
    var name: String?
    var reader = OptionReader(args: args)
    while let token = try reader.next() {
        if prefix.help || prefix.version { break }
        switch token {
        case .separator:
            throw usageError("shell does not take a command; use dynocap exec -t NAME -- COMMAND")
        case .positional(let value):
            guard name == nil else {
                throw usageError("unexpected argument \(value); use dynocap exec -t NAME -- COMMAND to run a command")
            }
            name = value
        case .flag(let flag, let inline):
            if try consumeGlobal(flag, inline, reader: &reader, prefix: &prefix) { continue }
            throw usageError("unknown flag \(flag)")
        }
    }
    let target = name ?? "help"
    if !(prefix.help || prefix.version) {
        guard name != nil else { throw usageError("usage: dynocap shell NAME_OR_ID") }
        try rethrowUsage { try validateVMName(target) }
    }
    // No command deadline: leaving the shell or the sandbox TTL ends it. The CLI fills in the host size.
    var command = ExecCommand(name: target, argv: guestShellArgv, env: [], cwd: "", timeoutSeconds: 0, input: "interactive")
    command.terminal = TerminalSize(rows: 0, cols: 0)
    return command
}

func applyStartFlag(_ command: inout TaskCommand, _ flag: String, _ raw: String, allowName: Bool) throws {
    switch flag {
    case "--name":
        guard allowName else { throw usageError("unknown flag --name") }
        guard command.name == nil else { throw usageError("--name specified more than once") }
        try rethrowUsage { try validateTaskName(raw) }
        command.name = raw
    case "--cpus":
        command.cpus = try integerFlag(flag, raw, min: 1)
    case "--memory":
        command.memoryMB = try integerFlag(flag, raw, min: 128)
    case "--network":
        command.network = try networkMode(raw)
    case "--ttl":
        command.ttlSeconds = try ttlValue(raw)
    case "--runtime":
        command.runtimes = try runtimeSelections(raw)
    case "--ref":
        command.ref = raw
    case "--history":
        guard taskHistoryModes.contains(raw) else { throw usageError("history must be branches, head, or none, got \(raw)") }
        command.history = raw
    case "--ssh-key":
        command.sshKeyPath = raw
    case "--git-token-env":
        guard let token = ProcessInfo.processInfo.environment[raw], !token.isEmpty else {
            throw usageError("\(raw) is empty")
        }
        command.gitToken = token
    default:
        throw usageError("unknown flag \(flag)")
    }
}

/// Values `dynocap-workspace import-git` accepts.
let taskHistoryModes = ["branches", "head", "none"]

func integerFlag(_ flag: String, _ raw: String, min: Int) throws -> Int {
    guard let value = Int(raw), value >= min else {
        throw usageError("\(flag) expects an integer >= \(min), got \(raw)")
    }
    return value
}

func ttlValue(_ raw: String) throws -> Int {
    guard let value = Int(raw) else { throw usageError("--ttl expects an integer from 1 to 86400, got \(raw)") }
    do {
        _ = try IsolationPolicy.ttl(value)
    } catch {
        throw usageError("--ttl expects an integer from 1 to 86400, got \(raw)")
    }
    return value
}

func networkMode(_ raw: String) throws -> NetworkMode {
    guard let mode = NetworkMode(rawValue: raw) else {
        throw usageError("network must be none, nat, or filtered, got \(raw)")
    }
    return mode
}

func runtimeSelections(_ raw: String?) throws -> [RuntimeSelection] {
    guard let raw else { return RuntimeArtifact.defaultRuntimes }
    let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
        throw usageError("runtime must be NAME:VERSION, got \(raw)")
    }
    return [RuntimeSelection(name: String(parts[0]), version: String(parts[1]))]
}
