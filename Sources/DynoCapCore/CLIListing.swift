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

public func formatSandboxList(
    _ entries: [ManagedEntry], now: Int64, width: Int = 120, style: CLIStyle = .plain, rawOnly: Bool = false
) -> String {
    let title = rawOnly ? "Raw sandboxes" : "Sandboxes and results"
    func render(_ lines: [String]) -> String {
        style.interactive ? style.result(title, body: lines) : lines.joined(separator: "\n") + "\n"
    }
    guard !entries.isEmpty else {
        let empty = rawOnly ? "No raw sandboxes." : "No sandboxes or retained results."
        guard style.interactive else { return empty + "\n" }
        let next = rawOnly ? "dynocap help run" : "dynocap help workflow"
        return style.result(empty, body: [style.action("Next", next)])
    }
    let availableWidth = max(1, width - (style.interactive ? 2 : 0))
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
    func styledValue(_ value: String, column: Int) -> String {
        if column == 1 { return style.phase(value) }
        if (column == 4 || column == 5) && value == "expired" { return style.paint(value, .warning) }
        return value
    }
    if widths.reduce(0, +) + (headers.count - 1) * 2 <= availableWidth {
        let lines = ([headers] + rows).enumerated().map { index, row in
            row.enumerated().map { column, value in
                let cell = index == 0 ? style.paint(value, .heading) : styledValue(value, column: column)
                let padding = column == headers.count - 1 ? 0 : max(0, widths[column] - value.count)
                return cell + String(repeating: " ", count: padding)
            }.joined(separator: "  ")
        }
        return render(lines)
    }
    // A labeled layout preserves full identifiers and paths when columns cannot fit.
    let limit = availableWidth
    let lines = rows.map { row in
        row.enumerated().map { column, value in
            let label = headers[column] + ":"
            var text = "\(label) \(value)"
            if text.count <= limit {
                return style.paint(label, .heading) + " " + styledValue(value, column: column)
            }
            var lines: [String] = []
            while !text.isEmpty {
                lines.append(String(text.prefix(limit)))
                text = String(text.dropFirst(limit))
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }.joined(separator: "\n\n")
    return render(lines.components(separatedBy: "\n"))
}
