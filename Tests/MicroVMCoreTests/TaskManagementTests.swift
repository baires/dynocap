import Foundation
import XCTest

@testable import MicroVMCore

final class TaskManagementTests: XCTestCase {
    private func setup() throws -> (URL, TaskManager) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try MicroVMPaths(home: root).ensure()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let manager = TaskManager(
            paths: MicroVMPaths(home: root), arch: "aarch64", boot: { _ in throw MicroVMError("boot") },
            execute: { _, _, _, _, _, _ in throw MicroVMError("exec") }, destroy: { _ in })
        try manager.recover()
        return (root, manager)
    }

    private func seed(_ root: URL, name: String? = "interview") throws -> TaskRecord {
        let directory = root.appendingPathComponent("tasks/task-old")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = directory.appendingPathComponent("result")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        try Data("patch".utf8).write(to: result.appendingPathComponent("changes.patch"))
        let record = TaskRecord(
            id: "task-old", name: name, phase: "completed", runtimeDigest: "digest", createdAtUnix: unixNow(),
            expiresAtUnix: unixNow() + 86400, resultDirectory: result.path, network: .none)
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("task.json"))
        return record
    }

    func testNameRetentionRemovalAndLegacyRecords() throws {
        let (root, tasks) = try setup()
        let original = try seed(root)
        XCTAssertEqual(try tasks.resolve("interview").id, original.id)
        XCTAssertThrowsError(try tasks.reserveName("interview"))
        try tasks.recover()
        XCTAssertEqual(try tasks.resolve("interview").id, original.id)
        try tasks.remove(original.id, purge: false)
        XCTAssertThrowsError(try tasks.resolve("interview"))
        XCTAssertNil(try tasks.resolve(original.id).name)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: original.resultDirectory!).appendingPathComponent("changes.patch")),
            Data("patch".utf8))
        try tasks.reserveName("interview")
        tasks.releaseNameReservation("interview")
        try tasks.remove(original.id, purge: true)
        XCTAssertThrowsError(try tasks.resolve(original.id))
        let legacy = try seed(root, name: nil)
        XCTAssertNil(try tasks.resolve(legacy.id).name)
    }

    func testReservationsAndRawNamespaceAreShared() throws {
        let (root, tasks) = try setup()
        try tasks.reserveName("coding")
        XCTAssertThrowsError(try tasks.reserveName("coding"))
        tasks.namespace.lock()
        XCTAssertThrowsError(try tasks.checkRawName("coding"))
        tasks.namespace.unlock()
        tasks.releaseNameReservation("coding")
        try StateStore(paths: MicroVMPaths(home: root)).save(
            VMRecord(
                name: "raw", phase: .stopped, cpus: 1, memoryMB: 256,
                daemonToken: "old", createdAtUnix: unixNow(), ttlSeconds: 60, message: nil))
        XCTAssertThrowsError(try tasks.reserveName("raw"))
        for name in ["task-user", "runtime-verify", "../bad", "", "bad name"] {
            XCTAssertThrowsError(try tasks.reserveName(name))
        }
        try tasks.reserveName("Coding")
        try tasks.reserveName("coding")
    }

    func testConcurrentReservationHasOneWinner() throws {
        let (_, tasks) = try setup()
        let lock = NSLock()
        var winners = 0
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            do {
                try tasks.reserveName("same")
                lock.lock()
                winners += 1
                lock.unlock()
            } catch {}
        }
        XCTAssertEqual(winners, 1)
    }

    func testFailedTeardownPreservesNameAndResult() throws {
        let (root, _) = try setup()
        _ = try seed(root)
        let tasks = TaskManager(
            paths: MicroVMPaths(home: root), arch: "aarch64", boot: { _ in throw MicroVMError("boot") },
            execute: { _, _, _, _, _, _ in throw MicroVMError("exec") }, destroy: { _ in throw MicroVMError("teardown") })
        XCTAssertThrowsError(try tasks.remove("task-old", purge: true))
        XCTAssertEqual(try tasks.resolve("interview").id, "task-old")
    }

    func testCombinedListDeduplicatesAndRawRemovalWorks() throws {
        let (root, _) = try setup()
        let daemon = Daemon(home: root, backend: UnsupportedBackend())
        try daemon.start()
        defer { daemon.stop() }
        _ = try seed(root)
        let store = StateStore(paths: MicroVMPaths(home: root))
        for name in ["task-old", "raw"] {
            try store.save(
                VMRecord(
                    name: name, phase: .stopped, cpus: 1, memoryMB: 256,
                    daemonToken: "old", createdAtUnix: unixNow(), ttlSeconds: 60, message: nil))
        }
        let client = DaemonClient(socketPath: daemon.paths.socket.path)
        let entries = try JSONDecoder().decode([ManagedEntry].self, from: client.task(TaskCommand(op: "entries")))
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.filter { $0.kind == "task" }.map(\.name), ["interview"])
        var remove = TaskCommand(op: "remove")
        remove.id = "raw"
        _ = try client.task(remove)
        XCTAssertNil(try store.load("raw"))
    }
}
