import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct RunRequest: Codable, Equatable {
    public var runtimeDirectory: String?
    public var workspaceDisk: String?
    public var name: String
    public var cpus: Int
    public var memoryMB: Int
    public var ttlSeconds: Int?
    public var bootTimeoutSeconds: Int
    public var network: NetworkMode?
    public var filteredRepositoryHost: String?

    public init(name: String, cpus: Int, memoryMB: Int, ttlSeconds: Int?, bootTimeoutSeconds: Int, network: NetworkMode? = nil) {
        self.name = name
        self.cpus = cpus
        self.memoryMB = memoryMB
        self.ttlSeconds = ttlSeconds
        self.bootTimeoutSeconds = bootTimeoutSeconds
        self.network = network
    }
}

public struct ExecCommand: Codable, Equatable {
    public var name: String
    public var argv: [String]
    public var env: [String]
    public var cwd: String
    public var timeoutSeconds: Int
    public var requireOffline: Bool?
    public var permitFiltered: Bool?
    /// `none` closes guest stdin immediately, `pipe` streams host stdin until EOF,
    /// and `interactive` does the same even when host stdin is a terminal.
    public var input: String?
    /// Set to run on a guest terminal of this size. Output is one combined stdout stream.
    /// An older daemon ignores this field, so clients must check `execTerminalVersion`.
    public var terminal: TerminalSize?
    /// Asks the daemon to send the sandbox's expiration deadline before any output.
    /// An older daemon ignores this field, so clients must check `execDeadlineVersion`.
    public var reportDeadline: Bool?

    public init(
        name: String, argv: [String], env: [String], cwd: String, timeoutSeconds: Int,
        requireOffline: Bool? = nil, permitFiltered: Bool? = nil, input: String? = nil
    ) {
        self.name = name
        self.argv = argv
        self.env = env
        self.cwd = cwd
        self.timeoutSeconds = timeoutSeconds
        self.requireOffline = requireOffline
        self.permitFiltered = permitFiltered
        self.input = input
    }
}

/// Stop flag for a host stdin reader. Set when the guest command finishes.
public final class ExecStdinControl {
    private let lock = NSLock()
    private var stopped = false

    public func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    public var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}

/// Host Ctrl-C state for one foreground guest command.
public final class ExecInterrupt {
    public init() {}

    private let lock = NSLock()
    private var forwardSignal: ((Int32) -> Void)?
    private var abortWait: (() -> Void)?
    private var aborted = false

    public func bind(forward: @escaping (Int32) -> Void, abort: @escaping () -> Void) {
        lock.lock()
        forwardSignal = forward
        abortWait = abort
        lock.unlock()
    }

    public func deliver(count: Int) {
        switch hostInterruptAction(count: count) {
        case .forward(let signal):
            lock.lock()
            let forward = forwardSignal
            lock.unlock()
            forward?(signal)
        case .abort:
            lock.lock()
            aborted = true
            let abort = abortWait
            lock.unlock()
            abort?()
        }
    }

    public var didAbort: Bool {
        lock.lock()
        defer { lock.unlock() }
        return aborted
    }
}

/// Host window changes for one terminal exec.
public final class ExecResize {
    public init() {}

    private let lock = NSLock()
    private var send: ((TerminalSize) -> Void)?

    public func bind(_ send: @escaping (TerminalSize) -> Void) {
        lock.lock()
        self.send = send
        lock.unlock()
    }

    public func deliver(_ size: TerminalSize) {
        lock.lock()
        let send = self.send
        lock.unlock()
        send?(size)
    }
}

public enum HostInterrupt: Equatable {
    case forward(Int32)
    case abort
}

/// The first host interrupt is delivered to the guest. The next one stops waiting.
public func hostInterruptAction(count: Int) -> HostInterrupt {
    count <= 1 ? .forward(SIGINT) : .abort
}

public func cliExitStatus(code: Int32, signal: Int32) -> Int32 {
    signal > 0 ? 128 + signal : code
}

/// A terminal without `-i` sends no input. A pipe streams until EOF. Explicit modes win.
public func resolveExecInput(requested: String?, stdinIsTerminal: Bool) -> String {
    switch requested {
    case "none", "pipe", "interactive":
        return requested ?? "none"
    default:
        return stdinIsTerminal ? "none" : "pipe"
    }
}

public enum CLIOutput: Equatable {
    case human
    case json
}

public enum CLICommand: Equatable {
    case help(topic: [String])
    case version
    case daemon
    case ps
    case ls
    case doctor([RuntimeSelection])
    case logs(LogsCommand)
    case managed(TaskCommand)
    case run(RunRequest)
    case exec(ExecCommand)
    case shell(ExecCommand)
    /// The same removal request as `rm`, without `--purge`.
    case destroy(TaskCommand)
    case task(TaskCommand)
    /// `task exec` parses exactly like `exec` and runs the same request.
    case taskExec(ExecCommand)
    case runtimePrepare(RuntimePreparation)
}

public struct CLIInvocation: Equatable {
    public var home: URL?
    public var output: CLIOutput
    public var verbose: Bool
    public var command: CLICommand

    public init(home: URL?, command: CLICommand, output: CLIOutput = .human, verbose: Bool = false) {
        self.home = home
        self.output = output
        self.verbose = verbose
        self.command = command
    }
}

public struct LogsCommand: Equatable {
    public var target: String
    public var execution: Int?
    public var list: Bool
}
