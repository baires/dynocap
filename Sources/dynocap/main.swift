import Foundation
import DynoCapCore
import DynoCapVZ

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
                try replayExecutionLogs(
                    logs, execution: command.execution,
                    stdoutFilter: TerminalSanitizer.forTerminal(STDOUT_FILENO, mode: .stream),
                    stderrFilter: TerminalSanitizer.forTerminal(STDERR_FILENO, mode: .stream))
            }
        case .doctor(let request):
            try request.validate()
            let report = request.fix ? doctorFix(request, invocation, args) : diagnose(request, invocation, args)
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
        case .managed(let command), .task(let command), .destroy(let command):
            // Advanced forms (task start, task finish, destroy) run the same operations as clone, finish, and rm.
            try manage(command, invocation, args)
        case .runtimePrepare(let preparation):
            let paths = try ready(invocation)
            let say: (String) -> Void = { if invocation.output == .human { fputs($0 + "\n", stderr) } }
            let (artifact, log) = try prepareRuntime(preparation, paths: paths, args: args, say: say)
            print(try formatRuntimePreparationResult(artifact, home: paths.home, log: log, output: invocation.output), terminator: "")
        case .help(let topic):
            print(commandHelp(topic))
        case .version:
            print(try formatVersion(output: invocation.output), terminator: "")
        case .daemon:
            if ProcessInfo.processInfo.environment["DYNOCAP_DETACH"] == "1" {
                _ = setsid()
            }
            let paths = resolve(invocation)
            let daemon = Daemon(home: paths.home, backend: makeBackend())
            try daemon.start()
            daemon.runForever()
        case .ps:
            let paths = try ready(invocation)
            // ps is ls limited to raw sandboxes, so both share one listing and JSON schema.
            let data = try DaemonClient(socketPath: paths.socket.path).task(TaskCommand(op: "entries"))
            let entries = try JSONDecoder().decode([ManagedEntry].self, from: data).filter { $0.kind == "sandbox" }
            if invocation.output == .json {
                print(try formatSandboxListJSON(entries), terminator: "")
            } else {
                print(formatSandboxList(entries, now: unixNow(), width: listingWidth(), empty: "No raw sandboxes."), terminator: "")
            }
        case .run(let request):
            let paths = try ready(invocation)
            if invocation.output == .human { fputs(CreationStage.booting.rawValue + "\n", stderr) }
            let status = try DaemonClient(socketPath: paths.socket.path).run(request)
            print(try formatRunResult(status, home: paths.home, output: invocation.output, now: unixNow()), terminator: "")
        case .exec(let command), .taskExec(let command):
            try requireTerminalInput(command, stdinIsTerminal: isatty(STDIN_FILENO) == 1)
            let paths = try ready(invocation)
            var command = command
            command.input = resolveExecInput(requested: command.input, stdinIsTerminal: isatty(STDIN_FILENO) == 1)
            let status = try foregroundExec(client: DaemonClient(socketPath: paths.socket.path), command: command)
            exit(status)
        case .shell(let command):
            try requireShellTerminal(stdinIsTerminal: isatty(STDIN_FILENO) == 1, stdoutIsTerminal: isatty(STDOUT_FILENO) == 1)
            let paths = try ready(invocation)
            let status = try foregroundExec(client: DaemonClient(socketPath: paths.socket.path), command: command)
            fputs(shellExitNotice(command.name), stderr)
            exit(status)
        }
    }

    /// Builds and verifies a runtime; `runtime prepare` and `doctor --fix` share it.
    static func prepareRuntime(
        _ preparation: RuntimePreparation, paths: DynoCapPaths, args: [String], say: (String) -> Void, onLog: (URL) -> Void = { _ in }
    ) throws -> (RuntimeArtifact, URL) {
        try DaemonClient(socketPath: paths.socket.path).requireTasks()
        say("Preparing the runtime; verified inputs may be downloaded...")
        let executable = CLIExecutable.resolve(argument: args[0]).deletingLastPathComponent()
            .appendingPathComponent("dynocap-mkruntime")
        let log = try buildRuntime(preparation, paths: paths, executable: executable) { log in
            onLog(log)
            say("Runtime build log: \(log.path)")
        }
        say("Verifying the prepared runtime (offline guest check for new artifacts)...")
        var verification = TaskCommand(op: "runtimeVerify")
        verification.runtimes = preparation.runtimes
        do {
            let data = try DaemonClient(socketPath: paths.socket.path).task(verification)
            return (try JSONDecoder().decode(RuntimeArtifact.self, from: data), log)
        } catch {
            var failure = error as? DynoCapError ?? DynoCapError("prepared runtime verification failed")
            failure.recovery += " Runtime build log: \(log.path)."
            throw failure
        }
    }

    static func diagnose(_ request: DoctorRequest, _ invocation: CLIInvocation, _ args: [String]) -> DoctorReport {
        let executable = CLIExecutable.resolve(argument: args[0])
        let host = DoctorHost(
            arch: HostArch.guest, platformSupported: DynoCapInfo.virtualizationAvailable,
            backend: DoctorVirtualizationSupport.backendCheck(), signing: DoctorVirtualizationSupport.signingCheck(executable: executable))
        let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
        let source = locateDynoCapSource(executable: executable, currentDirectory: current)
        // --runtime wins; otherwise the project decides. The dynocap checkout is where people run doctor, not their project.
        var runtimes = request.runtimes ?? []
        var origin: String?
        let project = request.project.map { URL(fileURLWithPath: $0).standardizedFileURL } ?? (current == source?.standardizedFileURL ? nil : current)
        // A named PROJECT gets exactly what clone would use, shell:1 included; a bare directory only counts with project files.
        if request.runtimes == nil, let project,
           let chosen = request.project == nil ? ProjectRuntime.detect(project) : ProjectRuntime.choose(projectPath: project.path) {
            runtimes = [chosen.runtime]
            origin = chosen.marker
        }
        return diagnoseHost(paths: resolve(invocation), executable: executable, runtimes: runtimes, host: host, source: source,
                            runtimeOrigin: origin, fixCommand: doctorFixCommand(home: invocation.home, runtimes: request.runtimes, project: request.project))
    }

    /// Repairs what the first diagnosis marks fixable, then reports a fresh diagnosis with what was attempted.
    static func doctorFix(_ request: DoctorRequest, _ invocation: CLIInvocation, _ args: [String]) -> DoctorReport {
        let before = diagnose(request, invocation, args)
        let executable = CLIExecutable.resolve(argument: args[0])
        let source = locateDynoCapSource(executable: executable, currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        let paths = resolve(invocation)
        // Progress stays on stderr for JSON too, so stdout remains a single JSON document.
        let count = before.fixes.count
        fputs(count == 0 ? "Nothing to repair automatically.\n" : "Repairing \(count) problem\(count == 1 ? "" : "s"):\n", stderr)
        let repairs = repairHost(before, progress: { fix, repair in
            if let repair {
                fputs("\(repair.status) (\(formatDuration(repair.seconds)))\n", stderr)
            } else {
                fputs("  \(fix.action(before))... ", stderr)
            }
        }, perform: { fix in
            switch fix {
            case .restartDaemon:
                try stopDaemon(paths)
                try ensureDaemon(paths: paths, home: invocation.home)
                let check = probeDoctorDaemon(paths)
                guard check.status == "ok" else {
                    throw DynoCapError("the restarted daemon still fails: \(check.message)",
                                       recovery: "Rebuild with ./scripts/build-macos.sh, then run dynocap doctor --fix again.")
                }
                return DoctorRepairOutput()
            case .buildImages:
                guard let source else { throw DynoCapError("the dynocap source checkout was not found") }
                return try buildGuestImage(paths: paths, arch: before.arch, source: source)
            case .prepareRuntime:
                guard let source else { throw DynoCapError("the dynocap source checkout was not found") }
                _ = try requireGo()
                let ready = try ready(invocation)
                var log: URL?
                do {
                    let preparation = RuntimePreparation(repo: source.path, runtimes: before.runtimes)
                    _ = try prepareRuntime(preparation, paths: ready, args: args, say: { _ in }, onLog: { log = $0 })
                } catch let error as DynoCapError {
                    guard let log else { throw error }
                    throw DoctorRepairFailure(error, log: log)
                }
                return DoctorRepairOutput(log: log)
            }
        })
        if !repairs.isEmpty { fputs("\n", stderr) }
        var after = diagnose(request, invocation, args)
        after.repairs = repairs
        return after
    }

    static func formatDuration(_ seconds: Double) -> String {
        seconds < 60 ? String(format: "%.0fs", seconds) : "\(Int(seconds) / 60)m\(String(format: "%02d", Int(seconds) % 60))s"
    }

    /// Management operations shared by their primary and advanced forms.
    static func manage(_ command: TaskCommand, _ invocation: CLIInvocation, _ args: [String]) throws {
        var command = command
        // Without --runtime the daemon chooses by the same rule; showing it here keeps the choice visible.
        if command.op == "start", command.runtimes == nil {
            let chosen = ProjectRuntime.choose(projectPath: command.projectPath)
            command.runtimes = [chosen.runtime]
            if invocation.output == .human { fputs(chosen.note + "\n", stderr) }
        }
        let paths = try ready(invocation)
        let client = DaemonClient(socketPath: paths.socket.path)
        try client.requireTaskManagement()
        let progress: ((String) -> Void)? = invocation.output == .human && command.op == "start" ? { fputs($0 + "\n", stderr) } : nil
        let data = try client.task(command, onProgress: progress)
        switch command.op {
        case "start":
            let descriptor = try JSONDecoder().decode(TaskDescriptor.self, from: data)
            print(try formatCreationResult(
                descriptor, command: command, home: paths.home, output: invocation.output, now: unixNow()), terminator: "")
        case "inspect":
            let inspection = try JSONDecoder().decode(SandboxInspection.self, from: data)
            print(try formatInspection(inspection, output: invocation.output, now: unixNow(), arguments: args), terminator: "")
        case "finish":
            let descriptor = try JSONDecoder().decode(TaskDescriptor.self, from: data)
            print(try formatFinishResult(descriptor, output: invocation.output, now: unixNow()), terminator: "")
        case "diff":
            let preview = try JSONDecoder().decode(TaskPreview.self, from: data)
            let warning = sensitiveWarning(sensitiveChanges(resultDirectory: preview.directory))
            if !warning.isEmpty { FileHandle.standardError.write(Data((warning.joined(separator: "\n") + "\n").utf8)) }
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: preview.patchPath))
            defer { try? file.close() }
            // On a terminal the patch is shown, not interpreted: escapes and hidden characters become visible text.
            var review = TerminalSanitizer.forTerminal(STDOUT_FILENO, mode: .review)
            while let chunk = try file.read(upToCount: 64 << 10), !chunk.isEmpty {
                try FileHandle.standardOutput.write(contentsOf: review?.filter(chunk) ?? chunk)
            }
            if let rest = review?.finish() { try FileHandle.standardOutput.write(contentsOf: rest) }
        case "remove":
            print(try formatRemovalResult(target: command.id ?? "", purged: command.purge == true, output: invocation.output), terminator: "")
        default:
            print(String(data: data, encoding: .utf8) ?? "")
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
        // A terminal session warns on stderr before the sandbox TTL ends. Writes share a lock
        // so a warning never lands inside a chunk of guest output.
        let output = NSLock()
        var warnings: DispatchSourceTimer?
        defer { warnings?.cancel() }
        let onDeadline: ((Int64) -> Void)? = command.terminal == nil ? nil : { deadline in
            var schedule = TTLWarningSchedule(deadline: deadline)
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now(), repeating: 1)
            timer.setEventHandler {
                guard let remaining = schedule.due(now: unixNow()) else { return }
                let text = ttlWarningText(name: command.name, remaining: remaining, deadline: deadline)
                output.withLock { try? FileHandle.standardError.write(contentsOf: Data(text.utf8)) }
            }
            timer.resume()
            warnings = timer
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
        // Without -t, guest bytes are command output, not a terminal session: a host terminal sees text and colors only.
        var stdoutFilter = command.terminal == nil ? TerminalSanitizer.forTerminal(STDOUT_FILENO, mode: .stream) : nil
        var stderrFilter = command.terminal == nil ? TerminalSanitizer.forTerminal(STDERR_FILENO, mode: .stream) : nil
        defer {
            if let rest = stdoutFilter?.finish(), !rest.isEmpty { try? FileHandle.standardOutput.write(contentsOf: rest) }
            if let rest = stderrFilter?.finish(), !rest.isEmpty { try? FileHandle.standardError.write(contentsOf: rest) }
        }
        do {
            let outcome = try client.exec(
                command,
                readStdin: command.input == "none" ? nil : { readExecStdin($0) },
                onStdout: { data in
                    output.withLock {
                        let shown = stdoutFilter?.filter(data) ?? data
                        try? FileHandle.standardOutput.write(contentsOf: shown)
                    }
                },
                onStderr: { data in
                    output.withLock {
                        let shown = stderrFilter?.filter(data) ?? data
                        try? FileHandle.standardError.write(contentsOf: shown)
                    }
                },
                interrupt: interrupt,
                resize: resize,
                onDeadline: onDeadline
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

    static func resolve(_ invocation: CLIInvocation) -> DynoCapPaths {
        if let home = invocation.home {
            return DynoCapPaths(home: home)
        }
        return DynoCapPaths.resolve(override: nil)
    }

    static func ready(_ invocation: CLIInvocation) throws -> DynoCapPaths {
        let paths = resolve(invocation)
        do { try paths.ensure() } catch {
            throw DynoCapError(
                "cannot access home \(paths.home.path)", code: .operationFailed,
                recovery: "Choose a writable directory with --home PATH and retry.")
        }
        try ensureDaemon(paths: paths, home: invocation.home)
        return paths
    }

    static func ensureDaemon(paths: DynoCapPaths, home: URL?) throws {
        let client = DaemonClient(socketPath: paths.socket.path)
        if (try? client.ping()) != nil { return }
        let proc = Process()
        proc.executableURL = CLIExecutable.resolve(argument: CommandLine.arguments[0])
        if let home {
            proc.arguments = ["--home", home.path, "daemon"]
        } else if let envHome = ProcessInfo.processInfo.environment["DYNOCAP_HOME"], !envHome.isEmpty {
            proc.arguments = ["--home", envHome, "daemon"]
        } else {
            proc.arguments = ["daemon"]
        }
        var env = ProcessInfo.processInfo.environment
        env["DYNOCAP_DETACH"] = "1"
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
            throw DynoCapError("could not start daemon for home \(paths.home.path)", code: .daemonUnavailable)
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if (try? client.ping()) != nil { return }
            usleep(50_000)
        }
        throw DynoCapError("daemon did not become ready; see \(paths.log.path)", code: .daemonUnavailable)
    }

    static func makeBackend() -> VMBackend {
        #if os(macOS)
        return VirtualizationBackend()
        #else
        return UnsupportedBackend()
        #endif
    }
}
