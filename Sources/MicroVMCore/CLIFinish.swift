import Foundation

private struct FinishResult: Encodable {
    var id: String
    var name: String?
    var phase: String
    var sandbox = "stopped"
    var resultDirectory: String?
    var patch: String?
    var resultExpiresAtUnix: Int64
    var priorCommandFailure: Bool
    var baseline = "imported_checkout_including_uncommitted_changes"
    var hostCheckout = "unchanged"
    var applyCommand: String
}

public func formatFinishResult(_ descriptor: TaskDescriptor, output: CLIOutput, now: Int64) throws -> String {
    let directory = descriptor.resultDirectory
    let patch = directory.map { URL(fileURLWithPath: $0).appendingPathComponent("changes.patch").path }
    let quoted = patch.map(shellQuote) ?? shellQuote("unavailable")
    let apply = "git apply --check \(quoted) && git apply \(quoted)"
    let priorCommandFailure = descriptor.phase == "failed"
    if output == .json {
        let result = FinishResult(
            id: descriptor.id, name: descriptor.name, phase: descriptor.phase, resultDirectory: directory, patch: patch,
            resultExpiresAtUnix: descriptor.expiresAtUnix, priorCommandFailure: priorCommandFailure, applyCommand: apply)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (String(data: try encoder.encode(result), encoding: .utf8) ?? "") + "\n"
    }
    let formatter = ISO8601DateFormatter()
    let date = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(descriptor.expiresAtUnix)))
    let remaining = descriptor.expiresAtUnix > now ? finishRetention(descriptor.expiresAtUnix - now) : "expired"
    var lines = [
        "Stopped sandbox: \(finishText(descriptor.name ?? descriptor.id))",
        "ID: \(finishText(descriptor.id))",
        "Phase: \(finishText(descriptor.phase))",
        "Patch: \(finishText(patch ?? "unavailable"))",
        "Result directory: \(finishText(directory ?? "unavailable"))",
        "Result retention: \(remaining) (\(date))",
        "The patch applies only to a checkout matching the imported baseline, including uncommitted changes that were imported. "
            + "microvm does not modify the host checkout.",
        "Apply: \(apply)",
    ]
    if priorCommandFailure {
        lines.insert(
            "Guest commands failed before export. The result was still exported; this is not an export or teardown failure.",
            at: 3)
    }
    return lines.joined(separator: "\n") + "\n"
}

private func finishRetention(_ seconds: Int64) -> String {
    switch max(0, seconds) {
    case 0: return "expired"
    case 1..<60: return "\(seconds)s left"
    case 60..<3600: return "\(seconds / 60)m left"
    case 3600..<86400: return "\(seconds / 3600)h left"
    default: return "\(seconds / 86400)d left"
    }
}

private func finishText(_ value: String) -> String {
    String(value.map { $0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ? " " : $0 })
}
