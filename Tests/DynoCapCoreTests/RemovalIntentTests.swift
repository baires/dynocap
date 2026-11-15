import XCTest

@testable import DynoCapCore

final class RemovalIntentTests: XCTestCase {
    func testForceAndPurgeParseIndependently() throws {
        for args in [["--force"], ["--purge", "--force"], ["--force", "--purge"]] {
            guard case .managed(let command) = try parseCommand(["dynocap", "rm", "demo"] + args).command else {
                return XCTFail("unexpected command")
            }
            XCTAssertEqual(command.op, "remove")
            XCTAssertEqual(command.force ?? false, args.contains("--force"))
            XCTAssertEqual(command.purge ?? false, args.contains("--purge"))
        }
        guard case .managed(let plain) = try parseCommand(["dynocap", "rm", "demo"]).command else { return XCTFail("unexpected command") }
        XCTAssertEqual(plain.force ?? false, false)
        XCTAssertEqual(plain.purge ?? false, false)
        XCTAssertThrowsError(try parseCommand(["dynocap", "rm", "demo", "--force=yes"]))
    }

    func testLiveRemovalRequiresForceAndLeavesTheRecordUnchanged() throws {
        for phase in ["starting", "running", "finalizing"] {
            let fixture = try liveTask(phase: phase)
            XCTAssertThrowsError(try fixture.tasks.remove(fixture.record.id, purge: true, force: false)) { error in
                let failure = error as? DynoCapError
                XCTAssertEqual(failure?.code, .invalidPhase)
                XCTAssertTrue(failure?.message.contains("interview") == true)
                XCTAssertTrue(failure?.recovery.contains("dynocap finish interview") == true)
                XCTAssertTrue(failure?.recovery.contains("dynocap rm interview --force") == true)
                XCTAssertFalse(failure?.recovery.contains("y/n") == true)
            }
            XCTAssertEqual(fixture.destroys, 0)
            let saved = try fixture.tasks.load(fixture.record.id)
            XCTAssertEqual(saved.phase, phase)
            XCTAssertEqual(saved.name, "interview")
            XCTAssertEqual(try Data(contentsOf: fixture.patch), Data("patch".utf8))
        }
    }

    func testFinishedRemovalPurgeAndForceStayIndependent() throws {
        let finished = try liveTask(phase: "completed")
        try finished.tasks.remove(finished.record.id, purge: false, force: false)
        XCTAssertNil(try finished.tasks.load(finished.record.id).name)
        XCTAssertEqual(try Data(contentsOf: finished.patch), Data("patch".utf8))

        let forced = try liveTask(phase: "failed")
        try forced.tasks.remove(forced.record.id, purge: false, force: true)
        XCTAssertNil(try forced.tasks.load(forced.record.id).name)
        XCTAssertEqual(try Data(contentsOf: forced.patch), Data("patch".utf8))

        let interrupted = try liveTask(phase: "interrupted")
        try interrupted.tasks.remove(interrupted.record.id, purge: false, force: false)
        XCTAssertNil(try interrupted.tasks.resolve(interrupted.record.id).name)

        let purged = try liveTask(phase: "completed")
        try purged.tasks.remove(purged.record.id, purge: true, force: false)
        XCTAssertThrowsError(try purged.tasks.load(purged.record.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: purged.patch.path))
    }

    func testForcedLiveRemovalDiscardsAndTeardownFailureStaysRetryable() throws {
        let fixture = try liveTask(phase: "running")
        try fixture.tasks.remove(fixture.record.id, purge: false, force: true)
        XCTAssertEqual(fixture.destroys, 1)
        XCTAssertNil(try fixture.tasks.load(fixture.record.id).name)
        XCTAssertEqual(try fixture.tasks.load(fixture.record.id).phase, "interrupted")

        let stuck = try liveTask(phase: "running", failTeardown: true)
        XCTAssertThrowsError(try stuck.tasks.remove(stuck.record.id, purge: true, force: true))
        XCTAssertEqual(try stuck.tasks.load(stuck.record.id).name, "interview")
        XCTAssertEqual(try stuck.tasks.load(stuck.record.id).phase, "running")
        XCTAssertEqual(try Data(contentsOf: stuck.patch), Data("patch".utf8))
    }

    func testRemovalReadsThePhaseHeldByTheMutationLock() throws {
        let fixture = try liveTask(phase: "running")
        fixture.tasks.condition.lock()
        let finished = expectation(description: "removal observes the completed phase")
        DispatchQueue.global().async {
            do {
                try fixture.tasks.remove(fixture.record.id, purge: false, force: false)
                finished.fulfill()
            } catch {
                XCTFail("removal failed after the phase became completed: \(error)")
            }
        }
        Thread.sleep(forTimeInterval: 0.05)
        fixture.tasks.current?.phase = "completed"
        try fixture.tasks.save(fixture.tasks.current!)
        fixture.tasks.condition.unlock()
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(fixture.destroys, 1)
        XCTAssertNil(try fixture.tasks.load(fixture.record.id).name)
    }

    func testDaemonRejectsUnforcedLiveRemovalAndDestroy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try DynoCapPaths(home: root).ensure()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let daemon = Daemon(home: root, backend: UnsupportedBackend())
        try daemon.start()
        defer { daemon.stop() }
        let record = try seed(root, phase: "running")
        try StateStore(paths: DynoCapPaths(home: root)).save(
            VMRecord(
                name: "raw", phase: .running, cpus: 1, memoryMB: 256, daemonToken: "live",
                createdAtUnix: unixNow(), ttlSeconds: 60, message: nil))
        let client = DaemonClient(socketPath: daemon.paths.socket.path)
        var remove = TaskCommand(op: "remove")
        remove.id = "interview"
        XCTAssertThrowsError(try client.task(remove)) { error in
            let failure = error as? DynoCapError
            XCTAssertTrue(failure?.message.contains("interview") == true)
            XCTAssertTrue(failure?.recovery.contains("--force") == true)
        }
        XCTAssertEqual(try loadPhase(root, id: record.id), "running")
        remove.force = true
        _ = try client.task(remove)
        XCTAssertNil(try loadRecord(root, id: record.id).name)

        var raw = TaskCommand(op: "remove")
        raw.id = "raw"
        raw.purge = true
        XCTAssertThrowsError(try client.task(raw))
        XCTAssertEqual(try StateStore(paths: DynoCapPaths(home: root)).load("raw")?.phase, .running)
        raw.force = true
        _ = try client.task(raw)
        XCTAssertNil(try StateStore(paths: DynoCapPaths(home: root)).load("raw"))

        let kept = try seed(root, phase: "running", id: "task-kept", name: "kept")
        XCTAssertThrowsError(try client.destroy("task-kept"))
        XCTAssertEqual(try loadPhase(root, id: kept.id), "running")
        XCTAssertEqual(try loadRecord(root, id: kept.id).name, "kept")
    }

    private final class Fixture {
        var tasks: TaskManager!
        var record: TaskRecord
        var patch: URL
        var destroys = 0
        init(record: TaskRecord, patch: URL) {
            self.record = record
            self.patch = patch
        }
    }

    private func liveTask(phase: String, failTeardown: Bool = false) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try DynoCapPaths(home: root).ensure()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let record = try seed(root, phase: phase)
        let patch = URL(fileURLWithPath: record.resultDirectory!).appendingPathComponent("changes.patch")
        let fixture = Fixture(record: record, patch: patch)
        let tasks = TaskManager(
            paths: DynoCapPaths(home: root), arch: "aarch64", boot: { _ in throw DynoCapError("boot") },
            execute: { _, _, _, _, _, _ in throw DynoCapError("exec") },
            destroy: { _ in
                fixture.destroys += 1
                if failTeardown { throw DynoCapError("teardown failed") }
            })
        try tasks.recover()
        var stored = record
        if ["starting", "running", "finalizing"].contains(phase) {
            stored.resultDirectory = nil
            tasks.current = stored
            tasks.busy = true
        }
        try tasks.save(stored)
        fixture.record = stored
        fixture.tasks = tasks
        return fixture
    }

    private func seed(_ root: URL, phase: String, id: String = "task-old", name: String = "interview") throws -> TaskRecord {
        let directory = root.appendingPathComponent("tasks/\(id)")
        let result = directory.appendingPathComponent("result")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        try Data("patch".utf8).write(to: result.appendingPathComponent("changes.patch"))
        let record = TaskRecord(
            id: id, name: name, phase: phase, runtimeDigest: "digest", createdAtUnix: unixNow(),
            expiresAtUnix: unixNow() + 86400, resultDirectory: result.path, network: .none)
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("task.json"))
        return record
    }

    private func loadRecord(_ root: URL, id: String) throws -> TaskRecord {
        let url = root.appendingPathComponent("tasks/\(id)/task.json")
        return try JSONDecoder().decode(TaskRecord.self, from: Data(contentsOf: url))
    }

    private func loadPhase(_ root: URL, id: String) throws -> String {
        try loadRecord(root, id: id).phase
    }
}
