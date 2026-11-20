import Foundation

private struct InspectionJSON: Encodable {
    var value: SandboxInspection
    enum CodingKeys: String, CodingKey {
        case id, name, kind, phase, source, runtime, runtimes, runtimeDigest, network, createdAtUnix
        case sandboxPhase, sandboxExpiresAtUnix, resultExpiresAtUnix, result, unexportedWork, message
    }
    enum SourceKeys: String, CodingKey { case kind, value, revision }
    enum ResultKeys: String, CodingKey { case directory, available, patchPath, reviewPath, changesPath }

    func encode(to encoder: Encoder) throws {
        var output = encoder.container(keyedBy: CodingKeys.self)
        try output.encode(value.id, forKey: .id)
        try output.encode(value.name, forKey: .name)
        try output.encode(value.kind, forKey: .kind)
        try output.encode(value.phase, forKey: .phase)
        try output.encode(value.runtime, forKey: .runtime)
        try output.encode(value.runtimes, forKey: .runtimes)
        try output.encode(value.runtimeDigest, forKey: .runtimeDigest)
        try output.encode(value.network, forKey: .network)
        try output.encode(value.createdAtUnix, forKey: .createdAtUnix)
        try output.encode(value.sandboxPhase, forKey: .sandboxPhase)
        try output.encode(value.sandboxExpiresAtUnix, forKey: .sandboxExpiresAtUnix)
        try output.encode(value.resultExpiresAtUnix, forKey: .resultExpiresAtUnix)
        try output.encode(value.unexportedWork, forKey: .unexportedWork)
        try output.encode(value.message, forKey: .message)
        if let source = value.source {
            var fields = output.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
            try fields.encode(source.kind, forKey: .kind)
            try fields.encode(source.value, forKey: .value)
            try fields.encode(source.revision, forKey: .revision)
        } else { try output.encodeNil(forKey: .source) }
        if let result = value.result {
            var fields = output.nestedContainer(keyedBy: ResultKeys.self, forKey: .result)
            try fields.encode(result.directory, forKey: .directory)
            try fields.encode(result.available, forKey: .available)
            try fields.encode(result.patchPath, forKey: .patchPath)
            try fields.encode(result.reviewPath, forKey: .reviewPath)
            try fields.encode(result.changesPath, forKey: .changesPath)
        } else { try output.encodeNil(forKey: .result) }
    }
}

public func formatInspection(
    _ inspection: SandboxInspection, output: CLIOutput, now: Int64, arguments: [String] = [], style: CLIStyle = .plain
) throws -> String {
    var value = inspection
    let secrets = cliFailureOptions(arguments).secrets
    func safe(_ text: String) -> String { safeDiagnostic(text, secrets: secrets) }
    value.message = value.message.map(safe)
    if var source = value.source { source.value = safe(source.value); value.source = source }
    if output == .json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (String(data: try encoder.encode(InspectionJSON(value: value)), encoding: .utf8) ?? "") + "\n"
    }
    func date(_ timestamp: Int64) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }
    let live = value.sandboxPhase.map { ["booting", "running", "stopping"].contains($0) } ?? false
    let sandboxDeadline = value.sandboxExpiresAtUnix.map { deadline in
        date(deadline) + (live ? (deadline > now ? " (\(formatAge(deadline - now)) remaining)" : " (expired)") : " (original deadline)")
    } ?? "unavailable"
    let retention = value.resultExpiresAtUnix.map { deadline in
        date(deadline) + (deadline > now ? " (\(formatAge(deadline - now)) remaining; from task creation)" : " (expired)")
    } ?? "not applicable"
    var lines = [
        "Name: \(value.name ?? "unavailable")", "ID: \(value.id)", "Kind: \(value.kind)", "Phase: \(value.phase)",
        "Source: \(value.source.map { "\($0.kind): \($0.value)" } ?? "unavailable")",
        "Source revision: \(value.source?.revision ?? "unavailable")", "Runtime: \(value.runtime)",
        "Runtime digest: \(value.runtimeDigest ?? "unavailable")", "Network: \(value.network?.rawValue ?? "unknown")",
        "Created: \(date(value.createdAtUnix))", "Sandbox phase: \(value.sandboxPhase ?? "unavailable")",
        "Sandbox deadline: \(sandboxDeadline)", "Retention expires: \(retention)",
    ]
    if let result = value.result {
        lines += [
            "Result: \(result.directory) (\(result.available ? "directory available" : "directory unavailable"))",
            "Patch: \(result.patchPath ?? "unavailable")", "Review: \(result.reviewPath ?? "unavailable")",
            "Changes: \(result.changesPath ?? "unavailable")",
        ]
    } else { lines.append(value.kind == "sandbox" ? "Result: not applicable" : "Result: not exported") }
    switch value.unexportedWork {
    case "discarded": lines.append("Unexported workspace edits were discarded; inspection cannot recover or resume them.")
    case "unavailable_cleanup_pending": lines.append("Unexported edits are unavailable through finish; sandbox cleanup is still pending.")
    case "not_exported": lines.append("Unexported workspace edits will be discarded when the sandbox expires.")
    default: break
    }
    if let message = value.message { lines.append("Message: \(message)") }
    let details = lines.map(safe)
    guard style.interactive else { return details.joined(separator: "\n") + "\n" }
    return style.result(safe("Sandbox: \(value.name ?? value.id)"), body: details.dropFirst().map(style.label))
}
