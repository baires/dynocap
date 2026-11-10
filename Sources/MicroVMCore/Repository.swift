import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum TaskSource: Equatable {
    case directory(String)
    case guestClone(RepositorySource)
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
        (value.utf8.count == 40 || value.utf8.count == 64)
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }
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
        }
        guard command.network == .nat || command.network == .filtered else {
            throw MicroVMError("repository fetch requires --network nat")
        }
        // Filtered egress is TCP 443 only, so an SSH fetch cannot leave the guest on that mode.
        if key != nil && command.network != .nat {
            throw MicroVMError("an ssh repository requires --network nat")
        }
        return .guestClone(repo)
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
    return CommitID.isValid(ref) ? ref.lowercased() : ref
}

func redactSecrets(_ message: String, secrets: [String]) -> String {
    var result = message
    for secret in secrets where secret.count >= 4 {
        result = result.replacingOccurrences(of: secret, with: "<redacted>")
    }
    return result
}

enum GuestGit {
    /// One guest exec. The URL and ref are arguments. The credential is not.
    static func fetch(url: String, ref: String?) -> [String] {
        ["/usr/local/bin/microvm-agent", "fetch", "/workspace", url, ref ?? ""]
    }

    /// Token or key bytes for the one fetch exec. Callers do not store the result.
    static func secretEnv(_ repo: RepositorySource) throws -> [String] {
        if let token = repo.token, !token.isEmpty {
            let entry = "MICROVM_GIT_TOKEN=\(token)"
            guard entry.utf8.count <= 32 << 10 else { throw MicroVMError("git token is too large") }
            return [entry]
        }
        if let path = repo.sshKeyPath, !path.isEmpty {
            try validateSSHKey(path)
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
                throw MicroVMError("ssh key is not a file")
            }
            let entry = "MICROVM_SSH_KEY=\(text)"
            guard entry.utf8.count <= 32 << 10 else { throw MicroVMError("ssh key is too large") }
            return [entry]
        }
        return []
    }
}

private func validateSSHKey(_ path: String) throws {
    var info = stat()
    guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
        throw MicroVMError("ssh key is not a file")
    }
    if info.st_mode & 0o077 != 0 {
        throw MicroVMError("ssh key must be readable only by its owner")
    }
}
