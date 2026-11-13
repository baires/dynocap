import Foundation

struct InvocationPrefix {
    var home: String?
    var json = false
    var verbose = false
    var help = false
    var version = false
}

public func parseCommand(_ args: [String]) throws -> CLIInvocation {
    var prefix = InvocationPrefix()
    let rest = try peelLeadingGlobals(Array(args.dropFirst()), into: &prefix)
    if prefix.help {
        let positionals = rest.filter { $0 != "--" && !$0.hasPrefix("-") }
        let strict = positionals.first == "help"
        let body = strict ? Array(positionals.dropFirst()) : positionals
        return makeInvocation(prefix, .help(topic: try helpTopic(from: body, strict: strict)))
    }
    if prefix.version {
        return makeInvocation(prefix, .version)
    }
    guard let sub = rest.first else {
        if prefix.json { throw usageError("--json requires a command") }
        return makeInvocation(prefix, .help(topic: []))
    }
    let commandArgs = Array(rest.dropFirst())
    switch sub {
    case "logs":
        let command = try parseLogs(commandArgs, &prefix)
        return try finishParse(prefix, ["logs"], .logs(command))
    case "doctor":
        let request = try parseDoctor(commandArgs, &prefix)
        return try finishParse(prefix, ["doctor"], .doctor(request))
    case "ls":
        try parseLs(commandArgs, &prefix)
        return try finishParse(prefix, ["ls"], .ls)
    case "clone":
        let command = try parseClone(commandArgs, &prefix)
        return try finishParse(prefix, ["clone"], .managed(command))
    case "finish", "rm", "diff", "inspect":
        let command = try parseNamed(sub, commandArgs, &prefix)
        return try finishParse(prefix, [sub], .managed(command))
    case "runtime":
        let preparation = try parseRuntime(commandArgs, &prefix)
        return try finishParse(prefix, runtimeHelpTopic(commandArgs), .runtimePrepare(preparation))
    case "task":
        let command = try parseTask(commandArgs, &prefix)
        let path: [String]
        if prefix.help || prefix.version {
            path = taskHelpTopic(commandArgs)
        } else if case .task(let task) = command {
            path = ["task", task.op]
        } else {
            path = ["task", "exec"]
        }
        return try finishParse(prefix, path, command)
    case "help":
        let topic = try parseHelpCommand(commandArgs, &prefix)
        if prefix.version { return makeInvocation(prefix, .version) }
        if prefix.json { throw usageError("help does not support --json") }
        if prefix.help && topic.isEmpty { return makeInvocation(prefix, .help(topic: ["help"])) }
        return makeInvocation(prefix, .help(topic: topic))
    case "version":
        try parseEmpty("version", commandArgs, &prefix)
        return try finishParse(prefix, ["version"], .version)
    case "daemon":
        try parseEmpty("daemon", commandArgs, &prefix)
        return try finishParse(prefix, ["daemon"], .daemon)
    case "ps":
        try parseEmpty("ps", commandArgs, &prefix)
        return try finishParse(prefix, ["ps"], .ps)
    case "destroy":
        let command = try parseNamed("destroy", commandArgs, &prefix)
        return try finishParse(prefix, ["destroy"], .destroy(command))
    case "run":
        let request = try parseRun(commandArgs, &prefix)
        return try finishParse(prefix, ["run"], .run(request))
    case "exec":
        let command = try parseExec(commandArgs, &prefix)
        return try finishParse(prefix, ["exec"], .exec(command))
    case "shell":
        let command = try parseShell(commandArgs, &prefix)
        return try finishParse(prefix, ["shell"], .shell(command))
    default:
        throw usageError("unknown command \(sub)")
    }
}

func makeInvocation(_ prefix: InvocationPrefix, _ command: CLICommand) -> CLIInvocation {
    CLIInvocation(
        home: prefix.home.map { URL(fileURLWithPath: $0) },
        command: command,
        output: prefix.json ? .json : .human,
        verbose: prefix.verbose
    )
}

func finishParse(_ prefix: InvocationPrefix, _ path: [String], _ command: CLICommand) throws -> CLIInvocation {
    if prefix.help { return makeInvocation(prefix, .help(topic: path)) }
    if prefix.version { return makeInvocation(prefix, .version) }
    if prefix.json && cliSpec(path)?.allowsJSON != true {
        throw usageError("\(path.joined(separator: " ")) does not support --json")
    }
    return makeInvocation(prefix, command)
}

func taskHelpTopic(_ args: [String]) -> [String] {
    let positionals = args.filter { $0 != "--" && !$0.hasPrefix("-") }
    if let op = positionals.first, ["start", "exec", "finish"].contains(op) {
        return ["task", op]
    }
    return ["task"]
}

func runtimeHelpTopic(_ args: [String]) -> [String] {
    let positionals = args.filter { $0 != "--" && !$0.hasPrefix("-") }
    if positionals.first == "prepare" { return ["runtime", "prepare"] }
    return ["runtime"]
}

enum OptionToken {
    case positional(String)
    case flag(String, inline: String?)
    case separator
}

struct OptionReader {
    var args: [String]
    var index = 0

    mutating func next() throws -> OptionToken? {
        guard index < args.count else { return nil }
        let token = args[index]
        if token == "--" {
            index += 1
            return .separator
        }
        if let parts = try flagParts(token) {
            index += 1
            return .flag(parts.name, inline: parts.inline)
        }
        index += 1
        return .positional(token)
    }

    mutating func value(_ flag: String, _ inline: String?) throws -> String {
        if let inline { return inline }
        guard index < args.count else { throw usageError("\(flag) requires a value") }
        let token = args[index]
        if token == "--" || (token.hasPrefix("-") && token != "-") {
            throw usageError("\(flag) requires a value")
        }
        index += 1
        return token
    }

    func remaining() -> [String] { Array(args[index...]) }
}

func flagParts(_ token: String) throws -> (name: String, inline: String?)? {
    guard token.hasPrefix("-"), token != "-", token != "--" else { return nil }
    guard token.hasPrefix("--"), let eq = token.firstIndex(of: "=") else { return (token, nil) }
    let name = String(token[..<eq])
    guard name.hasPrefix("--"), name.count > 2 else { throw usageError("unknown flag \(token)") }
    return (name, String(token[token.index(after: eq)...]))
}

func isGlobalFlag(_ name: String) -> Bool {
    ["--help", "-h", "--version", "--verbose", "--json", "--home"].contains(name)
}

func peelLeadingGlobals(_ tokens: [String], into prefix: inout InvocationPrefix) throws -> [String] {
    var index = 0
    while index < tokens.count {
        let token = tokens[index]
        if token == "--" || token == "-" { break }
        guard let (name, inline) = try flagParts(token), isGlobalFlag(name) else { break }
        index = try applyGlobal(name, inline, tokens: tokens, index: index, prefix: &prefix)
    }
    return Array(tokens[index...])
}

func applyGlobal(
    _ name: String, _ inline: String?, tokens: [String], index: Int, prefix: inout InvocationPrefix
) throws -> Int {
    switch name {
    case "--help", "-h":
        if inline != nil { throw usageError("\(name) does not take a value") }
        prefix.help = true
        return index + 1
    case "--version":
        if inline != nil { throw usageError("--version does not take a value") }
        prefix.version = true
        return index + 1
    case "--verbose":
        if inline != nil { throw usageError("--verbose does not take a value") }
        prefix.verbose = true
        return index + 1
    case "--json":
        if inline != nil { throw usageError("--json does not take a value") }
        prefix.json = true
        return index + 1
    case "--home":
        let value = try globalValue(name, inline, tokens: tokens, index: index)
        if value.value.isEmpty { throw usageError("--home requires a path") }
        prefix.home = value.value
        return value.nextIndex
    default:
        throw usageError("unknown flag \(name)")
    }
}

func globalValue(
    _ flag: String, _ inline: String?, tokens: [String], index: Int
) throws -> (value: String, nextIndex: Int) {
    if let inline { return (inline, index + 1) }
    let next = index + 1
    guard next < tokens.count, tokens[next] != "--", !(tokens[next].hasPrefix("-") && tokens[next] != "-") else {
        throw usageError("\(flag) requires a value")
    }
    return (tokens[next], next + 1)
}

func consumeGlobal(
    _ name: String, _ inline: String?, reader: inout OptionReader, prefix: inout InvocationPrefix
) throws -> Bool {
    guard isGlobalFlag(name) else { return false }
    switch name {
    case "--help", "-h":
        if inline != nil { throw usageError("\(name) does not take a value") }
        prefix.help = true
    case "--version":
        if inline != nil { throw usageError("--version does not take a value") }
        prefix.version = true
    case "--verbose":
        if inline != nil { throw usageError("--verbose does not take a value") }
        prefix.verbose = true
    case "--json":
        if inline != nil { throw usageError("--json does not take a value") }
        prefix.json = true
    case "--home":
        let value = try reader.value(name, inline)
        if value.isEmpty { throw usageError("--home requires a path") }
        prefix.home = value
    default:
        return false
    }
    return true
}

func parseLs(_ args: [String], _ prefix: inout InvocationPrefix) throws {
    var reader = OptionReader(args: args)
    while let token = try reader.next() {
        if prefix.help || prefix.version { return }
        switch token {
        case .positional(let value):
            throw usageError("unexpected argument \(value)")
        case .separator:
            throw usageError("unexpected argument --")
        case .flag(let name, let inline):
            guard try consumeGlobal(name, inline, reader: &reader, prefix: &prefix) else {
                throw usageError("unknown flag \(name)")
            }
        }
    }
}

func parseNamed(_ sub: String, _ args: [String], _ prefix: inout InvocationPrefix) throws -> TaskCommand {
    var name: String?
    var purge = false
    var force = false
    var reader = OptionReader(args: args)
    while let token = try reader.next() {
        if prefix.help || prefix.version { return TaskCommand(op: sub) }
        switch token {
        case .separator:
            throw usageError("unexpected argument --")
        case .positional(let value):
            if name == nil {
                name = value
            } else {
                throw usageError("unexpected argument \(value)")
            }
        case .flag(let flag, let inline):
            if try consumeGlobal(flag, inline, reader: &reader, prefix: &prefix) { continue }
            guard knownFlag([sub], flag) else { throw usageError("unknown flag \(flag)") }
            if flag == "--purge" {
                if inline != nil { throw usageError("--purge does not take a value") }
                purge = true
            } else if flag == "--force" {
                if inline != nil { throw usageError("--force does not take a value") }
                force = true
            } else {
                throw usageError("unknown flag \(flag)")
            }
        }
    }
    if prefix.help || prefix.version { return TaskCommand(op: sub) }
    let removal = sub == "rm" || sub == "destroy"
    guard let name else {
        throw usageError("usage: microvm \(sub) NAME_OR_ID" + (sub == "rm" ? " [--force] [--purge]" : (removal ? " [--force]" : "")))
    }
    try rethrowUsage { try validateVMName(name) }
    var command = TaskCommand(op: removal ? "remove" : sub)
    command.id = name
    if removal {
        command.purge = purge
        command.force = force
    }
    return command
}

func parseRuntime(_ args: [String], _ prefix: inout InvocationPrefix) throws -> RuntimePreparation {
    var positionals: [String] = []
    var runtime: String?
    var reader = OptionReader(args: args)
    let fallback = RuntimePreparation(repo: ".", runtimes: RuntimeArtifact.defaultRuntimes)
    while let token = try reader.next() {
        if prefix.help || prefix.version { return fallback }
        switch token {
        case .separator:
            throw usageError("unexpected argument --")
        case .positional(let value):
            positionals.append(value)
        case .flag(let name, let inline):
            if try consumeGlobal(name, inline, reader: &reader, prefix: &prefix) { continue }
            guard knownFlag(["runtime", "prepare"], name) else { throw usageError("unknown flag \(name)") }
            runtime = try reader.value(name, inline)
        }
    }
    if prefix.help || prefix.version { return fallback }
    guard positionals.first == "prepare" else {
        throw usageError("usage: microvm runtime prepare [REPO] [--runtime NAME:VERSION]")
    }
    if positionals.count > 2 { throw usageError("unexpected argument \(positionals[2])") }
    let repo = positionals.count == 2 ? positionals[1] : FileManager.default.currentDirectoryPath
    return RuntimePreparation(repo: repo, runtimes: try runtimeSelections(runtime))
}

func parseHelpCommand(_ args: [String], _ prefix: inout InvocationPrefix) throws -> [String] {
    var positionals: [String] = []
    var reader = OptionReader(args: args)
    while let token = try reader.next() {
        switch token {
        case .separator:
            throw usageError("unexpected argument --")
        case .positional(let value):
            positionals.append(value)
        case .flag(let name, let inline):
            if try consumeGlobal(name, inline, reader: &reader, prefix: &prefix) { continue }
            throw usageError("unknown flag \(name)")
        }
    }
    if prefix.version { return [] }
    return try helpTopic(from: positionals, strict: true)
}

func parseEmpty(_ command: String, _ args: [String], _ prefix: inout InvocationPrefix) throws {
    var reader = OptionReader(args: args)
    while let token = try reader.next() {
        if prefix.help || prefix.version { return }
        switch token {
        case .positional(let value):
            throw usageError("\(command) does not take arguments, got \(value)")
        case .separator:
            throw usageError("unexpected argument --")
        case .flag(let name, let inline):
            guard try consumeGlobal(name, inline, reader: &reader, prefix: &prefix) else {
                throw usageError("unknown flag \(name)")
            }
        }
    }
}

func parseDoctor(_ args: [String], _ prefix: inout InvocationPrefix) throws -> DoctorRequest {
    var request = DoctorRequest()
    var reader = OptionReader(args: args)
    while let token = try reader.next() {
        if prefix.help || prefix.version { return DoctorRequest() }
        switch token {
        case .positional(let value):
            guard request.project == nil else { throw usageError("unexpected argument \(value)") }
            request.project = value
        case .separator: throw usageError("unexpected argument --")
        case .flag(let name, let inline):
            if try consumeGlobal(name, inline, reader: &reader, prefix: &prefix) { continue }
            switch name {
            case "--runtime": request.runtimes = try runtimeSelections(try reader.value(name, inline))
            case "--fix":
                guard inline == nil else { throw usageError("--fix does not take a value") }
                request.fix = true
            default: throw usageError("unknown flag \(name)")
            }
        }
    }
    return request
}

func parseLogs(_ args: [String], _ prefix: inout InvocationPrefix) throws -> LogsCommand {
    var target: String?
    var execution: Int?
    var list = false
    var reader = OptionReader(args: args)
    while let token = try reader.next() {
        if prefix.help || prefix.version { return LogsCommand(target: "help", list: false) }
        switch token {
        case .separator: throw usageError("unexpected argument --")
        case .positional(let value):
            guard target == nil else { throw usageError("unexpected argument \(value)") }
            target = value
        case .flag(let name, let inline):
            if try consumeGlobal(name, inline, reader: &reader, prefix: &prefix) { continue }
            switch name {
            case "--list":
                guard inline == nil else { throw usageError("--list does not take a value") }
                list = true
            case "--exec":
                guard execution == nil else { throw usageError("--exec specified more than once") }
                execution = try integerFlag(name, try reader.value(name, inline), min: 0)
            default: throw usageError("unknown flag \(name)")
            }
        }
    }
    if prefix.help || prefix.version { return LogsCommand(target: "help", list: false) }
    guard let target else { throw usageError("usage: microvm logs NAME_OR_ID [--list | --exec N]") }
    guard !list || execution == nil else { throw usageError("--list and --exec cannot be combined") }
    try rethrowUsage { try validateVMName(target) }
    return LogsCommand(target: target, execution: execution, list: list)
}
