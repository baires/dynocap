import Foundation
import MicroVMCore
import MicroVMVZ

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main
struct Main {
    static func main() {
        do {
            let invocation = try parseCommand(CommandLine.arguments)
            do {
                try dispatch(invocation, CommandLine.arguments)
            } catch {
                fail(error, invocation: invocation)
            }
        } catch {
            fail(error)
        }
    }

    static func fail(_ error: Error, invocation: CLIInvocation? = nil) -> Never {
        let result = formatCLIFailure(error, invocation: invocation, arguments: CommandLine.arguments)
        fputs(result.text, stderr)
        exit(result.exitCode)
    }

    static func dispatch(_ invocation: CLIInvocation, _ args: [String]) throws {
        switch invocation.command {
        case .logs(let command):
            let paths = try ready(invocation)
            var request = TaskCommand(op: "logs")
            request.id = command.target
            let data = try DaemonClient(socketPath: paths.socket.path).task(request)
            let logs = try JSONDecoder().decode(ExecutionLogs.self, from: data)
            if command.list {
                print(formatExecutionList(logs, arguments: args), terminator: "")
            } else {
                try replayExecutionLogs(logs, execution: command.execution)
            }
        case .doctor(let runtimes):
            let executable = URL(fileURLWithPath: args[0]).standardizedFileURL.resolvingSymlinksInPath()
            let host = DoctorHost(
                arch: HostArch.guest, platformSupported: MicroVMInfo.virtualizationAvailable,
                backend: DoctorVirtualizationSupport.backendCheck(), signing: DoctorVirtualizationSupport.signingCheck(executable: executable))
            let report = diagnoseHost(paths: resolve(invocation), executable: executable, runtimes: runtimes, host: host)
            print(try formatDoctorReport(report, output: invocation.output, arguments: args), terminator: "")
            exit(report.ok ? 0 : 1)
        case .ls:
            let paths = try ready(invocation)
            let data = try DaemonClient(socketPath: paths.socket.path).task(TaskCommand(op: "entries"))
            let entries = try JSONDecoder().decode([ManagedEntry].self, from: data)
            if invocation.output == .json {
                print(try formatSandboxListJSON(entries), terminator: "")
            } else {
                print(formatSandboxList(entries, now: unixNow(), width: listingWidth()), terminator: "")
            }
        case .managed(let command):
            let paths = try ready(invocation)
            let client = DaemonClient(socketPath: paths.socket.path)
            try client.requireTaskManagement()
            let progress: ((String) -> Void)? = invocation.output == .human && command.op == "start" ? { fputs($0 + "\n", stderr) } : nil
            let data = try client.task(command, onProgress: progress)
            if command.op == "start" {
                let descriptor = try JSONDecoder().decode(TaskDescriptor.self, from: data)
                print(try formatCreationResult(
                    descriptor, command: command, home: paths.home, output: invocation.output, now: unixNow()), terminator: "")
            } else if command.op == "inspect" {
                let inspection = try JSONDecoder().decode(SandboxInspection.self, from: data)
                print(try formatInspection(inspection, output: invocation.output, now: unixNow(), arguments: args), terminator: "")
            } else if command.op == "finish" {
                let descriptor = try JSONDecoder().decode(TaskDescriptor.self, from: data)
                print(try formatFinishResult(descriptor, output: invocation.output, now: unixNow()), terminator: "")
            } else if command.op == "diff" {
                let preview = try JSONDecoder().decode(TaskPreview.self, from: data)
                let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: preview.patchPath))
                defer { try? file.close() }
                while let chunk = try file.read(upToCount: 64 << 10), !chunk.isEmpty {
                    try FileHandle.standardOutput.write(contentsOf: chunk)
                }
            } else if command.op == "remove" {
                print("removed \(command.id ?? "")")
            } else {
                print(String(data: data, encoding: .utf8) ?? "")
            }
        case .runtimePrepare(let preparation):
            let paths = try ready(invocation)
            try DaemonClient(socketPath: paths.socket.path).requireTasks()
            if invocation.output == .human { fputs("Preparing the runtime; verified inputs may be downloaded...\n", stderr) }
            let executable = URL(fileURLWithPath: args[0]).standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
                .appendingPathComponent("microvm-mkruntime")
            let log = try buildRuntime(preparation, paths: paths, executable: executable) { log in
                if invocation.output == .human { fputs("Runtime build log: \(log.path)\n", stderr) }
            }
            if invocation.output == .human { fputs("Verifying the prepared runtime (offline guest check for new artifacts)...\n", stderr) }
            var verification = TaskCommand(op: "runtimeVerify")
            verification.runtimes = preparation.runtimes
            let artifact: RuntimeArtifact
            do {
                let data = try DaemonClient(socketPath: paths.socket.path).task(verification)
                artifact = try JSONDecoder().decode(RuntimeArtifact.self, from: data)
            } catch {
                var failure = error as? MicroVMError ?? MicroVMError("prepared runtime verification failed")
                failure.recovery += " Runtime build log: \(log.path)."
                throw failure
            }
            print(try formatRuntimePreparationResult(artifact, home: paths.home, log: log, output: invocation.output), terminator: "")
        case .task(let command):
            var request: ExecCommand?
            if command.op == "exec", let id = command.id, let argv = command.argv {
                var exec = ExecCommand(name: id, argv: argv, env: [], cwd: "/workspace", timeoutSeconds: 300)
                if command.terminal == true {
                    exec.terminal = TerminalSize(rows: 0, cols: 0)
                    exec.input = "interactive"
                }
                try requireTerminalInput(exec, stdinIsTerminal: isatty(STDIN_FILENO) == 1)
                request = exec
            }
            let paths = try ready(invocation)
            let client = DaemonClient(socketPath: paths.socket.path)
            if var request {
                request.input = resolveExecInput(requested: request.input, stdinIsTerminal: isatty(STDIN_FILENO) == 1)
                let status = try foregroundExec(client: client, command: request)
                exit(status)
            }
            let data = try client.task(command)
            if command.op == "finish" {
                let descriptor = try JSONDecoder().decode(TaskDescriptor.self, from: data)
                print(try formatFinishResult(descriptor, output: invocation.output, now: unixNow()), terminator: "")
            } else {
                print(String(data: data, encoding: .utf8) ?? "")
            }
        case .help(let topic):
            print(commandHelp(topic))
        case .version:
            print(MicroVMInfo.describe(), terminator: "")
        case .daemon:
            if ProcessInfo.processInfo.environment["MICROVM_DETACH"] == "1" {
                _ = setsid()
            }
            let paths = resolve(invocation)
            let daemon = Daemon(home: paths.home, backend: makeBackend())
            try daemon.start()
            daemon.runForever()
        case .ps:
            let paths = try ready(invocation)
            let records = try DaemonClient(socketPath: paths.socket.path).ps()
            print(formatProcessTable(records, now: unixNow()), terminator: "")
        case .run(let request):
            let paths = try ready(invocation)
            let status = try DaemonClient(socketPath: paths.socket.path).run(request)
            print("\(status.name) \(status.phase)")
        case .exec(let command):
            try requireTerminalInput(command, stdinIsTerminal: isatty(STDIN_FILENO) == 1)
            let paths = try ready(invocation)
            var command = command
            command.input = resolveExecInput(requested: command.input, stdinIsTerminal: isatty(STDIN_FILENO) == 1)
            let status = try foregroundExec(client: DaemonClient(socketPath: paths.socket.path), command: command)
            exit(status)
        case .destroy(let name):
            let paths = try ready(invocation)
            try DaemonClient(socketPath: paths.socket.path).destroy(name)
            print("destroyed \(name)")
        }
    }

    /// Ctrl-C forwards SIGINT to the guest. A second Ctrl-C stops waiting and exits 130.
    /// With a terminal, the host terminal is raw until the command ends, whatever ends it.
    static func foregroundExec(client: DaemonClient, command: ExecCommand) throws -> Int32 {
        var command = command
        var resize: ExecResize?
        var terminal: HostTerminalMode?
        var terminalSources: [DispatchSourceSignal] = []
        defer {
            for source in terminalSources { source.cancel() }
            terminal?.restore()
        }
        if command.terminal != nil {
            command.terminal = terminalSize(STDIN_FILENO)
            let mode = try HostTerminalMode(fd: STDIN_FILENO)
            terminal = mode
            let windows = ExecResize()
            resize = windows
            terminalSources.append(watchSignal(SIGWINCH) { windows.deliver(terminalSize(STDIN_FILENO)) })
            for value in terminalExitSignals {
                terminalSources.append(watchSignal(value) {
                    mode.restore()
                    exit(128 + value)
                })
            }
        }
        let interrupt = ExecInterrupt()
        let lock = NSLock()
        var count = 0
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        signal(SIGINT, SIG_IGN)
        source.setEventHandler {
            lock.lock()
            count += 1
            let seen = count
            lock.unlock()
            interrupt.deliver(count: seen)
        }
        source.resume()
        defer {
            source.cancel()
            signal(SIGINT, SIG_DFL)
        }
        do {
            let outcome = try client.exec(
                command,
                readStdin: command.input == "none" ? nil : { readExecStdin($0) },
                onStdout: { try? FileHandle.standardOutput.write(contentsOf: $0) },
                onStderr: { try? FileHandle.standardError.write(contentsOf: $0) },
                interrupt: interrupt,
                resize: resize
            )
            return cliExitStatus(code: outcome.code, signal: outcome.signal)
        } catch {
            if interrupt.didAbort { return 130 }
            throw error
        }
    }

    static func watchSignal(_ value: Int32, _ handler: @escaping () -> Void) -> DispatchSourceSignal {
        signal(value, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: value, queue: .global())
        source.setEventHandler(handler: handler)
        source.setCancelHandler { signal(value, SIG_DFL) }
        source.resume()
        return source
    }

    static func terminalSize(_ fd: Int32) -> TerminalSize {
        var size = winsize()
        guard ioctl(fd, TIOCGWINSZ, &size) == 0 else { return TerminalSize(rows: 0, cols: 0) }
        return TerminalSize(rows: size.ws_row, cols: size.ws_col)
    }

    static func readExecStdin(_ control: ExecStdinControl) -> Data? {
        var item = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        while !control.isStopped {
            let ready = poll(&item, 1, 50)
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if ready == 0 { continue }
            var buffer = [UInt8](repeating: 0, count: 32 * 1024)
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return read(STDIN_FILENO, base, raw.count)
            }
            if count > 0 { return Data(buffer.prefix(count)) }
            if count == 0 { return nil }
            if errno == EINTR || errno == EAGAIN { continue }
            return nil
        }
        return nil
    }

    static func listingWidth() -> Int {
        var size = winsize()
        guard isatty(STDOUT_FILENO) == 1, ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else {
            return 120
        }
        return Int(size.ws_col)
    }

    static func resolve(_ invocation: CLIInvocation) -> MicroVMPaths {
        if let home = invocation.home {
            return MicroVMPaths(home: home)
        }
        return MicroVMPaths.resolve(override: nil)
    }

    static func ready(_ invocation: CLIInvocation) throws -> MicroVMPaths {
        let paths = resolve(invocation)
        do { try paths.ensure() } catch {
            throw MicroVMError(
                "cannot access home \(paths.home.path)", code: .operationFailed,
                recovery: "Choose a writable directory with --home PATH and retry.")
        }
        try ensureDaemon(paths: paths, home: invocation.home)
        return paths
    }

    static func ensureDaemon(paths: MicroVMPaths, home: URL?) throws {
        let client = DaemonClient(socketPath: paths.socket.path)
        if (try? client.ping()) != nil { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        if let home {
            proc.arguments = ["--home", home.path, "daemon"]
        } else if let envHome = ProcessInfo.processInfo.environment["MICROVM_HOME"], !envHome.isEmpty {
            proc.arguments = ["--home", envHome, "daemon"]
        } else {
            proc.arguments = ["daemon"]
        }
        var env = ProcessInfo.processInfo.environment
        env["MICROVM_DETACH"] = "1"
        proc.environment = env
        if !FileManager.default.fileExists(atPath: paths.log.path) {
            _ = FileManager.default.createFile(atPath: paths.log.path, contents: nil)
        }
        if let log = FileHandle(forWritingAtPath: paths.log.path) {
            _ = try? log.seekToEnd()
            proc.standardOutput = log
            proc.standardError = log
        }
        proc.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        do { try proc.run() } catch {
            throw MicroVMError("could not start daemon for home \(paths.home.path)", code: .daemonUnavailable)
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if (try? client.ping()) != nil { return }
            usleep(50_000)
        }
        throw MicroVMError("daemon did not become ready; see \(paths.log.path)", code: .daemonUnavailable)
    }

    static func makeBackend() -> VMBackend {
        #if os(macOS)
        return VirtualizationBackend()
        #else
        return UnsupportedBackend()
        #endif
    }
}
