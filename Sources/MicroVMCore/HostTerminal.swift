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
    private let lock = NSLock()
    private var active = true

    public init(fd: Int32) throws {
        var original = termios()
        guard tcgetattr(fd, &original) == 0 else {
            throw MicroVMError("cannot read host terminal settings: \(POSIX.errnoString())")
        }
        var raw = original
        cfmakeraw(&raw)
        guard tcsetattr(fd, TCSANOW, &raw) == 0 else {
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

/// Host signals that end a terminal exec. The terminal is restored before the CLI exits 128 + signal.
public let terminalExitSignals: [Int32] = [SIGTERM, SIGHUP, SIGQUIT]
