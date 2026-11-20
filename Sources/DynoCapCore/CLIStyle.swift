import Foundation

/// Presentation for DynoCap-owned output. Decide separately for each destination stream.
public struct CLIStyle {
    public enum Tone: String {
        case heading = "1"
        case muted = "2"
        case accent = "36"
        case success = "32"
        case warning = "33"
        case error = "31"
    }

    public static let plain = CLIStyle(isTerminal: false, environment: [:])
    public let interactive: Bool
    public let enabled: Bool

    public init(isTerminal: Bool, environment: [String: String], output: CLIOutput = .human, noColor: Bool = false) {
        interactive = isTerminal && output == .human && environment["TERM"] != "dumb"
        enabled = interactive && !noColor && environment["NO_COLOR"] == nil
    }

    public func paint(_ text: String, _ tone: Tone) -> String {
        guard enabled, !text.isEmpty else { return text }
        return "\u{1B}[\(tone.rawValue)m\(text)\u{1B}[0m"
    }

    public func result(_ title: String, body: [String] = [], tone: Tone = .heading) -> String {
        let heading = paint(title, tone)
        return ([heading] + body.map { $0.isEmpty ? "" : "  " + $0 }).joined(separator: "\n") + "\n"
    }

    public func action(_ label: String, _ value: String) -> String {
        paint(label + ":", .heading) + " " + paint(value, .accent)
    }

    public func progress(_ message: String) -> String {
        interactive ? paint("›", .accent) + " " + message : message
    }

    public func phase(_ value: String, uppercase: Bool = false) -> String {
        let text = uppercase ? value.uppercased() : value
        switch value {
        case "running", "completed", "ok", "fixed": return paint(text, .success)
        case "booting", "stopping", "warning", "skipped": return paint(text, .warning)
        case "failed", "error": return paint(text, .error)
        case "stopped", "-": return paint(text, .muted)
        default: return text
        }
    }

    func label(_ line: String) -> String {
        guard enabled, let colon = line.firstIndex(of: ":") else { return line }
        let label = String(line[...colon])
        let value = String(line[line.index(after: colon)...])
        switch label {
        case "Next:", "Apply:": return action(String(label.dropLast()), String(value.dropFirst()))
        case "Phase:", "Sandbox phase:":
            return paint(label, .heading) + " " + phase(String(value.dropFirst()))
        case "TTL:" where value.hasPrefix(" expired"): return paint(label, .heading) + paint(value, .warning)
        default: return paint(label, .heading) + value
        }
    }
}

/// Colors the sanitized terminal view of a patch, retaining only the current tone across reads.
public struct DiffHighlight {
    private var atLineStart = true
    private var coloring = false
    private static let reset = Data("\u{1B}[0m".utf8)

    public init() {}

    public mutating func filter(_ data: Data) -> Data {
        var result = Data()
        var offset = data.startIndex
        while offset < data.endIndex {
            if atLineStart, let tone = Self.lineTone(data[offset]) {
                result.append(contentsOf: "\u{1B}[\(tone.rawValue)m".utf8)
                coloring = true
            }
            let newline = data[offset...].firstIndex(of: UInt8(ascii: "\n"))
            let end = newline ?? data.endIndex
            result.append(data[offset..<end])
            atLineStart = newline != nil
            if atLineStart {
                result.append(finish())
                result.append(UInt8(ascii: "\n"))
            }
            offset = newline.map { $0 + 1 } ?? end
        }
        return result
    }

    public mutating func finish() -> Data {
        guard coloring else { return Data() }
        coloring = false
        return Self.reset
    }

    private static func lineTone(_ byte: UInt8) -> CLIStyle.Tone? {
        switch byte {
        case UInt8(ascii: "+"): return .success
        case UInt8(ascii: "-"): return .error
        case UInt8(ascii: "@"): return .accent
        default: return nil
        }
    }
}
