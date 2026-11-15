import XCTest

@testable import DynoCapCore

final class ExecSignalTests: XCTestCase {
    func testFirstInterruptForwardsSIGINTAndTheNextAborts() {
        var forwarded: [Int32] = []
        var aborted = 0
        let interrupt = ExecInterrupt()
        interrupt.bind(forward: { forwarded.append($0) }, abort: { aborted += 1 })
        interrupt.deliver(count: 1)
        interrupt.deliver(count: 2)
        XCTAssertEqual(forwarded, [SIGINT])
        XCTAssertEqual(aborted, 1)
        XCTAssertEqual(cliExitStatus(code: 0, signal: SIGINT), 130)
        XCTAssertEqual(cliExitStatus(code: 3, signal: 0), 3)
    }

    func testExecHelpDocumentsInterruptStatus() {
        let help = commandHelp(["exec"])
        XCTAssertTrue(help.contains("Ctrl-C"))
        XCTAssertTrue(help.contains("130"))
        XCTAssertTrue(help.contains("does not destroy the sandbox"))
    }

    func testGuestSignalCapabilityAndControlFrame() throws {
        XCTAssertTrue(guestAgentDeliversSignals("dynocap-agent signal=1"))
        XCTAssertFalse(guestAgentDeliversSignals("dynocap-agent"))
        XCTAssertFalse(guestAgentDeliversSignals("dynocap-agent signal=10"))
        let frame = try ControlCodec.encode(.signal(SIGINT))
        guard case .signal(let signal) = try ControlCodec.decode(frame) else {
            return XCTFail("expected signal")
        }
        XCTAssertEqual(signal, SIGINT)
        XCTAssertThrowsError(try validateExecSignalCapability(Data(#"{"ok":true,"execStreamVersion":1}"#.utf8))) { error in
            let micro = error as? DynoCapError
            XCTAssertEqual(micro?.code, .incompatibleDaemon)
            XCTAssertTrue(micro?.message.contains("guest signals") == true)
        }
    }

    func testGuestSignalFrameRoundTrip() throws {
        let message = GuestMessage.signal(id: 7, signal: SIGINT)
        let encoded = try GuestProtocol.encodeFrame(message)
        XCTAssertEqual(try GuestProtocol.decodeFrame(encoded), message)
    }

    func testRunningDaemonAdvertisesSignalForwarding() throws {
        let harness = try SignalHarness()
        defer { harness.close() }
        let fd = try POSIX.connectUnix(harness.daemon.paths.socket.path)
        defer { _ = closeFD(fd) }
        try ControlCodec.write(fd, .ping)
        guard case .result(let data) = try ControlCodec.read(fd) else { return XCTFail("expected ping result") }
        XCTAssertNoThrow(try validateExecSignalCapability(data))
    }

    func testSignalReachesOnlyTheSelectedExec() throws {
        let harness = try SignalHarness()
        defer { harness.close() }
        _ = try harness.client.run(RunRequest(name: "other", cpus: 1, memoryMB: 256, ttlSeconds: 60, bootTimeoutSeconds: 5))
        let demo = try POSIX.connectUnix(harness.daemon.paths.socket.path)
        let other = try POSIX.connectUnix(harness.daemon.paths.socket.path)
        defer {
            _ = closeFD(demo)
            _ = closeFD(other)
        }
        try ControlCodec.write(demo, .exec(ExecCommand(name: "demo", argv: ["sleep", "30"], env: [], cwd: "", timeoutSeconds: 30)))
        try ControlCodec.write(other, .exec(ExecCommand(name: "other", argv: ["sleep", "30"], env: [], cwd: "", timeoutSeconds: 30)))
        XCTAssertTrue(waitUntil(2) { harness.backend.execs.count == 2 })
        try ControlCodec.write(demo, .signal(SIGINT))
        XCTAssertTrue(waitUntil(2) { harness.backend.signals.count == 1 })
        XCTAssertEqual(harness.backend.signals.map(\.name), ["demo"])
        XCTAssertEqual(harness.backend.signals.map(\.signal), [SIGINT])
        XCTAssertTrue(harness.backend.cancelled.isEmpty)
        XCTAssertFalse(harness.backend.destroyed)
        XCTAssertEqual(Set(try harness.client.ps().map(\.name)), ["demo", "other"])
        XCTAssertEqual(Set(try harness.client.ps().map(\.phase)), [.running])
    }

    func testUnsupportedGuestSignalDoesNotCancelOrDestroy() throws {
        let harness = try SignalHarness()
        defer { harness.close() }
        harness.backend.rejectSignal = true
        let fd = try POSIX.connectUnix(harness.daemon.paths.socket.path)
        defer { _ = closeFD(fd) }
        try receiveTimeout(fd, seconds: 2)
        try ControlCodec.write(fd, .exec(ExecCommand(name: "demo", argv: ["sleep", "30"], env: [], cwd: "", timeoutSeconds: 30)))
        XCTAssertTrue(waitUntil(2) { harness.backend.execs.count == 1 })
        try ControlCodec.write(fd, .signal(SIGINT))
        guard case .stderr(let data) = try ControlCodec.read(fd) else { return XCTFail("expected a signal rejection") }
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("cannot deliver signals"))
        XCTAssertTrue(harness.backend.signals.isEmpty)
        XCTAssertTrue(harness.backend.cancelled.isEmpty)
        XCTAssertFalse(harness.backend.destroyed)
        XCTAssertEqual(try harness.client.ps().map(\.phase), [.running])
    }

    func testSignalAfterStdinEOFStillForwards() throws {
        let harness = try SignalHarness()
        defer { harness.close() }
        let fd = try POSIX.connectUnix(harness.daemon.paths.socket.path)
        defer { _ = closeFD(fd) }
        var command = ExecCommand(name: "demo", argv: ["cat"], env: [], cwd: "", timeoutSeconds: 30)
        command.input = "pipe"
        try ControlCodec.write(fd, .exec(command))
        XCTAssertTrue(waitUntil(2) { harness.backend.execs.count == 1 })
        try ControlCodec.write(fd, .stdinEOF)
        try ControlCodec.write(fd, .signal(SIGTERM))
        XCTAssertTrue(waitUntil(2) { harness.backend.signals.count == 1 })
        XCTAssertEqual(harness.backend.signals.first?.signal, SIGTERM)
        XCTAssertTrue(harness.backend.closedStdin)
        XCTAssertTrue(harness.backend.cancelled.isEmpty)
        XCTAssertFalse(harness.backend.destroyed)
    }
}

private func waitUntil(_ seconds: TimeInterval, _ ready: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if ready() { return true }
        usleep(10_000)
    }
    return ready()
}

private func receiveTimeout(_ fd: Int32, seconds: Int) throws {
    var timeout = timeval(tv_sec: seconds, tv_usec: 0)
    let result = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    if result != 0 { throw DynoCapError("cannot set receive timeout") }
}

private final class SignalHarness {
    let home: URL
    let backend: SignalBackend
    let daemon: Daemon
    let client: DaemonClient

    init() throws {
        home = URL(fileURLWithPath: "/tmp/dynocap-exec-signal-\(UUID().uuidString)")
        backend = SignalBackend()
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

private final class SignalBackend: VMBackend {
    var onGuestExit: ((String, UUID, String?) -> Void)?
    var rejectSignal = false
    var closedStdin = false
    var destroyed = false
    private(set) var execs: [(name: String, id: UInt32)] = []
    private(set) var signals: [(name: String, id: UInt32, signal: Int32)] = []
    private(set) var cancelled: [(name: String, id: UInt32)] = []
    private let lock = NSLock()

    func boot(_ request: BootRequest, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }

    func exec(_ request: ExecRequest, emit: @escaping (ExecEvent) -> Void) {
        lock.lock()
        execs.append((request.name, request.id))
        lock.unlock()
    }

    func signalExec(name: String, id: UInt32, signal: Int32) throws {
        if rejectSignal {
            throw DynoCapError("guest agent cannot deliver signals; rebuild the guest image")
        }
        lock.lock()
        signals.append((name, id, signal))
        lock.unlock()
    }

    func closeStdin(name: String, id: UInt32) throws {
        lock.lock()
        closedStdin = true
        lock.unlock()
    }

    func cancelExec(name: String, id: UInt32) {
        lock.lock()
        cancelled.append((name, id))
        lock.unlock()
    }

    func destroy(name: String, completion: @escaping (Result<Void, Error>) -> Void) {
        lock.lock()
        destroyed = true
        lock.unlock()
        completion(.success(()))
    }
}
