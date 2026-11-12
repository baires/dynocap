import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Raw mode for the host terminal during `exec --tty`. The guest terminal does
/// the echo, line editing, and signal keys, so the host passes every byte through.
/// Restore is idempotent and safe from any thread, including a signal handler queue.
public final class HostTerminalMode {
    private let fd: Int32
    private let saved: termios
    private let guardian: TerminalGuardian?
    private let lock = NSLock()
    private var active = true

    public init(fd: Int32) throws {
        var original = termios()
        guard tcgetattr(fd, &original) == 0 else {
            throw MicroVMError("cannot read host terminal settings: \(POSIX.errnoString())")
        }
        // Started before raw mode so it saves the settings to put back.
        guardian = ttyname(fd).flatMap { TerminalGuardian(terminalPath: String(cString: $0)) }
        var raw = original
        cfmakeraw(&raw)
        guard tcsetattr(fd, TCSANOW, &raw) == 0 else {
            guardian?.release()
            throw MicroVMError("cannot put the host terminal in raw mode: \(POSIX.errnoString())")
        }
        self.fd = fd
        saved = original
    }

    deinit { restore() }

    public func restore() {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        active = false
        var original = saved
        _ = tcsetattr(fd, TCSANOW, &original)
        guardian?.release()
    }
}

/// Restores the host terminal if the CLI dies while it is raw, including by SIGKILL,
/// which no handler can catch. A shell helper saves the settings, then waits on a pipe
/// that only this process can write. `done` means the CLI restored the terminal itself;
/// EOF without it means the CLI died, and the helper puts the saved settings back.
/// Best effort: a signal sent to the whole process group can end the helper too.
final class TerminalGuardian {
    static let script = """
        trap '' HUP INT QUIT TERM TSTP TTIN TTOU
        saved=$(stty -g <"$1") || exit 0
        echo ready
        IFS= read -r line || line=
        [ "$line" = done ] || stty "$saved" <"$1"
        """

    private let control: FileHandle
    private let lock = NSLock()
    private var released = false

    init?(terminalPath: String) {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Self.script, "microvm-terminal-guard", terminalPath]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        control = input.fileHandleForWriting
        let ready = DispatchSemaphore(value: 0)
        var line = Data()
        Thread.detachNewThread {
            line = output.fileHandleForReading.readData(ofLength: 6)
            ready.signal()
        }
        guard ready.wait(timeout: .now() + 2) == .success, line == Data("ready\n".utf8) else {
            try? control.close()
            return nil
        }
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return }
        released = true
        try? control.write(contentsOf: Data("done\n".utf8))
        try? control.close()
    }
}

/// `exec --tty` reads keystrokes from the host terminal. A pipe or file has no
/// window, echo, or signal keys to forward, so it is refused before any daemon work.
public func requireTerminalInput(_ command: ExecCommand, stdinIsTerminal: Bool) throws {
    guard command.terminal != nil, !stdinIsTerminal else { return }
    throw MicroVMError(
        "--tty requires a terminal on stdin", exitCode: 2,
        recovery: "Run the command from an interactive terminal, or drop -t to pipe input with stdout and stderr kept separate.")
}

/// `shell` is for a person at a terminal. Without one there is no prompt to read or keystrokes
/// to send, so scripts are pointed at exec before any daemon work.
public func requireShellTerminal(stdinIsTerminal: Bool, stdoutIsTerminal: Bool) throws {
    guard !stdinIsTerminal || !stdoutIsTerminal else { return }
    let missing = stdinIsTerminal ? "stdout is not a terminal" : (stdoutIsTerminal ? "stdin is not a terminal" : "neither is a terminal")
    throw MicroVMError(
        "shell requires a terminal on stdin and stdout; \(missing)", exitCode: 2,
        recovery: "Run microvm shell from an interactive terminal. To script a command, use microvm exec NAME -- COMMAND.")
}

/// Printed on stderr after the shell exits, because leaving it does not end the sandbox.
public func shellExitNotice(_ name: String) -> String {
    "microvm: left the shell; \(name) is still running until its TTL. "
        + "Export with `microvm finish \(name)` or discard with `microvm rm \(name) --force`.\n"
}

/// Seconds before the sandbox deadline at which a terminal session warns, latest last.
public let ttlWarningThresholds: [Int64] = [300, 60]

/// When a terminal session warns about its sandbox TTL. Each threshold warns at most once;
/// thresholds already passed when the session opens collapse into one immediate warning.
/// Pure and clock-free: callers pass the current Unix time.
public struct TTLWarningSchedule {
    public let deadline: Int64
    private var pending: [Int64]

    public init(deadline: Int64, thresholds: [Int64] = ttlWarningThresholds) {
        self.deadline = deadline
        pending = thresholds.sorted(by: >)
    }

    /// Seconds remaining when a warning is due at `now`, otherwise nil. Expiry itself is
    /// reported by the daemon ending the session, not here.
    public mutating func due(now: Int64) -> Int64? {
        let remaining = deadline - now
        guard remaining > 0, let largest = pending.first, remaining <= largest else { return nil }
        pending.removeAll { remaining <= $0 }
        return remaining
    }
}

/// A host diagnostic for stderr. It starts and ends a line itself because the host terminal is raw.
public func ttlWarningText(name: String, remaining: Int64, deadline: Int64) -> String {
    let minutes = remaining / 60
    let seconds = remaining % 60
    let left = minutes == 0 ? "\(seconds)s" : (seconds == 0 ? "\(minutes)m" : "\(minutes)m \(seconds)s")
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime]
    let at = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(deadline)))
    return "\r\nmicrovm: \(name) expires in \(left) (\(at) UTC); the TTL is not renewed and unexported edits are lost then. "
        + "To keep them, run `microvm finish \(name)` from another terminal before it expires.\r\n"
}

/// Host signals that end a terminal exec. The terminal is restored before the CLI exits 128 + signal.
public let terminalExitSignals: [Int32] = [SIGTERM, SIGHUP, SIGQUIT]
