import XCTest

@testable import MicroVMCore

final class DaemonTests: XCTestCase {
    func testRunExecDestroy() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let backend = FakeBackend()
        let daemon = Daemon(home: home, backend: backend)
        try daemon.start()
        defer { daemon.stop() }
        let client = DaemonClient(socketPath: daemon.paths.socket.path)
        try client.ping()
        XCTAssertEqual(try client.ps().count, 0)

        XCTAssertThrowsError(try client.run(RunRequest(name: "demo", cpus: 1, memoryMB: 256, ttlSeconds: nil, bootTimeoutSeconds: 5)))

        try touchImages(daemon.paths)
        let status = try client.run(RunRequest(name: "demo", cpus: 2, memoryMB: 1024, ttlSeconds: nil, bootTimeoutSeconds: 5))
        XCTAssertEqual(status.phase, "running")
        XCTAssertEqual(backend.booted["demo"]?.cpus, 2)
        XCTAssertEqual(backend.booted["demo"]?.memoryMB, 1024)
        XCTAssertEqual(try client.ps().map(\.name), ["demo"])

        XCTAssertThrowsError(try client.run(RunRequest(name: "demo", cpus: 1, memoryMB: 256, ttlSeconds: nil, bootTimeoutSeconds: 5)))

        let outcome = try client.exec(ExecCommand(name: "demo", argv: ["uname", "-a"], env: [], cwd: "", timeoutSeconds: 5))
        XCTAssertEqual(outcome.code, 0)
        XCTAssertEqual(String(data: outcome.stdout, encoding: .utf8), "uname -a\n")

        try client.destroy("demo")
        XCTAssertEqual(try client.ps().count, 0)
        XCTAssertNil(backend.booted["demo"])
        XCTAssertThrowsError(try client.exec(ExecCommand(name: "demo", argv: ["true"], env: [], cwd: "", timeoutSeconds: 5))) { error in
            XCTAssertEqual((error as? MicroVMError)?.message, "sandbox not found: demo")
        }
    }

    func testNamedExecUsesTaskWorkingDirectoryAndKeepsOverrides() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let backend = FakeBackend()
        let daemon = Daemon(home: home, backend: backend)
        try daemon.start()
        defer { daemon.stop() }
        try touchImages(daemon.paths)
        let client = DaemonClient(socketPath: daemon.paths.socket.path)
        _ = try client.run(RunRequest(name: "underlying", cpus: 1, memoryMB: 256, ttlSeconds: 60, bootTimeoutSeconds: 5))
        let directory = home.appendingPathComponent("tasks/underlying")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = TaskRecord(
            id: "underlying", name: "interview", phase: "running", runtimeDigest: "digest",
            createdAtUnix: unixNow(), expiresAtUnix: unixNow() + 86400, network: .none)
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("task.json"))
        _ = try client.exec(ExecCommand(name: "interview", argv: ["pwd"], env: [], cwd: "", timeoutSeconds: 5))
        XCTAssertEqual(backend.lastExec?.cwd, "/workspace")
        backend.exitCode = 7
        let outcome = try client.exec(ExecCommand(name: "interview", argv: ["false"], env: ["CI=1"], cwd: "/tmp", timeoutSeconds: 12))
        XCTAssertEqual(backend.lastExec?.cwd, "/tmp")
        XCTAssertEqual(backend.lastExec?.env, ["CI=1"])
        XCTAssertEqual(outcome.code, 7)
        var remove = TaskCommand(op: "remove")
        remove.id = "underlying"
        remove.force = true
        _ = try client.task(remove)
    }

    func testReapOnStartAndUnsupportedBoot() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = MicroVMPaths(home: home)
        try paths.ensure()
        try StateStore(paths: paths).save(
            VMRecord(
                name: "leaked", phase: .running, cpus: 1, memoryMB: 256,
                daemonToken: "dead", createdAtUnix: 1, ttlSeconds: nil, message: nil
            ))
        let daemon = Daemon(home: home, backend: UnsupportedBackend())
        try daemon.start()
        defer { daemon.stop() }
        let client = DaemonClient(socketPath: paths.socket.path)
        let records = try client.ps()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].phase, .stopped)
        XCTAssertTrue(records[0].message?.contains("reaped") == true)

        try touchImages(paths)
        XCTAssertThrowsError(
            try client.run(
                RunRequest(
                    name: "demo", cpus: 1, memoryMB: 256, ttlSeconds: nil, bootTimeoutSeconds: 5
                ))
        ) { error in
            XCTAssertTrue(String(describing: error).contains("macOS"))
        }
        let failed = try client.ps().first { $0.name == "demo" }
        XCTAssertEqual(failed?.phase, .failed)
    }

    func testExecTimeout() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let backend = FakeBackend()
        backend.hangExec = true
        let daemon = Daemon(home: home, backend: backend)
        try daemon.start()
        defer { daemon.stop() }
        try touchImages(daemon.paths)
        _ = try DaemonClient(socketPath: daemon.paths.socket.path).run(
            RunRequest(name: "demo", cpus: 1, memoryMB: 256, ttlSeconds: nil, bootTimeoutSeconds: 5)
        )
        XCTAssertThrowsError(
            try DaemonClient(socketPath: daemon.paths.socket.path).exec(
                ExecCommand(name: "demo", argv: ["sleep", "30"], env: [], cwd: "", timeoutSeconds: 1)
            )
        ) { error in
            let micro = error as? MicroVMError
            XCTAssertEqual(micro?.exitCode, 124)
            XCTAssertTrue(micro?.message.contains("timed out") == true)
        }
    }

    func testSecondDaemonRejected() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let first = Daemon(home: home, backend: FakeBackend())
        try first.start()
        defer { first.stop() }
        let second = Daemon(home: home, backend: FakeBackend())
        XCTAssertThrowsError(try second.start())
    }
}

private final class FakeBackend: VMBackend {
    var onGuestExit: ((String, UUID, String?) -> Void)?
    var booted: [String: BootRequest] = [:]
    var lastExec: ExecRequest?
    var exitCode: Int32 = 0
    var hangExec = false

    func boot(_ request: BootRequest, completion: @escaping (Result<Void, Error>) -> Void) {
        booted[request.name] = request
        completion(.success(()))
    }

    func exec(_ request: ExecRequest, emit: @escaping (ExecEvent) -> Void) {
        lastExec = request
        if hangExec { return }
        emit(.stdout(Data((request.argv.joined(separator: " ") + "\n").utf8)))
        emit(.finished(code: exitCode, signal: 0))
    }

    func cancelExec(name: String, id: UInt32) {}

    func destroy(name: String, completion: @escaping (Result<Void, Error>) -> Void) {
        booted.removeValue(forKey: name)
        completion(.success(()))
    }
}

private func tempHome() -> URL {
    URL(fileURLWithPath: "/tmp/microvm-test-\(UUID().uuidString)")
}

private func touchImages(_ paths: MicroVMPaths) throws {
    let dir = paths.imageDir(HostArch.guest)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    _ = FileManager.default.createFile(atPath: paths.kernel(HostArch.guest).path, contents: Data("kernel".utf8))
    _ = FileManager.default.createFile(atPath: paths.initrd(HostArch.guest).path, contents: Data("initrd".utf8))
}
