import XCTest

@testable import MicroVMCore

final class ExecInputTests: XCTestCase {
    func testInteractiveAndNoInputFlags() throws {
        guard case .exec(let interactive) = try parseCommand(["microvm", "exec", "-i", "demo", "--", "cat"]).command else {
            return XCTFail("expected exec")
        }
        XCTAssertEqual(interactive.input, "interactive")
        guard case .exec(let long) = try parseCommand(["microvm", "exec", "--interactive", "demo", "--", "sh"]).command else {
            return XCTFail("expected exec")
        }
        XCTAssertEqual(long.input, "interactive")
        guard case .exec(let closed) = try parseCommand(["microvm", "exec", "--no-input", "demo", "--", "cat"]).command else {
            return XCTFail("expected exec")
        }
        XCTAssertEqual(closed.input, "none")
        XCTAssertThrowsError(try parseCommand(["microvm", "exec", "-i", "--no-input", "demo", "--", "cat"]))
    }

    func testInputModeFollowsTheTerminalWhenUnset() {
        XCTAssertEqual(resolveExecInput(requested: nil, stdinIsTerminal: true), "none")
        XCTAssertEqual(resolveExecInput(requested: nil, stdinIsTerminal: false), "pipe")
        XCTAssertEqual(resolveExecInput(requested: "interactive", stdinIsTerminal: true), "interactive")
        XCTAssertEqual(resolveExecInput(requested: "none", stdinIsTerminal: false), "none")
        XCTAssertEqual(resolveExecInput(requested: "pipe", stdinIsTerminal: true), "pipe")
    }

    func testExecHelpDocumentsStdinAndWorkingDirectories() {
        let help = commandHelp(["exec"])
        XCTAssertTrue(help.contains("--interactive"))
        XCTAssertTrue(help.contains("--no-input"))
        XCTAssertTrue(help.contains("EOF"))
        XCTAssertTrue(help.contains("/workspace"))
        XCTAssertTrue(help.contains("raw sandboxes"))
    }

    func testControlStdinFramesRoundTrip() throws {
        let payload = Data([0, 255, 10])
        let stdin = try ControlCodec.encode(.stdin(payload))
        guard case .stdin(let decoded) = try ControlCodec.decode(stdin) else { return XCTFail("expected stdin") }
        XCTAssertEqual(decoded, payload)
        let eof = try ControlCodec.encode(.stdinEOF)
        guard case .stdinEOF = try ControlCodec.decode(eof) else { return XCTFail("expected stdin EOF") }
    }

    func testMissingExecStreamCapabilityIsRejected() {
        XCTAssertThrowsError(try validateExecStreamCapability(Data(#"{"ok":true}"#.utf8))) { error in
            let micro = error as? MicroVMError
            XCTAssertEqual(micro?.code, .incompatibleDaemon)
            XCTAssertTrue(micro?.message.contains("exec stream v1") == true)
        }
    }

    func testRunningDaemonAdvertisesExecStream() throws {
        let harness = try ExecInputHarness()
        defer { harness.close() }
        let fd = try POSIX.connectUnix(harness.daemon.paths.socket.path)
        defer { _ = closeFD(fd) }
        try ControlCodec.write(fd, .ping)
        guard case .result(let data) = try ControlCodec.read(fd) else { return XCTFail("expected ping result") }
        XCTAssertNoThrow(try validateExecStreamCapability(data))
    }

    func testRawSandboxDefaultsToRootAndOverrideWins() throws {
        let harness = try ExecInputHarness()
        defer { harness.close() }
        _ = try harness.client.exec(ExecCommand(name: "demo", argv: ["pwd"], env: [], cwd: "", timeoutSeconds: 5))
        XCTAssertEqual(harness.backend.lastRequest?.cwd, "/")
        XCTAssertEqual(harness.backend.lastRequest?.streamStdin, false)
        _ = try harness.client.exec(ExecCommand(name: "demo", argv: ["pwd"], env: [], cwd: "/var/tmp", timeoutSeconds: 5))
        XCTAssertEqual(harness.backend.lastRequest?.cwd, "/var/tmp")
    }

    func testPipedStdinStreamsBeforeTheRestIsProduced() throws {
        let harness = try ExecInputHarness()
        defer { harness.close() }
        harness.backend.mode = .echoThenClose
        let total = 300 * 1024
        let first = 32 * 1024
        let gate = DispatchSemaphore(value: 0)
        var sent = 0
        var outputArrivedEarly = false
        let outcome = try harness.client.exec(
            ExecCommand(name: "demo", argv: ["cat"], env: [], cwd: "/tmp", timeoutSeconds: 5, input: "pipe"),
            readStdin: { _ in
                if sent == 0 {
                    sent = first
                    return Data(repeating: 0x61, count: first)
                }
                if sent == first {
                    XCTAssertEqual(gate.wait(timeout: .now() + 2), .success)
                    outputArrivedEarly = true
                    sent = total
                    return Data(repeating: 0x62, count: total - first)
                }
                return nil
            },
            onStdout: { data in
                if data == Data("out".utf8) { gate.signal() }
            }
        )
        XCTAssertTrue(outputArrivedEarly)
        XCTAssertEqual(outcome.code, 0)
        XCTAssertEqual(outcome.signal, 0)
        XCTAssertEqual(String(data: outcome.stdout, encoding: .utf8), "out")
        XCTAssertEqual(String(data: outcome.stderr, encoding: .utf8), "err")
        XCTAssertEqual(harness.backend.stdin.count, total)
        XCTAssertGreaterThan(harness.backend.chunkSizes.count, 1)
        XCTAssertLessThanOrEqual(harness.backend.chunkSizes.max() ?? 0, 32 * 1024)
        XCTAssertTrue(harness.backend.closedStdin)
        XCTAssertEqual(harness.backend.lastRequest?.cwd, "/tmp")
    }

    func testEarlyGuestExitUnblocksFurtherInput() throws {
        let harness = try ExecInputHarness()
        defer { harness.close() }
        harness.backend.mode = .exitOnFirstStdin
        var calls = 0
        let outcome = try harness.client.exec(
            ExecCommand(name: "demo", argv: ["cat"], env: [], cwd: "", timeoutSeconds: 5, input: "pipe"),
            readStdin: { control in
                calls += 1
                if control.isStopped { return nil }
                if calls == 1 { return Data(repeating: 0x63, count: 64 * 1024) }
                return nil
            }
        )
        XCTAssertEqual(outcome.code, 3)
        XCTAssertEqual(String(data: outcome.stdout, encoding: .utf8), "partial")
        XCTAssertEqual(String(data: outcome.stderr, encoding: .utf8), "bye")
        XCTAssertLessThan(harness.backend.stdin.count, 300 * 1024)
    }

    func testDisconnectDuringStdinCancelsOnlyThatExec() throws {
        let harness = try ExecInputHarness()
        defer { harness.close() }
        harness.backend.mode = .hang
        let fd = try POSIX.connectUnix(harness.daemon.paths.socket.path)
        let command = ExecCommand(name: "demo", argv: ["sleep", "30"], env: [], cwd: "", timeoutSeconds: 30, input: "pipe")
        try ControlCodec.write(fd, .exec(command))
        let started = Date().addingTimeInterval(2)
        while harness.backend.lastRequest == nil && Date() < started { usleep(10_000) }
        XCTAssertEqual(harness.backend.lastRequest?.streamStdin, true)
        _ = closeFD(fd)
        let deadline = Date().addingTimeInterval(2)
        while !harness.backend.cancelled && Date() < deadline { usleep(10_000) }
        XCTAssertTrue(harness.backend.cancelled)
        XCTAssertEqual(try harness.client.ps().map(\.phase), [.running])
        harness.backend.mode = .finishImmediately
        let outcome = try harness.client.exec(ExecCommand(name: "demo", argv: ["true"], env: [], cwd: "", timeoutSeconds: 5))
        XCTAssertEqual(outcome.code, 0)
    }

    func testTimeoutDuringOpenStdinDoesNotBlockTheSandbox() throws {
        let harness = try ExecInputHarness()
        defer { harness.close() }
        harness.backend.mode = .hang
        XCTAssertThrowsError(
            try harness.client.exec(
                ExecCommand(name: "demo", argv: ["sleep", "30"], env: [], cwd: "", timeoutSeconds: 1, input: "pipe"),
                readStdin: { control in
                    while !control.isStopped { usleep(10_000) }
                    return nil
                }
            )
        ) { error in
            XCTAssertEqual((error as? MicroVMError)?.exitCode, 124)
        }
        XCTAssertTrue(harness.backend.cancelled)
        harness.backend.mode = .finishImmediately
        harness.backend.cancelled = false
        let outcome = try harness.client.exec(ExecCommand(name: "demo", argv: ["true"], env: [], cwd: "", timeoutSeconds: 5))
        XCTAssertEqual(outcome.code, 0)
        XCTAssertEqual(try harness.client.ps().first?.phase, .running)
    }
}

private final class ExecInputHarness {
    let home: URL
    let backend: StreamingBackend
    let daemon: Daemon
    let client: DaemonClient

    init() throws {
        home = URL(fileURLWithPath: "/tmp/microvm-exec-input-\(UUID().uuidString)")
        backend = StreamingBackend()
        daemon = Daemon(home: home, backend: backend)
        try daemon.start()
        let paths = daemon.paths
        let dir = paths.imageDir(HostArch.guest)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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

private final class StreamingBackend: VMBackend {
    enum Mode {
        case finishImmediately
        case echoThenClose
        case exitOnFirstStdin
        case hang
    }

    var onGuestExit: ((String, UUID, String?) -> Void)?
    var mode: Mode = .finishImmediately
    var lastRequest: ExecRequest?
    var stdin = Data()
    var chunkSizes: [Int] = []
    var closedStdin = false
    var cancelled = false
    private let lock = NSLock()
    private var emit: ((ExecEvent) -> Void)?

    func boot(_ request: BootRequest, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }

    func exec(_ request: ExecRequest, emit: @escaping (ExecEvent) -> Void) {
        lock.lock()
        lastRequest = request
        self.emit = emit
        let mode = mode
        lock.unlock()
        if mode == .finishImmediately {
            emit(.stdout(Data((request.argv.joined(separator: " ") + "\n").utf8)))
            emit(.finished(code: 0, signal: 0))
        }
    }

    func writeStdin(name: String, id: UInt32, data: Data) throws {
        lock.lock()
        stdin.append(data)
        chunkSizes.append(data.count)
        let first = chunkSizes.count == 1
        let mode = mode
        let emit = emit
        lock.unlock()
        switch mode {
        case .echoThenClose where first:
            emit?(.stdout(Data("out".utf8)))
            emit?(.stderr(Data("err".utf8)))
        case .exitOnFirstStdin where first:
            emit?(.stdout(Data("partial".utf8)))
            emit?(.stderr(Data("bye".utf8)))
            emit?(.finished(code: 3, signal: 0))
        default:
            break
        }
    }

    func closeStdin(name: String, id: UInt32) throws {
        lock.lock()
        closedStdin = true
        let mode = mode
        let emit = emit
        lock.unlock()
        if mode == .echoThenClose {
            emit?(.finished(code: 0, signal: 0))
        }
    }

    func cancelExec(name: String, id: UInt32) {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func destroy(name: String, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }
}
