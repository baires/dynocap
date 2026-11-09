import XCTest
@testable import MicroVMCore

final class IsolationPolicyTests: XCTestCase {
    func testDefaultsExplicitNATAndTTLBoundaries() throws {
        let fixture = try PolicyFixture()
        defer { fixture.close() }
        let status = try fixture.client.run(fixture.request("offline"))
        XCTAssertEqual(status.network, NetworkMode.none)
        XCTAssertEqual(status.ttlSeconds, 1800)
        XCTAssertEqual(fixture.backend.request("offline")?.network, NetworkMode.none)
        var nat = fixture.request("online")
        nat.network = .nat
        nat.ttlSeconds = 86400
        let online = try fixture.client.run(nat)
        XCTAssertEqual(online.network, .nat)
        XCTAssertEqual(online.ttlSeconds, 86400)
        let records = try fixture.client.ps()
        XCTAssertEqual(records.first { $0.name == "offline" }?.network, NetworkMode.none)
        let table = formatProcessTable(records, now: unixNow())
        XCTAssertTrue(table.contains("NETWORK"))
        XCTAssertTrue(table.contains("TTL_SEC"))
        XCTAssertTrue(table.contains("1800"))
        XCTAssertEqual(try IsolationPolicy.ttl(1), 1)
        XCTAssertEqual(try IsolationPolicy.ttl(nil), 1800)
        for value in [0, -1, 86401, Int.max] { XCTAssertThrowsError(try IsolationPolicy.ttl(value)) }
    }

    func testMalformedRawRequestsNeverCreateResources() throws {
        let fixture = try PolicyFixture()
        defer { fixture.close() }
        for override: [String: Any] in [
            ["network": "public"], ["ttlSeconds": 0], ["ttlSeconds": -1],
            ["ttlSeconds": 86401], ["ttlSeconds": 1.5], ["ttlSeconds": "1800"],
        ] {
            var body: [String: Any] = ["name": "invalid", "cpus": 1, "memoryMB": 256, "bootTimeoutSeconds": 5]
            body.merge(override) { _, new in new }
            let fd = try POSIX.connectUnix(fixture.daemon.paths.socket.path)
            defer { _ = closeFD(fd) }
            let payload = try JSONSerialization.data(withJSONObject: body)
            var frame = Data()
            frame.appendU32(UInt32(payload.count + 1))
            frame.append(ControlType.run)
            frame.append(payload)
            try POSIX.writeAll(fd, frame)
            guard case .error = try ControlCodec.read(fd) else { return XCTFail("invalid request accepted") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.daemon.paths.vmDir("invalid").path))
            XCTAssertNil(fixture.backend.request("invalid"))
        }
        // Explicit JSON null has the same default as omission.
        let null = Data("{\"name\":\"null\",\"cpus\":1,\"memoryMB\":256,\"bootTimeoutSeconds\":5,\"ttlSeconds\":null}".utf8)
        let request = try JSONDecoder().decode(RunRequest.self, from: null)
        XCTAssertEqual(try fixture.client.run(request).ttlSeconds, 1800)
    }

    func testCLIValidationAndHistoricalRecords() throws {
        let invocation = try parseCommand(["microvm", "run", "--name", "demo", "--network", "nat", "--ttl", "86400"])
        guard case .run(let request) = invocation.command else { return XCTFail("expected run") }
        XCTAssertEqual(request.network, .nat)
        for flags in [["--network", "public"], ["--ttl", "0"], ["--ttl", "86401"], ["--ttl", "1.5"]] {
            XCTAssertThrowsError(try parseCommand(["microvm", "run", "--name", "demo"] + flags))
        }
        let json = Data("{\"name\":\"old\",\"phase\":\"running\",\"cpus\":1,\"memoryMB\":256,\"daemonToken\":\"dead\",\"createdAtUnix\":1}".utf8)
        let historical = try JSONDecoder().decode(VMRecord.self, from: json)
        XCTAssertNil(historical.network)
        XCTAssertTrue(formatProcessTable([historical], now: 2).contains("unknown"))
    }

    func testExpiryTerminatesActiveExecAndRejectsNewExec() throws {
        let fixture = try PolicyFixture()
        defer { fixture.close() }
        var request = fixture.request("short")
        request.ttlSeconds = 1
        _ = try fixture.client.run(request)
        let finished = expectation(description: "exec terminated by lifetime")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do {
                _ = try fixture.client.exec(ExecCommand(
                    name: "short", argv: ["sleep", "100"], env: [], cwd: "", timeoutSeconds: 30
                ))
                XCTFail("expired exec succeeded")
            } catch { XCTAssertTrue(String(describing: error).contains("lifetime expired")) }
        }
        wait(for: [finished], timeout: 4)
        XCTAssertTrue(eventually { (try? fixture.client.ps().isEmpty) == true })
        XCTAssertThrowsError(try fixture.client.exec(ExecCommand(
            name: "short", argv: ["true"], env: [], cwd: "", timeoutSeconds: 5
        )))
    }

    func testExpiryDuringBootAndLateCallbacksCannotResurrectOrStopReplacement() throws {
        let fixture = try PolicyFixture(delayedBoot: true)
        defer { fixture.close() }
        var request = fixture.request("short")
        request.ttlSeconds = 1
        let finished = expectation(description: "expired boot returns failure")
        let short = request
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do {
                _ = try fixture.client.run(short)
                XCTFail("expired boot succeeded")
            } catch {}
        }
        XCTAssertTrue(eventually { fixture.backend.request("short") != nil })
        let generation = try XCTUnwrap(fixture.backend.request("short")?.generation)
        wait(for: [finished], timeout: 4)
        XCTAssertTrue(eventually { (try? fixture.client.ps().isEmpty) == true })
        fixture.backend.finishBoot("short")
        fixture.backend.delayedBoot = false
        _ = try fixture.client.run(fixture.request("short"))
        fixture.daemon.noteGuestExit("short", generation: generation, message: "late exit")
        XCTAssertEqual(try fixture.client.ps().first?.phase, .running)
    }

    func testExpiredRecordCannotAdmitExecBeforeSweep() throws {
        let fixture = try PolicyFixture()
        defer { fixture.close() }
        _ = try fixture.client.run(fixture.request("expired"))
        let store = StateStore(paths: fixture.daemon.paths)
        var record = try XCTUnwrap(store.load("expired"))
        record.createdAtUnix = 1
        try store.save(record)
        XCTAssertThrowsError(try fixture.client.exec(ExecCommand(
            name: "expired", argv: ["true"], env: [], cwd: "", timeoutSeconds: 5
        )))
        XCTAssertEqual(fixture.backend.execCount, 0)
    }

    func testBootSuccessAfterDeadlineNeverReportsRunning() throws {
        let fixture = try PolicyFixture(delayedBoot: true)
        defer { fixture.close() }
        let finished = expectation(description: "late readiness rejected")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do {
                _ = try fixture.client.run(fixture.request("expired"))
                XCTFail("late boot was reported as running")
            } catch {}
        }
        XCTAssertTrue(eventually { fixture.backend.request("expired") != nil })
        let store = StateStore(paths: fixture.daemon.paths)
        var record = try XCTUnwrap(store.load("expired"))
        record.createdAtUnix = 1
        try store.save(record)
        fixture.backend.finishBoot("expired")
        wait(for: [finished], timeout: 3)
        XCTAssertTrue(eventually { (try? fixture.client.ps().isEmpty) == true })
    }

    func testDestroyFailureRetainedAndRetriedWithoutAcceptingExec() throws {
        let fixture = try PolicyFixture(failFirstDestroy: true)
        defer { fixture.close() }
        _ = try fixture.client.run(fixture.request("retry"))
        XCTAssertThrowsError(try fixture.client.destroy("retry"))
        let record = try XCTUnwrap(fixture.client.ps().first)
        XCTAssertEqual(record.phase, .stopping)
        XCTAssertTrue(record.message?.contains("teardown failed") == true)
        XCTAssertThrowsError(try fixture.client.exec(ExecCommand(
            name: "retry", argv: ["true"], env: [], cwd: "", timeoutSeconds: 5
        )))
        XCTAssertTrue(eventually { (try? fixture.client.ps().isEmpty) == true })
        XCTAssertEqual(fixture.backend.destroyCount, 2)
    }

    func testDestroyTimeoutIsFailureAndAutomaticallyRetried() throws {
        let fixture = try PolicyFixture(dropFirstDestroy: true)
        defer { fixture.close() }
        _ = try fixture.client.run(fixture.request("retry"))
        XCTAssertThrowsError(try fixture.client.destroy("retry")) { error in
            XCTAssertTrue(String(describing: error).contains("teardown failed"))
        }
        XCTAssertTrue(eventually { (try? fixture.client.ps().isEmpty) == true })
        XCTAssertEqual(fixture.backend.destroyCount, 2)
    }

    func testConcurrentDestroyIsIdempotent() throws {
        let fixture = try PolicyFixture()
        defer { fixture.close() }
        _ = try fixture.client.run(fixture.request("demo"))
        let finished = expectation(description: "both destroy callers complete")
        finished.expectedFulfillmentCount = 2
        for _ in 0..<2 {
            DispatchQueue.global().async {
                defer { finished.fulfill() }
                do { try fixture.client.destroy("demo") } catch { XCTFail("destroy failed: \(error)") }
            }
        }
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(fixture.backend.destroyCount, 1)
    }

    func testDaemonEnforcesOfflineExecRequirement() throws {
        let fixture = try PolicyFixture()
        defer { fixture.close() }
        var request = fixture.request("online")
        request.network = .nat
        _ = try fixture.client.run(request)
        XCTAssertThrowsError(try fixture.client.exec(ExecCommand(
            name: "online", argv: ["true"], env: [], cwd: "", timeoutSeconds: 5, requireOffline: true
        ))) { error in XCTAssertTrue(String(describing: error).contains("offline sandbox")) }
    }

    func testOldDaemonRejectedBeforeRunIsSent() throws {
        let home = URL(fileURLWithPath: "/tmp/microvm-old-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let socket = home.appendingPathComponent("daemon.sock").path
        let listen = try POSIX.listenUnix(socket)
        defer { _ = closeFD(listen) }
        let ping = expectation(description: "capability probe")
        DispatchQueue.global().async {
            defer { ping.fulfill() }
            let fd = POSIX.accept(listen)
            defer { _ = closeFD(fd) }
            XCTAssertEqual(try? ControlCodec.read(fd), .ping)
            try? ControlCodec.write(fd, .result(Data("{\"ok\":true}".utf8)))
        }
        XCTAssertThrowsError(try DaemonClient(socketPath: socket).run(RunRequest(
            name: "unsafe", cpus: 1, memoryMB: 256, ttlSeconds: nil, bootTimeoutSeconds: 5
        ))) { error in XCTAssertTrue(String(describing: error).contains("restart the daemon")) }
        wait(for: [ping], timeout: 2)
    }
}

private func eventually(_ predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(4)
    while Date() < deadline {
        if predicate() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return false
}

private final class PolicyFixture {
    let home = URL(fileURLWithPath: "/tmp/microvm-policy-\(UUID().uuidString)")
    let backend: PolicyBackend
    let daemon: Daemon
    let client: DaemonClient

    init(delayedBoot: Bool = false, failFirstDestroy: Bool = false, dropFirstDestroy: Bool = false) throws {
        backend = PolicyBackend(delayedBoot: delayedBoot, failFirstDestroy: failFirstDestroy, dropFirstDestroy: dropFirstDestroy)
        daemon = Daemon(home: home, backend: backend)
        try daemon.start()
        client = DaemonClient(socketPath: daemon.paths.socket.path)
        let paths = daemon.paths
        try FileManager.default.createDirectory(at: paths.imageDir(HostArch.guest), withIntermediateDirectories: true)
        try Data().write(to: paths.kernel(HostArch.guest))
        try Data().write(to: paths.initrd(HostArch.guest))
    }

    func request(_ name: String) -> RunRequest {
        RunRequest(name: name, cpus: 1, memoryMB: 256, ttlSeconds: nil, bootTimeoutSeconds: 5)
    }

    func close() {
        daemon.stop()
        try? FileManager.default.removeItem(at: home)
    }
}

private final class PolicyBackend: VMBackend {
    var onGuestExit: ((String, UUID, String?) -> Void)?
    private let lock = NSLock()
    private var requests: [String: BootRequest] = [:]
    private var pending: [String: (Result<Void, Error>) -> Void] = [:]
    private var delayed: Bool
    private var destroys = 0
    private var execs = 0
    private let failFirstDestroy: Bool
    private let dropFirstDestroy: Bool

    init(delayedBoot: Bool, failFirstDestroy: Bool, dropFirstDestroy: Bool) {
        delayed = delayedBoot
        self.failFirstDestroy = failFirstDestroy
        self.dropFirstDestroy = dropFirstDestroy
    }

    var delayedBoot: Bool {
        get { lock.lock(); defer { lock.unlock() }; return delayed }
        set { lock.lock(); delayed = newValue; lock.unlock() }
    }

    var destroyCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return destroys
    }

    func request(_ name: String) -> BootRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requests[name]
    }

    func boot(_ request: BootRequest, completion: @escaping (Result<Void, Error>) -> Void) {
        lock.lock()
        requests[request.name] = request
        let wait = delayed
        if wait { pending[request.name] = completion }
        lock.unlock()
        if !wait { completion(.success(())) }
    }

    func finishBoot(_ name: String) {
        lock.lock()
        let completion = pending.removeValue(forKey: name)
        lock.unlock()
        completion?(.success(()))
    }

    var execCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return execs
    }

    func exec(_ request: ExecRequest, emit: @escaping (ExecEvent) -> Void) {
        lock.lock()
        execs += 1
        lock.unlock()
    }
    func cancelExec(name: String, id: UInt32) {}

    func destroy(name: String, completion: @escaping (Result<Void, Error>) -> Void) {
        lock.lock()
        destroys += 1
        let first = destroys == 1
        lock.unlock()
        if first && dropFirstDestroy { return }
        if first && failFirstDestroy {
            completion(.failure(MicroVMError("injected stop failure")))
        } else {
            completion(.success(()))
        }
    }
}
