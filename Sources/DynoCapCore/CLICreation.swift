import Foundation

/// Human progress is opt-in on task requests, using existing stderr frames.
public enum CreationStage: String {
    case checkingRuntime = "Checking the prepared runtime..."
    case importingSource = "Preparing the source workspace..."
    case creatingWorkspace = "Creating the disposable workspace disk..."
    case booting = "Booting the sandbox..."
    case waitingForNetwork = "Waiting for the selected network..."
    case populatingWorkspace = "Importing or fetching the project into the sandbox..."
    case restoringCache = "Restoring the dependency cache..."
}

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Suggested commands repeat --home only when a plain command would reach a different home.
func homeFlag(_ home: URL) -> String {
    home.standardizedFileURL == DynoCapPaths.resolve(override: nil).home.standardizedFileURL ? "" : " --home " + shellWord(home.path)
}

private func creationText(_ value: String) -> String {
    String(value.map { $0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ? " " : $0 })
}

private func managementJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (String(data: try encoder.encode(value), encoding: .utf8) ?? "") + "\n"
}

private struct CreationSource: Encodable {
    var kind: String
    var value: String
    var revision: String?
    enum CodingKeys: String, CodingKey { case kind, value, revision }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        try values.encode(value, forKey: .value)
        try values.encode(revision, forKey: .revision)
    }
}

private struct CreationResult: Encodable {
    var descriptor: TaskDescriptor
    var source: CreationSource
    var nextCommand: String
    enum CodingKeys: String, CodingKey {
        case id, name, phase, runtimes, network, source, sandboxExpiresAtUnix, resultExpiresAtUnix, onSandboxExpiration, nextCommand
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(descriptor.id, forKey: .id)
        try values.encode(descriptor.name, forKey: .name)
        try values.encode(descriptor.phase, forKey: .phase)
        try values.encode(descriptor.runtimes, forKey: .runtimes)
        try values.encode(descriptor.network.rawValue, forKey: .network)
        try values.encode(source, forKey: .source)
        try values.encode(descriptor.sandboxExpiresAtUnix, forKey: .sandboxExpiresAtUnix)
        try values.encode(descriptor.expiresAtUnix, forKey: .resultExpiresAtUnix)
        try values.encode("discard_unexported_work", forKey: .onSandboxExpiration)
        try values.encode(nextCommand, forKey: .nextCommand)
    }
}

public func formatCreationResult(
    _ descriptor: TaskDescriptor, command: TaskCommand, home: URL, output: CLIOutput, now: Int64, style: CLIStyle = .plain
) throws -> String {
    let source = CreationSource(
        kind: command.repositoryUrl == nil ? "directory" : "repository",
        value: descriptor.sourceUrl ?? command.repositoryUrl ?? command.projectPath ?? "unknown",
        revision: descriptor.sourceRevision)
    let next = "dynocap\(homeFlag(home)) exec \(shellWord(descriptor.name ?? descriptor.id)) -- pwd"
    if output == .json {
        return try managementJSON(CreationResult(descriptor: descriptor, source: source, nextCommand: next))
    }
    let runtime = descriptor.runtimes?.map { $0.name + ":" + $0.version }.joined(separator: ", ") ?? "unknown"
    let lifetime = creationLifetime(descriptor.sandboxExpiresAtUnix, now: now)
    let lines = [
        "Created sandbox: \(descriptor.name ?? descriptor.id)",
        "ID: \(descriptor.id)", "Phase: \(descriptor.phase)",
        "Source (\(source.kind)): \(source.value)", "Runtime: \(runtime)",
        "Network: \(descriptor.network.rawValue)", "TTL: \(lifetime)",
        "Expiration discards unexported workspace edits. Run dynocap finish to export work before TTL expires.",
        "Next: \(next)",
    ]
    return formatCreationSummary(lines, style: style)
}

private func creationLifetime(_ deadline: Int64?, now: Int64) -> String {
    deadline.map { deadline -> String in
        let date = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(deadline)))
        return (deadline > now ? formatAge(deadline - now) + " remaining" : "expired") + " (\(date))"
    } ?? "unknown (daemon did not report a sandbox deadline)"
}

private struct RunResult: Encodable {
    var status: StatusResult
    var nextCommand: String
    enum CodingKeys: String, CodingKey {
        case name, kind, phase, network, ttlSeconds, sandboxExpiresAtUnix, onSandboxExpiration, nextCommand
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(status.name, forKey: .name)
        try values.encode("sandbox", forKey: .kind)
        try values.encode(status.phase, forKey: .phase)
        try values.encode(status.network?.rawValue, forKey: .network)
        try values.encode(status.ttlSeconds, forKey: .ttlSeconds)
        try values.encode(status.sandboxExpiresAtUnix, forKey: .sandboxExpiresAtUnix)
        try values.encode("discard_sandbox", forKey: .onSandboxExpiration)
        try values.encode(nextCommand, forKey: .nextCommand)
    }
}

/// `run` reports a raw sandbox the way clone reports a project sandbox.
public func formatRunResult(_ status: StatusResult, home: URL, output: CLIOutput, now: Int64, style: CLIStyle = .plain) throws -> String {
    let next = "dynocap\(homeFlag(home)) exec \(shellWord(status.name)) -- uname -a"
    if output == .json {
        return try managementJSON(RunResult(status: status, nextCommand: next))
    }
    let lines = [
        "Created raw sandbox: \(status.name)", "Phase: \(status.phase)",
        "Network: \(status.network?.rawValue ?? "unknown")", "TTL: \(creationLifetime(status.sandboxExpiresAtUnix, now: now))",
        "A raw sandbox has no project result to export; expiration or removal discards everything in it.",
        "Next: \(next)",
    ]
    return formatCreationSummary(lines, style: style)
}

private struct RemovalResult: Encodable {
    var target: String
    var removed = true
    var purged: Bool
}

/// `rm` and `destroy` send the same request and print the same result.
public func formatRemovalResult(target: String, purged: Bool, output: CLIOutput, style: CLIStyle = .plain) throws -> String {
    if output == .json { return try managementJSON(RemovalResult(target: target, purged: purged)) }
    let detail = purged ? "; deleted its retained record, logs, and result" : ""
    guard style.interactive else { return creationText("removed \(target)\(detail)") + "\n" }
    return style.result(
        creationText("Removed: \(target)"),
        body: purged ? ["Deleted its retained record, logs, and result."] : [],
        tone: .success)
}

private struct VersionResult: Encodable {
    var version = DynoCapInfo.version
    var guestArch = HostArch.guest
    var virtualizationAvailable = DynoCapInfo.virtualizationAvailable
}

public func formatVersion(output: CLIOutput, style: CLIStyle = .plain) throws -> String {
    let result = VersionResult()
    if output == .json { return try managementJSON(result) }
    guard style.interactive else { return DynoCapInfo.describe() }
    let availability = result.virtualizationAvailable ? "available" : "unavailable (requires macOS 13+)"
    return style.result("dynocap \(result.version)", body: ["Guest architecture: \(result.guestArch)", "Virtualization: \(availability)"]
        .map(style.label))
}

private struct RuntimePreparationResult: Encodable {
    var runtimes: [RuntimeSelection]
    var arch: String
    var artifactDigest: String
    var directory: String
    var verified = true
    var buildLogPath: String
}

public func formatRuntimePreparationResult(
    _ artifact: RuntimeArtifact, home: URL, log: URL, output: CLIOutput, style: CLIStyle = .plain
) throws -> String {
    let result = RuntimePreparationResult(
        runtimes: artifact.runtimes, arch: artifact.arch, artifactDigest: artifact.artifactDigest,
        directory: home.appendingPathComponent("runtimes").appendingPathComponent(artifact.artifactDigest).path, buildLogPath: log.path)
    if output == .json { return try managementJSON(result) }
    let lines = [
        "Runtime ready: " + artifact.runtimes.map { $0.name + ":" + $0.version }.joined(separator: ", "),
        "Architecture: \(result.arch)", "Verified artifact: \(result.artifactDigest)", "Directory: \(result.directory)",
        "Build log: \(log.path)", "Next: dynocap help clone",
    ]
    return formatCreationSummary(lines, style: style)
}

private func formatCreationSummary(_ lines: [String], style: CLIStyle) -> String {
    let safe = lines.map(creationText)
    guard style.interactive, let title = safe.first else { return safe.joined(separator: "\n") + "\n" }
    return style.result(title, body: safe.dropFirst().map(style.label), tone: .success)
}

/// Capture both companion streams in one file, so they cannot corrupt CLI success or JSON errors.
public func buildRuntime(
    _ preparation: RuntimePreparation, paths: DynoCapPaths, executable: URL, onLog: (URL) -> Void = { _ in }
) throws -> URL {
    let fm = FileManager.default
    guard fm.isExecutableFile(atPath: executable.path) else {
        throw DynoCapError(
            "runtime preparation companion not found: \(executable.path)",
            recovery: "Run ./scripts/build-macos.sh from the dynocap repository to install the signed CLI and its companions.")
    }
    let log = paths.home.appendingPathComponent("runtime-preparation-\(UUID().uuidString.lowercased()).log")
    guard fm.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
        throw DynoCapError("cannot create runtime preparation log at \(log.path)")
    }
    onLog(log)
    let handle = try FileHandle(forWritingTo: log)
    defer { try? handle.close() }
    let process = Process()
    process.executableURL = executable
    process.arguments = [
        preparation.repo, paths.home.path, HostArch.guest,
        String(data: try JSONEncoder().encode(preparation.runtimes), encoding: .utf8) ?? "",
    ]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = handle
    process.standardError = handle
    do { try process.run() } catch {
        throw DynoCapError("could not start runtime preparation companion", recovery: "Check \(executable.path) and rebuild with ./scripts/build-macos.sh.")
    }
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        throw DynoCapError(
            "runtime preparation failed (status \(process.terminationStatus)); see \(log.path)",
            recovery: "Read the build log, fix the reported prerequisite or download failure, then retry dynocap runtime prepare.")
    }
    return log
}
