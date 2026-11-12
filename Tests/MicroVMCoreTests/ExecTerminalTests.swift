import XCTest

#if canImport(Darwin)
import Darwin
#endif

@testable import MicroVMCore

final class ExecTerminalTests: XCTestCase {
    func testTerminalFlagsImplyLiveInputAndRejectNoInput() throws {
        for flags in [["-t"], ["--tty"], ["-it"], ["-ti"], ["-i", "-t"], ["-t", "-i"]] {
            guard case .exec(let command) = try parseCommand(["microvm", "exec"] + flags + ["demo", "--", "top"]).command else {
                return XCTFail("expected exec for \(flags)")
            }
            XCTAssertEqual(command.terminal, TerminalSize(rows: 0, cols: 0), "\(flags)")
            XCTAssertEqual(command.input, "interactive", "\(flags)")
            XCTAssertEqual(command.argv, ["top"])
        }
        guard case .exec(let guest) = try parseCommand(["microvm", "exec", "demo", "--", "ls", "-t"]).command else {
            return XCTFail("expected exec")
        }
        XCTAssertNil(guest.terminal, "guest arguments after -- are not microvm flags")
        XCTAssertEqual(guest.argv, ["ls", "-t"])
        for flags in [["-t", "--no-input"], ["--no-input", "-t"], ["--no-input", "-it"], ["--tty=yes"]] {
            XCTAssertThrowsError(try parseCommand(["microvm", "exec"] + flags + ["demo", "--", "sh"]), "\(flags)") { error in
                XCTAssertEqual((error as? MicroVMError)?.exitCode, 2)
            }
        }
    }

    func testExecHelpDocumentsTerminalMode() {
        let help = commandHelp(["exec"])
        for text in ["-t", "--tty", "raw mode", "restored", "resizes", "combined", "terminal on stdin", "xterm-256color"] {
            XCTAssertTrue(help.contains(text), text)
        }
    }

    func testNonTerminalInputIsRefusedBeforeDaemonWork() throws {
        var command = ExecCommand(name: "demo", argv: ["top"], env: [], cwd: "", timeoutSeconds: 5)
        XCTAssertNoThrow(try requireTerminalInput(command, stdinIsTerminal: false))
        command.terminal = TerminalSize(rows: 0, cols: 0)
        XCTAssertNoThrow(try requireTerminalInput(command, stdinIsTerminal: true))
        XCTAssertThrowsError(try requireTerminalInput(command, stdinIsTerminal: false)) { error in
            let micro = error as? MicroVMError
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
            XCTAssertEqual(($0 as? MicroVMError)?.code, .incompatibleDaemon)
        }
        XCTAssertTrue(guestAgentAllocatesTerminals("microvm-agent signal=1 tty=1"))
        XCTAssertFalse(guestAgentAllocatesTerminals("microvm-agent signal=1"))
        XCTAssertFalse(guestAgentAllocatesTerminals("microvm-agent tty=10"))
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
        let home = URL(fileURLWithPath: "/tmp/microvm-terminal-logs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = MicroVMPaths(home: home)
        try paths.ensure()
        let now = unixNow()
        var record = TaskRecord(id: "task-tty", name: "demo", phase: "running", runtimeDigest: "digest", createdAtUnix: now,
                                expiresAtUnix: now + 86400, network: .none)
        record.commands = []
        let directory = home.appendingPathComponent("tasks/task-tty")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = TaskManager(paths: paths, arch: HostArch.guest, boot: { _ in throw MicroVMError("boot") },
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

    func testPipedInputWithTTYIsRejectedWithoutStartingADaemon() throws {
        let home = URL(fileURLWithPath: "/tmp/microvm-terminal-pipe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MICROVM_BIN"] ?? ".build/debug/microvm")
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
        guard openpty(&ptmx, &pts, nil, nil, &size) == 0 else { throw MicroVMError("openpty failed") }
        self.ptmx = ptmx
        self.pts = pts
        let handle = FileHandle(fileDescriptor: pts, closeOnDealloc: false)
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MICROVM_BIN"] ?? ".build/debug/microvm")
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
        guard tcgetattr(pts, &value) == 0 else { throw MicroVMError("tcgetattr failed") }
        return value
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
        home = URL(fileURLWithPath: "/tmp/microvm-exec-terminal-\(UUID().uuidString)")
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
/// Ctrl-C the way a line discipline would. `q` exits 0; `x` loses the connection.
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
        for byte in data {
            switch byte {
            case 0x03:
                emit?(.stdout(Data("^C\r\n".utf8)))
                emit?(.finished(code: -1, signal: SIGINT))
            case UInt8(ascii: "q"):
                emit?(.finished(code: 0, signal: 0))
            case UInt8(ascii: "x"):
                emit?(.failed("guest agent connection lost"))
            default:
                emit?(.stdout(Data([byte])))
            }
        }
    }

    func resizeExec(name: String, id: UInt32, size: TerminalSize) throws {
        if size == Self.rejectedSize { throw MicroVMError("guest agent cannot allocate terminals; rebuild the guest image") }
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
