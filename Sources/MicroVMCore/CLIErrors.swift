import Foundation

private struct CLIErrorResult: Encodable {
    var error: MicroVMError
    var diagnostics: Diagnostics?

    struct Diagnostics: Encodable {
        var operation: String
        var source: String
    }
}

/// Detect formatting intent on malformed input using the same argument boundaries as the parser.
/// Invalid content-command formats still produce a usage error; guest arguments cannot opt in.
struct CLIFailureOptions {
    var json: Bool
    var verbose: Bool
    var secrets: [String]
}

func cliFailureOptions(_ args: [String]) -> CLIFailureOptions {
    var secrets: [String] = []
    let environment = ProcessInfo.processInfo.environment
    for (key, value) in environment where key.range(of: "(?i)token|password|secret|credential|api.?key", options: .regularExpression) != nil {
        if !value.isEmpty { secrets.append(value) }
    }
    var index = 1
    var json = false
    var verbose = false
    var command: String?
    var positionals = 0
    var taskOperation: String?
    let valued = ["--home", "--env", "--git-token-env", "--ssh-key", "--runtime", "--network", "--ttl", "--timeout",
                  "--boot-timeout", "--cwd", "--cpus", "--memory", "--ref", "--name", "--exec"]
    while index < args.count {
        let token = args[index]
        if token == "--" { break }
        let parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let flag = parts[0]
        if flag == "--json", parts.count == 1 { json = true }
        if flag == "--verbose", parts.count == 1 { verbose = true }
        if valued.contains(flag) {
            let value = parts.count == 2 ? parts[1] : (index + 1 < args.count ? args[index + 1] : "")
            if flag == "--env" {
                if let separator = value.firstIndex(of: "=") { secrets.append(String(value[value.index(after: separator)...])) }
            }
            if flag == "--git-token-env", let secret = environment[value] { secrets.append(secret) }
            index += parts.count == 2 ? 1 : 2
            continue
        }
        if !token.hasPrefix("-") {
            if command == nil {
                command = token
            } else {
                positionals += 1
                if command == "task", positionals == 1 { taskOperation = token }
                // exec also permits the guest command without an explicit separator.
                if command == "exec", positionals == 2 { break }
                if command == "task", taskOperation == "exec", positionals == 3 { break }
            }
        }
        index += 1
    }
    return CLIFailureOptions(json: json, verbose: verbose, secrets: secrets)
}

func safeDiagnostic(_ text: String, secrets: [String]) -> String {
    var result = text
    for secret in secrets.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
        result = result.replacingOccurrences(of: secret, with: "<redacted>")
    }
    // URL userinfo and common key/value diagnostics must never reveal credentials.
    let secretField = #"(?i)(["']?[a-z0-9_]*(?:token|password|secret|credential|api[_-]?key|authorization)[a-z0-9_]*["']?\s*[:=]\s*)"#
        + #"(?:"[^"]*"|'[^']*'|[^\s,;]+)"#
    for (pattern, replacement) in [
        (#"(?i)([a-z][a-z0-9+.-]*://)[^/\s@]+@"#, "$1<redacted>@"),
        (#"(?i)\b(Bearer|Basic)\s+[^\s,;]+"#, "$1 <redacted>"),
        (secretField, "$1<redacted>"),
        (#"(?s)-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----"#, "<redacted>"),
    ] {
        result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
    return String(result.map { $0.isNewline || $0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ? " " : $0 })
}

public func formatCLIFailure(
    _ error: Error, invocation: CLIInvocation? = nil, arguments: [String]
) -> (text: String, exitCode: Int32) {
    let options = cliFailureOptions(arguments)
    let json = invocation?.output == .json || (invocation == nil && options.json)
    let verbose = invocation?.verbose ?? options.verbose
    var failure = error as? MicroVMError ?? MicroVMError("The host operation could not be completed.")
    // Only the explicitly typed command deadline may use 124 for a host failure.
    failure.exitCode = failure.code == .usage ? 2 : (failure.code == .commandTimeout ? 124 : 1)
    failure.message = safeDiagnostic(failure.message, secrets: options.secrets)
    failure.recovery = safeDiagnostic(failure.recovery, secrets: options.secrets)
    let operation = invocation.map { cliOperation($0.command) } ?? "arguments"
    let hostError = error as NSError
    let source = error is MicroVMError ? "microvm" : safeDiagnostic(
        "\(hostError.domain):\(hostError.code)", secrets: options.secrets)
    if json {
        let result = CLIErrorResult(
            error: failure, diagnostics: verbose ? .init(operation: operation, source: source) : nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(result), let text = String(data: data, encoding: .utf8) {
            return (text + "\n", failure.exitCode)
        }
    }
    var text = "microvm: \(operation): \(failure.message)\nNext: \(failure.recovery)\n"
    if verbose {
        text += "microvm: code=\(failure.code.rawValue) operation=\(operation) source=\(source); exit \(failure.exitCode)\n"
    }
    return (text, failure.exitCode)
}

private func cliOperation(_ command: CLICommand) -> String {
    switch command {
    case .ls: return "ls"
    case .doctor: return "doctor"
    case .logs: return "logs"
    case .ps: return "ps"
    case .run: return "run"
    case .exec: return "exec"
    case .shell: return "shell"
    case .destroy: return "destroy"
    case .managed(let command): return ["start": "clone", "remove": "rm"][command.op] ?? command.op
    case .task(let command): return "task \(command.op)"
    case .runtimePrepare: return "runtime prepare"
    case .daemon: return "daemon"
    case .help: return "help"
    case .version: return "version"
    }
}
