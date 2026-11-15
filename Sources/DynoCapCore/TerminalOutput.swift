import Foundation

/// Guest bytes on their way to a host terminal. A terminal acts on escape sequences:
/// it can set the clipboard (OSC 52), retitle the window, emit links, or answer a
/// query by typing into the user's shell. Output to a pipe or file is never filtered.
/// `exec -t` and `shell` are a real terminal session and stay unfiltered, like ssh.
public struct TerminalSanitizer {
    public enum Mode {
        /// Live command output and log replay: text, colors (SGR), `\r`, `\b`, and the
        /// line-erase and column moves progress bars use. Everything else is dropped.
        case stream
        /// Patches under review: nothing is interpreted. Control bytes and invisible or
        /// reordering characters are shown, so hidden content cannot hide.
        case review
    }

    private enum State {
        case ground
        case escape
        case csi([UInt8])
        case string
        case stringEscape
    }

    public let mode: Mode
    private var state = State.ground
    private var pending: [UInt8] = []

    public init(mode: Mode) { self.mode = mode }

    /// The sanitizer for writes to `fd`, or nil when `fd` is not a terminal.
    public static func forTerminal(_ fd: Int32, mode: Mode) -> TerminalSanitizer? {
        isatty(fd) == 1 ? TerminalSanitizer(mode: mode) : nil
    }

    public mutating func filter(_ data: Data) -> Data {
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        for byte in data { take(byte, into: &out) }
        return Data(out)
    }

    /// Flushes a character split by the end of input. An unfinished escape sequence is dropped.
    public mutating func finish() -> Data {
        let rest = pending
        pending = []
        state = .ground
        return Data(rest)
    }

    private mutating func take(_ byte: UInt8, into out: inout [UInt8]) {
        if !pending.isEmpty {
            guard (0x80...0xBF).contains(byte) else {
                out += pending
                pending = []
                return take(byte, into: &out)
            }
            pending.append(byte)
            if pending.count == (pending[0] == 0xC2 ? 2 : 3) { emitPending(into: &out) }
            return
        }
        switch state {
        case .ground:
            ground(byte, into: &out)
        case .escape:
            switch byte {
            case UInt8(ascii: "["): state = .csi([0x1B, byte])
            case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"): state = .string
            default: state = .ground
            }
        case .csi(var sequence):
            if (0x20...0x3F).contains(byte), sequence.count < 64 {
                sequence.append(byte)
                state = .csi(sequence)
            } else if (0x40...0x7E).contains(byte) {
                sequence.append(byte)
                if Self.safeCSI(sequence) { out += sequence }
                state = .ground
            } else {
                // A control byte or an overlong sequence ends the sequence; the byte stands on its own.
                state = .ground
                if sequence.count >= 64 { return }
                ground(byte, into: &out)
            }
        case .string:
            if byte == 0x07 { state = .ground } else if byte == 0x1B { state = .stringEscape }
        case .stringEscape:
            state = byte == UInt8(ascii: "\\") ? .ground : (byte == 0x1B ? .stringEscape : .string)
        }
    }

    private mutating func ground(_ byte: UInt8, into out: inout [UInt8]) {
        switch byte {
        case 0x0A, 0x09:
            out.append(byte)
        // A `where` clause binds only to the last pattern of a case, so each byte gets its own.
        case 0x0D where mode == .stream, 0x08 where mode == .stream:
            out.append(byte)
        case 0x1B where mode == .stream:
            state = .escape
        case 0x00..<0x20, 0x7F:
            if mode == .review { out += Array("^\(Character(UnicodeScalar(byte ^ 0x40)))".utf8) }
        case 0xC2, 0xE2, 0xEF:
            pending = [byte]
        default:
            out.append(byte)
        }
    }

    private mutating func emitPending(into out: inout [UInt8]) {
        let bytes = pending
        pending = []
        var scalar = UInt32(bytes[0] & (bytes.count == 2 ? 0x1F : 0x0F))
        for byte in bytes.dropFirst() { scalar = scalar << 6 | UInt32(byte & 0x3F) }
        guard Self.hidden(scalar, mode: mode) else {
            out += bytes
            return
        }
        if mode == .review { out += Array(String(format: "<U+%04X>", scalar).utf8) }
    }

    /// C1 controls act like ESC sequences on some terminals. In review, characters that
    /// reorder or hide text (bidi overrides and isolates, zero-width marks, BOM) are shown.
    private static func hidden(_ scalar: UInt32, mode: Mode) -> Bool {
        if (0x80...0x9F).contains(scalar) { return true }
        guard mode == .review else { return false }
        return (0x200B...0x200F).contains(scalar) || (0x2028...0x202E).contains(scalar)
            || (0x2066...0x2069).contains(scalar) || scalar == 0xFEFF
    }

    /// SGR (colors), erase in line, and cursor to column: ESC [ digits/semicolons, then m, K or G.
    private static func safeCSI(_ sequence: [UInt8]) -> Bool {
        guard let final = sequence.last, [UInt8(ascii: "m"), UInt8(ascii: "K"), UInt8(ascii: "G")].contains(final) else { return false }
        return sequence.dropFirst(2).dropLast().allSatisfy { (0x30...0x39).contains($0) || $0 == UInt8(ascii: ";") }
    }
}
