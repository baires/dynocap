import XCTest

#if canImport(Darwin)
import Darwin
#endif

@testable import DynoCapCore

final class ExecTerminalTests: XCTestCase {
    func testTerminalFlagsImplyLiveInputAndRejectNoInput() throws {
        for flags in [["-t"], ["--tty"], ["-it"], ["-ti"], ["-i", "-t"], ["-t", "-i"]] {
            guard case .exec(let command) = try parseCommand(["dynocap", "exec"] + flags + ["demo", "--", "top"]).command else {
                return XCTFail("expected exec for \(flags)")
            }
            XCTAssertEqual(command.terminal, TerminalSize(rows: 0, cols: 0), "\(flags)")
            XCTAssertEqual(command.input, "interactive", "\(flags)")
            XCTAssertEqual(command.argv, ["top"])
        }
        guard case .exec(let guest) = try parseCommand(["dynocap", "exec", "demo", "--", "ls", "-t"]).command else {
            return XCTFail("expected exec")
        }
        XCTAssertNil(guest.terminal, "guest arguments after -- are not dynocap flags")
        XCTAssertEqual(guest.argv, ["ls", "-t"])
        for flags in [["-t", "--no-input"], ["--no-input", "-t"], ["--no-input", "-it"], ["--tty=yes"]] {
            XCTAssertThrowsError(try parseCommand(["dynocap", "exec"] + flags + ["demo", "--", "sh"]), "\(flags)") { error in
                XCTAssertEqual((error as? DynoCapError)?.exitCode, 2)
            }
        }
    }

    func testTaskExecTerminalFlag() throws {
        for flag in ["-t", "--tty", "-it"] {
            guard case .taskExec(let command) = try parseCommand(["dynocap", "task", "exec", flag, "demo", "--", "sh"]).command else {
                return XCTFail("expected task exec for \(flag)")
            }
            XCTAssertEqual(command.terminal, TerminalSize(rows: 0, cols: 0))
            XCTAssertEqual(command.input, "interactive")
            XCTAssertEqual(command.argv, ["sh"])
        }
        guard case .taskExec(let plain) = try parseCommand(["dynocap", "task", "exec", "demo", "--", "ls", "-t"]).command else {
            return XCTFail("expected task exec")
        }
        XCTAssertNil(plain.terminal)
        XCTAssertEqual(plain.argv, ["ls", "-t"])
        for flags in [["--tty=1"], ["--no-input", "-t"], ["-i", "--no-input"]] {
            XCTAssertThrowsError(try parseCommand(["dynocap", "task", "exec"] + flags + ["demo", "--", "sh"]), "\(flags)") {
                XCTAssertEqual(($0 as? DynoCapError)?.exitCode, 2)
            }
        }
        XCTAssertTrue(commandHelp(["task", "exec"]).contains("--tty"))
    }

    func testExecHelpDocumentsTerminalMode() {
        let help = commandHelp(["exec"])
        for text in ["-t", "--tty", "raw mode", "restored", "resizes", "combined", "terminal on stdin", "xterm-256color",
                     "5 minutes and 1 minute before the sandbox TTL ends"] {
            XCTAssertTrue(help.contains(text), text)
        }
    }

    func testShellIsAnUntimedTerminalExec() throws {
        for args in [["shell", "demo"], ["--home", "/tmp/h", "shell", "demo"], ["shell", "demo", "--home=/tmp/h", "--verbose"]] {
            guard case .shell(let command) = try parseCommand(["dynocap"] + args).command else {
                return XCTFail("expected shell for \(args)")
            }
            XCTAssertEqual(command.name, "demo")
            XCTAssertEqual(command.argv, guestShellArgv)
            XCTAssertEqual(command.timeoutSeconds, 0, "no command deadline")
            XCTAssertEqual(command.terminal, TerminalSize(rows: 0, cols: 0))
            XCTAssertEqual(command.input, "interactive")
            XCTAssertEqual(command.cwd, "", "the daemon picks /workspace or /")
            XCTAssertTrue(command.env.isEmpty)
        }
        for args in [["shell"], ["shell", "demo", "other"], ["shell", "demo", "--", "sh"], ["shell", "demo", "--json"],
                     ["--json", "shell", "demo"], ["shell", "demo", "-t"], ["shell", "demo", "--timeout", "5"],
                     ["shell", "demo", "--cwd=/tmp"], ["shell", "bad/name"]] {
            XCTAssertThrowsError(try parseCommand(["dynocap"] + args), "\(args)") {
                XCTAssertEqual(($0 as? DynoCapError)?.exitCode, 2, "\(args)")
            }
        }
        XCTAssertEqual(try parseCommand(["dynocap", "shell", "--help"]).command, .help(topic: ["shell"]))
        XCTAssertEqual(try parseCommand(["dynocap", "help", "shell"]).command, .help(topic: ["shell"]))
        let help = commandHelp(["shell"])
        for text in ["dynocap shell NAME_OR_ID", "/workspace", "Bash is not required", "no command deadline", "TTL",
                     "does not finish or remove", "restored", "--json is unsupported", "docs/how-to/interactive-shells-and-terminal.mdx",
                     "5 minutes and 1 minute before expiry"] {
            XCTAssertTrue(help.contains(text), text)
        }
        XCTAssertTrue(commandHelp([]).contains("dynocap shell demo"))
        XCTAssertTrue(commandHelp([]).contains("dynocap shell NAME_OR_ID"))
    }

    func testShellRequiresATerminalOnStdinAndStdout() {
        XCTAssertNoThrow(try requireShellTerminal(stdinIsTerminal: true, stdoutIsTerminal: true))
        for (input, output, text) in [(false, true, "stdin is not"), (true, false, "stdout is not"), (false, false, "neither")] {
            XCTAssertThrowsError(try requireShellTerminal(stdinIsTerminal: input, stdoutIsTerminal: output)) { error in
                let micro = error as? DynoCapError
                XCTAssertEqual(micro?.exitCode, 2)
                XCTAssertTrue(micro?.message.contains(text) == true, micro?.message ?? "")
                XCTAssertTrue(micro?.recovery.contains("dynocap exec NAME -- COMMAND") == true)
            }
        }
    }

    /// Runs the guest selection script against a substitute passwd file.
    func testGuestShellSelectionDoesNotAssumeBash() throws {
        let directory = URL(fileURLWithPath: "/tmp/dynocap-shell-select-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let custom = directory.appendingPathComponent("custom-shell")
        try "#!/bin/sh\necho custom\n".write(to: custom, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: custom.path)
        let refusal = directory.appendingPathComponent("nologin")
        try "#!/bin/sh\necho refused\n".write(to: refusal, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: refusal.path)
        let cases: [(String?, String)] = [
            ("root:x:0:0:root:/root:\(custom.path)\n", "custom"),
            ("daemon:x:1:1::/:\(custom.path)\nroot:x:0:0:root:/root:/bin/bash-is-not-installed\n", "fallback"),
            ("root:x:0:0:root:/root:\(refusal.path)\n", "fallback"),
            ("root:x:0:0:root:/root:\n", "fallback"),
            (nil, "fallback"),
        ]
        for (passwd, expected) in cases {
            let file = directory.appendingPathComponent("passwd")
            try? FileManager.default.removeItem(at: file)
            if let passwd { try passwd.write(to: file, atomically: true, encoding: .utf8) }
            // The fallback /bin/sh reads this script from stdin, which proves it was chosen.
            let script = guestShellArgv[2].replacingOccurrences(of: "/etc/passwd", with: file.path)
            XCTAssertNotEqual(script, guestShellArgv[2])
            let process = Process()
            process.executableURL = URL(fileURLWithPath: guestShellArgv[0])
            process.arguments = [guestShellArgv[1], script, guestShellArgv[3]]
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: Data("echo fallback\n".utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            let text = String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTAssertEqual(text, expected + "\n", passwd ?? "missing passwd")
        }
    }

    func testUntimedExecHasNoCommandDeadline() throws {
        let harness = try TerminalHarness()
        defer { harness.close() }
        let fd = try POSIX.connectUnix(harness.daemon.paths.socket.path)
        defer { _ = closeFD(fd) }
        try ControlCodec.write(fd, .ping)
        guard case .result(let capabilities) = try ControlCodec.read(fd) else { return XCTFail("expected ping result") }
        XCTAssertNoThrow(try validateExecUntimedCapability(capabilities))
        XCTAssertThrowsError(try validateExecUntimedCapability(Data(#"{"ok":true,"execTerminalVersion":1}"#.utf8))) {
            XCTAssertEqual(($0 as? DynoCapError)?.code, .incompatibleDaemon)
        }

        var command = ExecCommand(name: "demo", argv: guestShellArgv, env: [], cwd: "", timeoutSeconds: 0, input: "interactive")
        command.terminal = TerminalSize(rows: 24, cols: 80)
        let exec = try POSIX.connectUnix(harness.daemon.paths.socket.path)
        defer { _ = closeFD(exec) }
        try ControlCodec.write(exec, .exec(command))
        guard case .stdout = try ControlCodec.read(exec) else { return XCTFail("expected terminal output") }
        XCTAssertEqual(harness.backend.requests.last?.timeoutSeconds, 0, "the guest gets no timer either")
        // A one-second deadline would already have ended an ordinary command.
        var item = pollfd(fd: exec, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&item, 1, 1500), 0, "nothing arrives while the command runs without a deadline")
        try ControlCodec.write(exec, .stdin(Data("q".utf8)))
        XCTAssertEqual(try ControlCodec.read(exec), .exit(code: 0, signal: 0))

        let negative = try POSIX.connectUnix(harness.daemon.paths.socket.path)
        defer { _ = closeFD(negative) }
        try ControlCodec.write(negative, .exec(ExecCommand(name: "demo", argv: ["true"], env: [], cwd: "", timeoutSeconds: -1)))
        guard case .error(let text) = try ControlCodec.read(negative) else { return XCTFail("expected rejection") }
        XCTAssertTrue(text.contains("timeoutSeconds"), text)
        XCTAssertEqual(harness.backend.requests.count, 1, "a negative deadline starts nothing")
    }

    func testDaemonReportsTheSandboxDeadlineOnlyWhenAsked() throws {
        let harness = try TerminalHarness()
        defer { harness.close() }
        let fd = try POSIX.connectUnix(harness.daemon.paths.socket.path)
        defer { _ = closeFD(fd) }
        try ControlCodec.write(fd, .ping)
        guard case .result(let ping) = try ControlCodec.read(fd) else { return XCTFail("expected ping result") }
        XCTAssertEqual(try JSONDecoder().decode(PolicyCapabilities.self, from: ping).execDeadlineVersion, 1)
        let record = try XCTUnwrap(try harness.client.ps().first { $0.name == "demo" })
        let expected = record.createdAtUnix + Int64(try XCTUnwrap(record.ttlSeconds))

        var command = ExecCommand(name: "demo", argv: ["top"], env: [], cwd: "", timeoutSeconds: 30, input: "interactive")
        command.terminal = TerminalSize(rows: 24, cols: 80)
        command.reportDeadline = true
        let asked = try POSIX.connectUnix(harness.daemon.paths.socket.path)
        defer { _ = closeFD(asked) }
        try ControlCodec.write(asked, .exec(command))
        XCTAssertEqual(try ControlCodec.read(asked), .deadline(expected), "the deadline precedes any output")
        XCTAssertEqual(try ControlCodec.read(asked), .stdout(Data("ready\r\n".utf8)))
        try ControlCodec.write(asked, .stdin(Data("q".utf8)))
        XCTAssertEqual(try ControlCodec.read(asked), .exit(code: 0, signal: 0))

        command.reportDeadline = nil
        let plain = try POSIX.connectUnix(harness.daemon.paths.socket.path)
        defer { _ = closeFD(plain) }
        try ControlCodec.write(plain, .exec(command))
        XCTAssertEqual(try ControlCodec.read(plain), .stdout(Data("ready\r\n".utf8)), "older clients never see the frame")
        try ControlCodec.write(plain, .stdin(Data("q".utf8)))
        XCTAssertEqual(try ControlCodec.read(plain), .exit(code: 0, signal: 0))

        var received: [Int64] = []
        command.reportDeadline = nil
        let client = harness.client
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            let id = harness.backend.requests.last!.id
            try? harness.backend.writeStdin(name: "demo", id: id, data: Data("q".utf8))
        }
        _ = try client.exec(command, readStdin: { _ in nil }, onDeadline: { received.append($0) })
        XCTAssertEqual(received, [expected])
    }

    func testExpiryExplainsTheLossInATypedError() throws {
        let harness = try TerminalHarness()
        defer { harness.close() }
        _ = try harness.client.run(RunRequest(name: "short", cpus: 1, memoryMB: 256, ttlSeconds: 1, bootTimeoutSeconds: 5))
        XCTAssertThrowsError(try harness.client.exec(ExecCommand(name: "short", argv: ["top"], env: [], cwd: "", timeoutSeconds: 30))) {
            let error = $0 as? DynoCapError
            XCTAssertEqual(error?.code, .invalidPhase)
            XCTAssertEqual(error?.message, "sandbox short lifetime expired; its unexported edits are lost")
            XCTAssertTrue(error?.recovery.contains("does not renew the TTL or export") == true)
            XCTAssertTrue(error?.recovery.contains("own retention deadline; see dynocap inspect short") == true)
        }
    }

    func testNonTerminalInputIsRefusedBeforeDaemonWork() throws {
        var command = ExecCommand(name: "demo", argv: ["top"], env: [], cwd: "", timeoutSeconds: 5)
        XCTAssertNoThrow(try requireTerminalInput(command, stdinIsTerminal: false))
        command.terminal = TerminalSize(rows: 0, cols: 0)
        XCTAssertNoThrow(try requireTerminalInput(command, stdinIsTerminal: true))
        XCTAssertThrowsError(try requireTerminalInput(command, stdinIsTerminal: false)) { error in
            let micro = error as? DynoCapError
            XCTAssertEqual(micro?.exitCode, 2)
            XCTAssertTrue(micro?.recovery.contains("drop -t") == true)
        }
    }

    func testResizeFrameAndCapabilities() throws {
        let frame = try ControlCodec.encode(.resize(TerminalSize(rows: 40, cols: 120)))
        XCTAssertEqual(frame, Data([0, 0, 0, 5, ControlType.resize, 0, 40, 0, 120]))
        XCTAssertEqual(try ControlCodec.decode(frame), .resize(TerminalSize(rows: 40, cols: 120)))
        XCTAssertThrowsError(try ControlCodec.decode(Data([0, 0, 0, 4, ControlType.resize, 0, 40, 0])))
        XCTAssertThrowsError(try validateExecTerminalCapability(Data(#"{"ok":true,"execStreamVersion":1,"execSignalVersion":1}"#.utf8))) {
            XCTAssertEqual(($0 as? DynoCapError)?.code, .incompatibleDaemon)
        }
        XCTAssertTrue(guestAgentAllocatesTerminals("dynocap-agent signal=1 tty=1"))
        XCTAssertFalse(guestAgentAllocatesTerminals("dynocap-agent signal=1"))
        XCTAssertFalse(guestAgentAllocatesTerminals("dynocap-agent tty=10"))
        // A plain exec keeps the original frame type, so older agents are unaffected.
        let plain = try GuestProtocol.encode(.exec(ExecStart(id: 1, timeoutMS: 0, argv: ["true"], env: [], cwd: "")))
        XCTAssertEqual(plain.first, GuestProtocol.exec)
        XCTAssertThrowsError(try GuestProtocol.decode(Data([GuestProtocol.execTTY, 0, 0, 0, 1, 0, 0, 0, 0, 0, 24])))
    }

    func testRunningDaemonAdvertisesTerminals() throws {
        let harness = try TerminalHarness()
        defer { harness.close() }
        let fd = try POSIX.connectUnix(harness.daemon.paths.socket.path)
        defer { _ = closeFD(fd) }
        try ControlCodec.write(fd, .ping)
        guard case .result(let data) = try ControlCodec.read(fd) else { return XCTFail("expected ping result") }
        XCTAssertNoThrow(try validateExecTerminalCapability(data))
    }

    func testDaemonForwardsSizeResizeAndInputToTheSelectedTerminal() throws {
        let harness = try TerminalHarness()
        defer { harness.close() }
        _ = try harness.client.run(RunRequest(name: "other", cpus: 1, memoryMB: 256, ttlSeconds: 60, bootTimeoutSeconds: 5))
        let other = try POSIX.connectUnix(harness.daemon.paths.socket.path)
        defer { _ = closeFD(other) }
        try ControlCodec.write(other, .exec(ExecCommand(name: "other", argv: ["sleep"], env: [], cwd: "", timeoutSeconds: 30)))
        let fd = try POSIX.connectUnix(harness.daemon.paths.socket.path)
        defer { _ = closeFD(fd) }
        var command = ExecCommand(name: "demo", argv: ["top"], env: [], cwd: "", timeoutSeconds: 30, input: "interactive")
        command.terminal = TerminalSize(rows: 33, cols: 101)
        try ControlCodec.write(fd, .exec(command))
        XCTAssertTrue(waitUntil(2) { harness.backend.requests.count == 2 })
        let request = try XCTUnwrap(harness.backend.requests.first { $0.name == "demo" })
        XCTAssertEqual(request.terminal, TerminalSize(rows: 33, cols: 101))
        XCTAssertTrue(request.streamStdin)
        XCTAssertNil(harness.backend.requests.first { $0.name == "other" }?.terminal)
        guard case .stdout(let ready) = try ControlCodec.read(fd) else { return XCTFail("expected terminal output") }
        XCTAssertEqual(ready, Data("ready\r\n".utf8))
        // A failed resize is reported nowhere and does not cancel the command.
        try ControlCodec.write(fd, .resize(TerminalBackend.rejectedSize))
        try ControlCodec.write(fd, .resize(TerminalSize(rows: 40, cols: 120)))
        try ControlCodec.write(fd, .stdin(Data("ab".utf8)))
        try ControlCodec.write(fd, .stdinEOF)
        XCTAssertTrue(waitUntil(2) { harness.backend.resizes == [TerminalSize(rows: 40, cols: 120)] })
        XCTAssertTrue(waitUntil(2) { harness.backend.input == Data("ab".utf8) })
        try ControlCodec.write(fd, .stdin(Data("q".utf8)))
        var output = Data()
        while true {
            let message = try ControlCodec.read(fd)
            if case .stdout(let data) = message { output.append(data); continue }
            XCTAssertEqual(message, .exit(code: 0, signal: 0))
            break
        }
        XCTAssertEqual(output, Data("size 40 120\r\nab".utf8))
        XCTAssertEqual(harness.backend.cancelled, [])
        XCTAssertEqual(Set(try harness.client.ps().map(\.phase)), [.running])
    }

    func testTerminalExecJournalsOneTranscript() throws {
        let home = URL(fileURLWithPath: "/tmp/dynocap-terminal-logs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = DynoCapPaths(home: home)
        try paths.ensure()
        let now = unixNow()
        var record = TaskRecord(id: "task-tty", name: "demo", phase: "running", runtimeDigest: "digest", createdAtUnix: now,
                                expiresAtUnix: now + 86400, network: .none)
        record.commands = []
        let directory = home.appendingPathComponent("tasks/task-tty")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = TaskManager(paths: paths, arch: HostArch.guest, boot: { _ in throw DynoCapError("boot") },
                                  execute: { _, _, _, _, _, _ in Data() }, destroy: { _ in })
        manager.current = record
        manager.busy = true
        let plain = try XCTUnwrap(manager.begin(record.id, argv: ["echo"]))
        try manager.append(record.id, index: plain, data: Data("out\n".utf8), stderr: false)
        try manager.append(record.id, index: plain, data: Data("err\n".utf8), stderr: true)
        manager.end(record.id, index: plain, code: 0, error: nil)
        let index = try XCTUnwrap(manager.begin(record.id, argv: ["top"], terminal: true))
        let transcript = Data("ready\r\n\u{1b}[2Jtop\r\n^C\r\n".utf8) + Data([0, 255])
        try manager.append(record.id, index: index, data: transcript, stderr: false)
        manager.end(record.id, index: index, code: 130, error: nil)

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("1.terminal").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("1.stdout").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("1.stderr").path),
                       "a terminal has no separate stderr recording")
        let logs = try manager.executionLogs("demo")
        let entry = logs.executions[1]
        XCTAssertEqual(entry.format, "terminal")
        XCTAssertEqual(entry.stdout.fileName, "1.terminal")
        XCTAssertEqual(entry.stdout.integrity, "complete")
        XCTAssertEqual(entry.stderr.integrity, "absent")
        XCTAssertEqual(logs.executions[0].format, "separate")

        let table = formatExecutionList(logs)
        let row = try XCTUnwrap(table.split(separator: "\n").first { $0.hasPrefix("1  ") })
        XCTAssertTrue(row.contains("  \(transcript.count)  -  complete  terminal  top"), String(row))

        let out = home.appendingPathComponent("replay.out")
        let err = home.appendingPathComponent("replay.err")
        for file in [out, err] { FileManager.default.createFile(atPath: file.path, contents: nil) }
        let outHandle = try FileHandle(forWritingTo: out)
        let errHandle = try FileHandle(forWritingTo: err)
        try replayExecutionLogs(logs, execution: 1, stdout: outHandle, stderr: errHandle)
        try outHandle.close()
        try errHandle.close()
        XCTAssertEqual(try Data(contentsOf: out), transcript)
        XCTAssertEqual(try Data(contentsOf: err), Data())

        try Data("short".utf8).write(to: directory.appendingPathComponent("1.terminal"))
        XCTAssertEqual(try manager.executionLogs("demo").executions[1].stdout.integrity, "truncated")
    }

    #if os(macOS)
    func testTerminalSessionThroughAHostPTYRestoresTheTerminal() throws {
        let harness = try TerminalHarness()
        defer { harness.close() }
        let pty = try PTYProcess(home: harness.home, args: ["exec", "-t", "demo", "--", "top"], rows: 33, cols: 101)
        defer { pty.close() }
        let before = try pty.settings()
        XCTAssertTrue(pty.waitFor("ready"), pty.text)
        let raw = try pty.settings()
        XCTAssertEqual(raw.c_lflag & tcflag_t(ICANON | ECHO | ISIG), 0, "host terminal is raw during the command")
        let request = try XCTUnwrap(harness.backend.requests.last)
        XCTAssertEqual(request.terminal, TerminalSize(rows: 33, cols: 101))
        pty.type("ab")
        XCTAssertTrue(waitUntil(3) { harness.backend.input == Data("ab".utf8) })
        XCTAssertTrue(pty.waitFor("ab"), pty.text)
        pty.resize(rows: 40, cols: 120)
        XCTAssertTrue(waitUntil(3) { harness.backend.resizes.last == TerminalSize(rows: 40, cols: 120) }, "\(harness.backend.resizes)")
        XCTAssertTrue(pty.waitFor("size 40 120"), pty.text)
        pty.type("q")
        XCTAssertEqual(pty.wait(), 0, pty.text)
        XCTAssertTrue(sameSettings(before, try pty.settings()))
        XCTAssertTrue(harness.backend.signals.isEmpty)
        // After a normal exit the guardian stands down: a later change by the shell stays.
        var changed = try pty.settings()
        changed.c_lflag &= ~tcflag_t(ECHO)
        try pty.apply(changed)
        usleep(300_000)
        XCTAssertEqual(try pty.settings().c_lflag & tcflag_t(ECHO), 0)
    }

    func testSIGKILLStillRestoresTheTerminal() throws {
        let harness = try TerminalHarness()
        defer { harness.close() }
        let pty = try PTYProcess(home: harness.home, args: ["exec", "-t", "demo", "--", "top"], rows: 24, cols: 80)
        defer { pty.close() }
        let before = try pty.settings()
        XCTAssertTrue(pty.waitFor("ready"), pty.text)
        XCTAssertEqual(try pty.settings().c_lflag & tcflag_t(ICANON), 0)
        kill(pty.process.processIdentifier, SIGKILL)
        XCTAssertEqual(pty.wait(), SIGKILL, "Foundation reports the uncaught signal as the status")
        XCTAssertTrue(waitUntil(3) { (try? pty.settings()).map { sameSettings(before, $0) } ?? false })
        XCTAssertTrue(waitUntil(3) { !harness.backend.cancelled.isEmpty }, "the daemon cancels the orphaned command")
    }

    func testTaskExecRunsOnATerminal() throws {
        let harness = try TerminalHarness()
        defer { harness.close() }
        let pty = try PTYProcess(home: harness.home, args: ["task", "exec", "-t", "demo", "--", "top"], rows: 30, cols: 90)
        defer { pty.close() }
        let before = try pty.settings()
        XCTAssertTrue(pty.waitFor("ready"), pty.text)
        let request = try XCTUnwrap(harness.backend.requests.last)
        XCTAssertEqual(request.terminal, TerminalSize(rows: 30, cols: 90))
        XCTAssertEqual(request.cwd, "/", "like exec, a raw sandbox starts in /; a project starts in /workspace")
        pty.type("q")
        XCTAssertEqual(pty.wait(), 0, pty.text)
        XCTAssertTrue(sameSettings(before, try pty.settings()))
    }

    func testCtrlCIsAKeystrokeAndTheTerminalIsRestored() throws {
        let harness = try TerminalHarness()
        defer { harness.close() }
        let pty = try PTYProcess(home: harness.home, args: ["exec", "-it", "demo", "--", "top"], rows: 24, cols: 80)
        defer { pty.close() }
        let before = try pty.settings()
        XCTAssertTrue(pty.waitFor("ready"), pty.text)
        pty.type("\u{03}")
        XCTAssertEqual(pty.wait(), 130, pty.text)
        XCTAssertEqual(harness.backend.input, Data([3]), "Ctrl-C reached the guest terminal as a byte")
        XCTAssertTrue(harness.backend.signals.isEmpty, "the host did not generate SIGINT in raw mode")
        XCTAssertTrue(sameSettings(before, try pty.settings()))
        XCTAssertEqual(try harness.client.ps().first { $0.name == "demo" }?.phase, .running)
    }

    func testConnectionLossRestoresTheTerminal() throws {
        let harness = try TerminalHarness()
        defer { harness.close() }
        let pty = try PTYProcess(home: harness.home, args: ["exec", "-t", "demo", "--", "top"], rows: 24, cols: 80)
        defer { pty.close() }
        let before = try pty.settings()
        XCTAssertTrue(pty.waitFor("ready"), pty.text)
        pty.type("x")
        XCTAssertEqual(pty.wait(), 1, pty.text)
        XCTAssertTrue(pty.waitFor("guest agent connection lost"), pty.text)
        XCTAssertTrue(sameSettings(before, try pty.settings()))
    }

    func testSandboxExpiryRestoresTheTerminal() throws {
        let harness = try TerminalHarness()
        defer { harness.close() }
        _ = try harness.client.run(RunRequest(name: "short", cpus: 1, memoryMB: 256, ttlSeconds: 2, bootTimeoutSeconds: 5))
        let pty = try PTYProcess(home: harness.home, args: ["exec", "-t", "short", "--timeout", "30", "--", "top"], rows: 24, cols: 80)
        defer { pty.close() }
        let before = try pty.settings()
        XCTAssertTrue(pty.waitFor("ready"), pty.text)
        XCTAssertEqual(pty.wait(seconds: 10), 1, pty.text)
        XCTAssertTrue(pty.waitFor("lifetime expired"), pty.text)
        XCTAssertTrue(sameSettings(before, try pty.settings()))
    }

    func testHostTerminationRestoresTheTerminal() throws {
        let harness = try TerminalHarness()
        defer { harness.close() }
        let pty = try PTYProcess(home: harness.home, args: ["exec", "-t", "demo", "--", "top"], rows: 24, cols: 80)
        defer { pty.close() }
        let before = try pty.settings()
        XCTAssertTrue(pty.waitFor("ready"), pty.text)
        kill(pty.process.processIdentifier, SIGTERM)
        XCTAssertEqual(pty.wait(), 128 + SIGTERM, pty.text)
        XCTAssertTrue(sameSettings(before, try pty.settings()))
        // Closing the connection cancels only that command; the sandbox keeps running.
        XCTAssertTrue(waitUntil(3) { !harness.backend.cancelled.isEmpty })
        XCTAssertEqual(try harness.client.ps().first { $0.name == "demo" }?.phase, .running)
    }

    func testShellSessionKeepsTheSandboxAndRestoresTheTerminal() throws {
        let harness = try TerminalHarness()
        defer { harness.close() }
        let pty = try PTYProcess(home: harness.home, args: ["shell", "demo"], rows: 33, cols: 101)
        defer { pty.close() }
        let before = try pty.settings()
        XCTAssertTrue(pty.waitFor("ready"), pty.text)
        XCTAssertEqual(try pty.settings().c_lflag & tcflag_t(ICANON | ECHO | ISIG), 0, "host terminal is raw in the shell")
        let request = try XCTUnwrap(harness.backend.requests.last)
        XCTAssertEqual(request.argv, guestShellArgv)
        XCTAssertEqual(request.terminal, TerminalSize(rows: 33, cols: 101))
        XCTAssertEqual(request.timeoutSeconds, 0)
        XCTAssertEqual(request.cwd, "/", "a raw sandbox starts in /")
        XCTAssertTrue(request.streamStdin)
        pty.type("ab")
        XCTAssertTrue(pty.waitFor("ab"), pty.text)
        pty.resize(rows: 40, cols: 120)
        XCTAssertTrue(pty.waitFor("size 40 120"), pty.text)
        // Ctrl-C interrupts the shell's foreground child; the shell keeps reading.
        pty.type("\u{03}")
        XCTAssertTrue(pty.waitFor("^C"), pty.text)
        XCTAssertTrue(harness.backend.signals.isEmpty, "Ctrl-C reached the guest terminal as a byte")
        usleep(200_000)
        XCTAssertTrue(pty.process.isRunning, "the shell outlived Ctrl-C")
        pty.type("q")
        XCTAssertEqual(pty.wait(), 0, pty.text)
        XCTAssertTrue(pty.waitFor("left the shell; demo is still running"), pty.text)
        XCTAssertTrue(pty.text.contains("dynocap finish demo") && pty.text.contains("dynocap rm demo --force"), pty.text)
        XCTAssertTrue(sameSettings(before, try pty.settings()))
        XCTAssertEqual(harness.backend.cancelled, [])
        XCTAssertEqual(try harness.client.ps().first { $0.name == "demo" }?.phase, .running, "leaving does not end the sandbox")
        // The same sandbox takes another session.
        let again = try PTYProcess(home: harness.home, args: ["shell", "demo"], rows: 24, cols: 80)
        defer { again.close() }
        XCTAssertTrue(again.waitFor("ready"), again.text)
        again.type("q")
        XCTAssertEqual(again.wait(), 0, again.text)
    }

    func testShellOpensInTheProjectWorkspace() throws {
        let harness = try TerminalHarness()
        defer { harness.close() }
        let directory = harness.home.appendingPathComponent("tasks/demo")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = TaskRecord(id: "demo", name: "proj", phase: "running", runtimeDigest: "digest",
                                createdAtUnix: unixNow(), expiresAtUnix: unixNow() + 86400, network: .none)
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("task.json"))
        let pty = try PTYProcess(home: harness.home, args: ["shell", "proj"], rows: 24, cols: 80)
        defer { pty.close() }
        XCTAssertTrue(pty.waitFor("ready"), pty.text)
        let request = try XCTUnwrap(harness.backend.requests.last)
        XCTAssertEqual(request.name, "demo")
        XCTAssertEqual(request.cwd, "/workspace")
        pty.type("q")
        XCTAssertEqual(pty.wait(), 0, pty.text)
        XCTAssertTrue(pty.waitFor("proj is still running"), pty.text)
    }

    func testFailingShellExitPropagatesItsStatus() throws {
        let harness = try TerminalHarness()
        defer { harness.close() }
        let pty = try PTYProcess(home: harness.home, args: ["shell", "demo"], rows: 24, cols: 80)
        defer { pty.close() }
        let before = try pty.settings()
        XCTAssertTrue(pty.waitFor("ready"), pty.text)
        pty.type("e")
        XCTAssertEqual(pty.wait(), 3, pty.text)
        XCTAssertTrue(pty.waitFor("left the shell"), pty.text)
        XCTAssertTrue(sameSettings(before, try pty.settings()))
        XCTAssertEqual(try harness.client.ps().first { $0.name == "demo" }?.phase, .running)
    }

    func testShellConnectionLossRestoresTheTerminal() throws {
        let harness = try TerminalHarness()
        defer { harness.close() }
        let pty = try PTYProcess(home: harness.home, args: ["shell", "demo"], rows: 24, cols: 80)
        defer { pty.close() }
        let before = try pty.settings()
        XCTAssertTrue(pty.waitFor("ready"), pty.text)
        pty.type("x")
        XCTAssertEqual(pty.wait(), 1, pty.text)
        XCTAssertTrue(pty.waitFor("guest agent connection lost"), pty.text)
        XCTAssertFalse(pty.text.contains("left the shell"), "a lost session is an error, not a normal exit")
        XCTAssertTrue(sameSettings(before, try pty.settings()))
    }

    func testShellEndsWhenTheSandboxExpires() throws {
        let harness = try TerminalHarness()
        defer { harness.close() }
        _ = try harness.client.run(RunRequest(name: "short", cpus: 1, memoryMB: 256, ttlSeconds: 2, bootTimeoutSeconds: 5))
        let pty = try PTYProcess(home: harness.home, args: ["shell", "short"], rows: 24, cols: 80)
        defer { pty.close() }
        let before = try pty.settings()
        XCTAssertTrue(pty.waitFor("ready"), pty.text)
        XCTAssertEqual(pty.wait(seconds: 10), 1, pty.text)
        XCTAssertTrue(pty.waitFor("lifetime expired"), pty.text)
        XCTAssertFalse(pty.text.contains("left the shell"), pty.text)
        XCTAssertTrue(sameSettings(before, try pty.settings()))
    }

    func testTerminalSessionWarnsOnceBeforeExpiryWithoutTouchingTheGuest() throws {
        let harness = try TerminalHarness()
        defer { harness.close() }
        _ = try harness.client.run(RunRequest(name: "short", cpus: 1, memoryMB: 256, ttlSeconds: 3, bootTimeoutSeconds: 5))
        for args in [["shell", "short"], ["exec", "-t", "short", "--timeout", "30", "--", "top"]] {
            let pty = try PTYProcess(home: harness.home, args: args, rows: 24, cols: 80)
            defer { pty.close() }
            let before = try pty.settings()
            XCTAssertTrue(pty.waitFor("short expires in"), pty.text)
            if args[0] == "shell" { pty.type("ab") }
            XCTAssertEqual(pty.wait(seconds: 10), 1, pty.text)
            XCTAssertEqual(pty.text.components(separatedBy: "expires in").count - 1, 1, "one warning, not repeated: \(pty.text)")
            XCTAssertTrue(pty.text.contains("\r\ndynocap: short expires in "), pty.text)
            XCTAssertTrue(pty.waitFor("short lifetime expired; its unexported edits are lost"), pty.text)
            XCTAssertTrue(pty.text.contains("own retention deadline"), pty.text)
            XCTAssertTrue(sameSettings(before, try pty.settings()))
            if args[0] == "exec" { break }
            // The sandbox is gone, so the exec form below is refused at admission instead.
            _ = try harness.client.run(RunRequest(name: "short", cpus: 1, memoryMB: 256, ttlSeconds: 3, bootTimeoutSeconds: 5))
        }
        XCTAssertFalse((String(bytes: harness.backend.input, encoding: .utf8) ?? "").contains("dynocap"), "nothing was injected into guest input")
    }

    func testOrdinaryExecDoesNotWarn() throws {
        let harness = try TerminalHarness()
        defer { harness.close() }
        _ = try harness.client.run(RunRequest(name: "short", cpus: 1, memoryMB: 256, ttlSeconds: 2, bootTimeoutSeconds: 5))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DYNOCAP_BIN"] ?? ".build/debug/dynocap")
        process.arguments = ["--home", harness.home.path, "exec", "short", "--timeout", "30", "--", "top"]
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 1)
        let text = String(bytes: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("expires in"), "stderr carries guest data without a terminal: \(text)")
        XCTAssertTrue(text.contains("lifetime expired; its unexported edits are lost"), text)
        XCTAssertEqual(stdout.fileHandleForReading.readDataToEndOfFile(), Data())
    }

    func testShellWithoutATerminalIsRejectedWithoutStartingADaemon() throws {
        let home = URL(fileURLWithPath: "/tmp/dynocap-shell-pipe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DYNOCAP_BIN"] ?? ".build/debug/dynocap")
        process.arguments = ["--home", home.path, "shell", "demo"]
        process.standardInput = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 2)
        let text = String(bytes: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("shell requires a terminal on stdin and stdout"), text)
        XCTAssertTrue(text.contains("dynocap exec NAME -- COMMAND"), text)
        XCTAssertEqual(stdout.fileHandleForReading.readDataToEndOfFile(), Data())
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path), "no daemon home was created")
    }

    func testPipedInputWithTTYIsRejectedWithoutStartingADaemon() throws {
        let home = URL(fileURLWithPath: "/tmp/dynocap-terminal-pipe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DYNOCAP_BIN"] ?? ".build/debug/dynocap")
        process.arguments = ["--home", home.path, "exec", "-t", "demo", "--", "top"]
        process.standardInput = Pipe()
        let stderr = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 2)
        let text = String(bytes: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("--tty requires a terminal on stdin"), text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path), "no daemon home was created")
    }
    #endif
}

private func waitUntil(_ seconds: TimeInterval, _ ready: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if ready() { return true }
        usleep(10_000)
    }
    return ready()
}

#if os(macOS)
/// PENDIN is transient kernel state: BSD sets it whenever canonical mode is re-enabled.
private func sameSettings(_ left: termios, _ right: termios) -> Bool {
    var a = left
    var b = right
    let local = ~tcflag_t(PENDIN)
    let cc = withUnsafeBytes(of: &a.c_cc) { Data($0) } == withUnsafeBytes(of: &b.c_cc) { Data($0) }
    return cc && a.c_iflag == b.c_iflag && a.c_oflag == b.c_oflag && a.c_cflag == b.c_cflag
        && a.c_lflag & local == b.c_lflag & local
}

/// The actual CLI with stdin, stdout, and stderr on a host PTY pts.
private final class PTYProcess {
    let process = Process()
    private let ptmx: Int32
    private let pts: Int32
    private let lock = NSLock()
    private var output = Data()
    private var stopped = false
    private let reader = DispatchSemaphore(value: 0)

    init(home: URL, args: [String], rows: UInt16, cols: UInt16) throws {
        var ptmx: Int32 = 0
        var pts: Int32 = 0
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&ptmx, &pts, nil, nil, &size) == 0 else { throw DynoCapError("openpty failed") }
        self.ptmx = ptmx
        self.pts = pts
        let handle = FileHandle(fileDescriptor: pts, closeOnDealloc: false)
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DYNOCAP_BIN"] ?? ".build/debug/dynocap")
        process.arguments = ["--home", home.path] + args
        process.standardInput = handle
        process.standardOutput = handle
        process.standardError = handle
        Thread.detachNewThread { [self] in
            defer { reader.signal() }
            var item = pollfd(fd: ptmx, events: Int16(POLLIN), revents: 0)
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                lock.lock()
                let done = stopped
                lock.unlock()
                if done { return }
                guard poll(&item, 1, 20) > 0 else { continue }
                let count = read(ptmx, &buffer, buffer.count)
                if count <= 0 { return }
                lock.lock()
                output.append(contentsOf: buffer[0..<count])
                lock.unlock()
            }
        }
        try process.run()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(bytes: output, encoding: .utf8) ?? ""
    }

    func settings() throws -> termios {
        var value = termios()
        guard tcgetattr(pts, &value) == 0 else { throw DynoCapError("tcgetattr failed") }
        return value
    }

    func apply(_ value: termios) throws {
        var value = value
        guard tcsetattr(pts, TCSANOW, &value) == 0 else { throw DynoCapError("tcsetattr failed") }
    }

    func waitFor(_ needle: String, seconds: TimeInterval = 5) -> Bool {
        waitUntil(seconds) { text.contains(needle) }
    }

    func type(_ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { write(ptmx, $0.baseAddress, $0.count) }
    }

    /// The kernel sends SIGWINCH to a terminal's foreground group; this CLI has
    /// no controlling terminal here, so the harness delivers it directly.
    func resize(rows: UInt16, cols: UInt16) {
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(ptmx, TIOCSWINSZ, &size)
        kill(process.processIdentifier, SIGWINCH)
    }

    func wait(seconds: TimeInterval = 5) -> Int32? {
        guard waitUntil(seconds, { !process.isRunning }) else {
            process.terminate()
            return nil
        }
        return process.terminationStatus
    }

    func close() {
        if process.isRunning { process.terminate() }
        lock.lock()
        stopped = true
        lock.unlock()
        reader.wait()
        _ = Darwin.close(ptmx)
        _ = Darwin.close(pts)
    }
}
#endif

private final class TerminalHarness {
    let home: URL
    let backend = TerminalBackend()
    let daemon: Daemon
    let client: DaemonClient

    init() throws {
        home = URL(fileURLWithPath: "/tmp/dynocap-exec-terminal-\(UUID().uuidString)")
        daemon = Daemon(home: home, backend: backend)
        try daemon.start()
        let paths = daemon.paths
        try FileManager.default.createDirectory(at: paths.imageDir(HostArch.guest), withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: paths.kernel(HostArch.guest).path, contents: Data("kernel".utf8))
        _ = FileManager.default.createFile(atPath: paths.initrd(HostArch.guest).path, contents: Data("initrd".utf8))
        client = DaemonClient(socketPath: paths.socket.path)
        _ = try client.run(RunRequest(name: "demo", cpus: 1, memoryMB: 256, ttlSeconds: 60, bootTimeoutSeconds: 5))
    }

    func close() {
        daemon.stop()
        try? FileManager.default.removeItem(at: home)
    }
}

/// Stands in for a guest terminal: it echoes input, reports resizes, and treats
/// Ctrl-C the way a line discipline would; a shell survives it. `q` exits 0, `e` exits 3,
/// and `x` loses the connection.
private final class TerminalBackend: VMBackend {
    static let rejectedSize = TerminalSize(rows: 1, cols: 1)
    var onGuestExit: ((String, UUID, String?) -> Void)?
    private let lock = NSLock()
    private var emits: [UInt32: (ExecEvent) -> Void] = [:]
    private var _requests: [ExecRequest] = []
    private var _input = Data()
    private var _resizes: [TerminalSize] = []
    private var _signals: [Int32] = []
    private var _cancelled: [UInt32] = []

    var requests: [ExecRequest] { locked { _requests } }
    var input: Data { locked { _input } }
    var resizes: [TerminalSize] { locked { _resizes } }
    var signals: [Int32] { locked { _signals } }
    var cancelled: [UInt32] { locked { _cancelled } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func boot(_ request: BootRequest, completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
    func destroy(name: String, completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }

    func exec(_ request: ExecRequest, emit: @escaping (ExecEvent) -> Void) {
        locked {
            _requests.append(request)
            emits[request.id] = emit
        }
        if request.terminal != nil { emit(.stdout(Data("ready\r\n".utf8))) }
    }

    func writeStdin(name: String, id: UInt32, data: Data) throws {
        let emit = locked { () -> ((ExecEvent) -> Void)? in
            _input.append(data)
            return emits[id]
        }
        let shell = locked { _requests.first { $0.id == id }?.argv == guestShellArgv }
        for byte in data {
            switch byte {
            case 0x03 where shell:
                // A shell's foreground child gets SIGINT; the shell itself keeps reading.
                emit?(.stdout(Data("^C\r\n".utf8)))
            case 0x03:
                emit?(.stdout(Data("^C\r\n".utf8)))
                emit?(.finished(code: -1, signal: SIGINT))
            case UInt8(ascii: "q"):
                emit?(.finished(code: 0, signal: 0))
            case UInt8(ascii: "x"):
                emit?(.failed("guest agent connection lost"))
            case UInt8(ascii: "e"):
                emit?(.finished(code: 3, signal: 0))
            default:
                emit?(.stdout(Data([byte])))
            }
        }
    }

    func resizeExec(name: String, id: UInt32, size: TerminalSize) throws {
        if size == Self.rejectedSize { throw DynoCapError("guest agent cannot allocate terminals; rebuild the guest image") }
        let emit = locked { () -> ((ExecEvent) -> Void)? in
            _resizes.append(size)
            return emits[id]
        }
        emit?(.stdout(Data("size \(size.rows) \(size.cols)\r\n".utf8)))
    }

    func signalExec(name: String, id: UInt32, signal: Int32) throws {
        locked { _signals.append(signal) }
    }

    func cancelExec(name: String, id: UInt32) {
        locked { _cancelled.append(id) }
    }
}
