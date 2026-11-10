import Foundation

enum TaskSource: Equatable {
    case directory(String)
    case guestClone(RepositorySource)
    case hostFetch(RepositorySource)
}

struct RepositorySource: Equatable {
    var url: String
    var ref: String?
    var token: String?
    var sshKeyPath: String?
    var kind: String
}

enum CommitID {
    static func isValid(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.allSatisfy(\.isHexDigit)
    }
}

func isRepositoryArgument(_ value: String) -> Bool {
    value.contains("://") || value.hasPrefix("git@") || value.hasPrefix("ext::")
}

enum TaskSourceResolver {
    static func resolve(_ command: TaskCommand) throws -> TaskSource {
        let hasPath = !(command.projectPath ?? "").isEmpty
        let hasURL = !(command.repositoryUrl ?? "").isEmpty
        if hasPath && hasURL { throw MicroVMError("task start accepts a directory or a repository URL") }
        if !hasURL {
            guard let source = command.projectPath, !source.isEmpty else { throw MicroVMError("projectPath is required") }
            return .directory(source)
        }
        let parsed = try parseRepositoryURL(command.repositoryUrl ?? "")
        let ref = try command.ref.map(parseRef)
        let token = (command.gitToken?.isEmpty == false) ? command.gitToken : nil
        let key = (command.sshKeyPath?.isEmpty == false) ? command.sshKeyPath : nil
        if token != nil && key != nil { throw MicroVMError("pass a token or an ssh key, not both") }
        if token != nil && parsed.kind != "https" { throw MicroVMError("an https token cannot fetch an ssh repository") }
        if key != nil && parsed.kind != "ssh" { throw MicroVMError("an ssh key cannot fetch an https repository") }
        let repo = RepositorySource(url: parsed.url, ref: ref, token: token, sshKeyPath: key, kind: parsed.kind)
        if token == nil && key == nil {
            guard parsed.kind == "https" else { throw MicroVMError("ssh repository requires --ssh-key") }
            guard command.network == .nat else { throw MicroVMError("repository fetch requires --network nat") }
            return .guestClone(repo)
        }
        return .hostFetch(repo)
    }
}

private struct ParsedRepositoryURL {
    var url: String
    var kind: String
}

private func parseRepositoryURL(_ raw: String) throws -> ParsedRepositoryURL {
    if raw.isEmpty || raw.contains(" ") || raw.contains("\n") || raw.contains("\r") || raw.contains("\t") || raw.contains("\\") {
        throw MicroVMError("repository URL is invalid")
    }
    if raw.hasPrefix("ext::") || raw.hasPrefix("http://") || raw.hasPrefix("file://") {
        throw MicroVMError("repository URL must be https or ssh")
    }
    if raw.hasPrefix("https://") {
        if raw.contains("@") { throw MicroVMError("repository URL must not include credentials") }
        let rest = raw.dropFirst("https://".count)
        guard let slash = rest.firstIndex(of: "/"), slash != rest.startIndex, rest.index(after: slash) != rest.endIndex else {
            throw MicroVMError("repository URL is invalid")
        }
        return ParsedRepositoryURL(url: raw, kind: "https")
    }
    if raw.hasPrefix("ssh://") {
        if sshHasCredential(raw) { throw MicroVMError("repository URL must not include credentials") }
        return ParsedRepositoryURL(url: raw, kind: "ssh")
    }
    if raw.hasPrefix("git@") {
        let rest = raw.dropFirst("git@".count)
        guard let colon = rest.firstIndex(of: ":"), colon != rest.startIndex, rest.index(after: colon) != rest.endIndex else {
            throw MicroVMError("repository URL is invalid")
        }
        if rest[..<colon].contains("@") { throw MicroVMError("repository URL is invalid") }
        return ParsedRepositoryURL(url: raw, kind: "ssh")
    }
    throw MicroVMError("repository URL must be https or ssh")
}

private func sshHasCredential(_ raw: String) -> Bool {
    let rest = raw.dropFirst("ssh://".count)
    let host = rest.split(separator: "/", maxSplits: 1).first ?? ""
    guard let at = host.firstIndex(of: "@") else { return false }
    let user = host[..<at]
    return user != "git" || user.contains(":")
}

private func parseRef(_ ref: String) throws -> String {
    let ok = ref.unicodeScalars.allSatisfy { scalar in
        CharacterSet.alphanumerics.contains(scalar) || CharacterSet(charactersIn: "._/-").contains(scalar)
    }
    if ref.isEmpty || ref.hasPrefix("-") || ref.hasPrefix("/") || ref.hasSuffix("/") || ref.contains("..") || !ok {
        throw MicroVMError("ref must be a branch or tag name")
    }
    return ref
}

func redactSecrets(_ message: String, secrets: [String]) -> String {
    var result = message
    for secret in secrets where secret.count >= 4 {
        result = result.replacingOccurrences(of: secret, with: "<redacted>")
    }
    return result
}

enum RepositoryFetch {
    static func checkout(_ repo: RepositorySource, dest: URL) throws -> String {
        var env = ProcessInfo.processInfo.environment
        env["MICROVM_GIT_TOKEN"] = repo.token ?? ""
        env["MICROVM_SSH_KEY"] = repo.sshKeyPath ?? ""
        let data: Data
        do {
            data = try HostTree.run("microvm-workspace", ["fetch", dest.path, repo.url, repo.ref ?? ""], environment: env)
        } catch let error as MicroVMError {
            throw MicroVMError(redactSecrets(error.message, secrets: [repo.token ?? "", repo.sshKeyPath ?? ""]))
        } catch {
            throw MicroVMError(redactSecrets(String(describing: error), secrets: [repo.token ?? "", repo.sshKeyPath ?? ""]))
        }
        let revision = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard CommitID.isValid(revision) else { throw MicroVMError("git did not return a commit") }
        return revision
    }
}

enum GuestGit {
    private static let lock = ["GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null", "GIT_TERMINAL_PROMPT=0"]
    private static let config = [
        "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=", "-c", "credential.helper=",
        "-c", "protocol.file.allow=never", "-c", "protocol.ext.allow=never", "-c", "init.templateDir=",
    ]

    static func clone(url: String, ref: String?) -> [String] {
        var args = ["env"] + lock + ["git"] + config + ["clone", "--no-recurse-submodules"]
        if let ref { args += ["--branch", ref] }
        args += ["--", url, "/workspace"]
        return args
    }

    static func revision() -> [String] {
        ["env"] + lock + ["git", "-C", "/workspace", "-c", "core.hooksPath=/dev/null", "rev-parse", "HEAD"]
    }

    static func detach(_ revision: String) -> [String] {
        ["env"] + lock + ["git", "-C", "/workspace", "-c", "core.hooksPath=/dev/null", "checkout", "--detach", revision]
    }

    static func configure(url: String) -> [[String]] {
        [
            ["env"] + lock + ["git", "-C", "/workspace", "-c", "core.hooksPath=/dev/null", "config", "--local", "core.hooksPath", "/dev/null"],
            ["env"] + lock + ["git", "-C", "/workspace", "-c", "core.hooksPath=/dev/null", "remote", "set-url", "origin", url],
        ]
    }
}
