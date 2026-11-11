import Foundation

/// The public CLI contract is deliberately independent of daemon serialization.
private struct SandboxListItem: Encodable {
    let entry: ManagedEntry

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, kind, phase, runtime, network, sandboxExpiresAtUnix, resultExpiresAtUnix, resultDirectory
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(entry.id, forKey: .id)
        try values.encode(entry.name, forKey: .name)
        try values.encode(entry.kind, forKey: .kind)
        try values.encode(entry.phase, forKey: .phase)
        try values.encode(entry.runtime, forKey: .runtime)
        try values.encode(entry.network?.rawValue, forKey: .network)
        try values.encode(entry.sandboxExpiresAtUnix, forKey: .sandboxExpiresAtUnix)
        try values.encode(entry.resultExpiresAtUnix, forKey: .resultExpiresAtUnix)
        try values.encode(entry.resultDirectory, forKey: .resultDirectory)
    }
}

private func sortedListing(_ entries: [ManagedEntry]) -> [ManagedEntry] {
    entries.sorted {
        let left = $0.name ?? $0.id
        let right = $1.name ?? $1.id
        return left == right ? $0.id < $1.id : left < right
    }
}

public func formatSandboxListJSON(_ entries: [ManagedEntry]) throws -> String {
    guard !entries.isEmpty else { return "[]\n" }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(sortedListing(entries).map { SandboxListItem(entry: $0) })
    return (String(data: data, encoding: .utf8) ?? "[]") + "\n"
}

private func listingDeadline(_ deadline: Int64?, now: Int64) -> String {
    guard let deadline else { return "-" }
    let seconds = max(0, deadline - now)
    let remaining: String
    switch seconds {
    case 0: remaining = "expired"
    case 1..<60: remaining = "\(seconds)s left"
    case 60..<3600: remaining = "\(seconds / 60)m left"
    case 3600..<86400: remaining = "\(seconds / 3600)h left"
    default: remaining = "\(seconds / 86400)d left"
    }
    return remaining
}

/// Prevent record strings (including paths) from injecting terminal controls or extra rows.
private func listingCell(_ value: String) -> String {
    String(value.map { $0.isWhitespace || $0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ? " " : $0 })
}

public func formatSandboxList(_ entries: [ManagedEntry], now: Int64, width: Int = 120) -> String {
    guard !entries.isEmpty else { return "No sandboxes or retained results.\n" }
    let headers = ["NAME/ID", "PHASE", "RUNTIME", "NETWORK", "TTL", "RETENTION", "RESULT"]
    let rows = sortedListing(entries).map { entry in
        [
            entry.name ?? entry.id, entry.phase, entry.runtime, entry.network?.rawValue ?? "unknown",
            listingDeadline(entry.sandboxExpiresAtUnix, now: now), listingDeadline(entry.resultExpiresAtUnix, now: now),
            entry.resultDirectory ?? "-",
        ].map(listingCell)
    }
    let widths = headers.indices.map { column in
        ([headers] + rows).map { $0[column].count }.max() ?? 0
    }
    if widths.reduce(0, +) + (headers.count - 1) * 2 <= width {
        return ([headers] + rows).map { row in
            row.enumerated().map { column, value in
                column == headers.count - 1 ? value : value.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }.joined(separator: "\n") + "\n"
    }
    // A labeled layout preserves full identifiers and paths when columns cannot fit.
    let limit = max(1, width)
    return rows.map { row in
        zip(headers, row).map { label, value in
            var text = "\(label): \(value)"
            var lines: [String] = []
            while !text.isEmpty {
                lines.append(String(text.prefix(limit)))
                text = String(text.dropFirst(limit))
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }.joined(separator: "\n\n") + "\n"
}
