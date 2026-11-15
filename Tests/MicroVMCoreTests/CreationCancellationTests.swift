import Darwin
import Foundation
import XCTest

@testable import MicroVMCore

final class CreationCancellationTests: XCTestCase {
    func testCancellationDuringAdmissionDoesNotAllocate() throws {
        let fixture = try makeFixture()
        fixture.cancellation.cancel()
        XCTAssertThrowsError(try fixture.manager.start(startCommand(fixture.root), cancellation: fixture.cancellation)) { error in
            XCTAssertTrue(String(describing: error).contains("during admission"))
        }
        XCTAssertEqual(fixture.boots, 0)
        XCTAssertEqual(fixture.treeCalls, 0)
        XCTAssertEqual(try taskIDs(fixture.root), ["task-kept"])
        XCTAssertEqual(try String(contentsOf: fixture.keptPatch, encoding: .utf8), "kept")
        try fixture.manager.reserveName("demo")
    }

    func testCancellationDuringImportRemovesOnlyThatSandbox() throws {
        let fixture = try makeFixture()
        fixture.cancelOnTree = true
        XCTAssertThrowsError(try fixture.manager.start(startCommand(fixture.root), cancellation: fixture.cancellation)) { error in
            XCTAssertTrue(String(describing: error).contains("during import and boot"))
        }
        // Boot overlaps the host snapshot, so the sandbox it started is the one destroyed.
        XCTAssertEqual(fixture.boots, 1)
        XCTAssertGreaterThan(fixture.treeCalls, 0)
        XCTAssertEqual(fixture.destroyed.count, 1)
        XCTAssertFalse(fixture.destroyed.contains("task-kept"))
        XCTAssertEqual(try taskIDs(fixture.root), ["task-kept"])
        XCTAssertEqual(try String(contentsOf: fixture.keptPatch, encoding: .utf8), "kept")
        XCTAssertNoThrow(try fixture.manager.admit())
    }

    func testFailedSnapshotDestroysTheSandboxBootedBesideIt() throws {
        let fixture = try makeFixture()
        fixture.failOnPack = true
        XCTAssertThrowsError(try fixture.manager.start(startCommand(fixture.root), cancellation: fixture.cancellation)) { error in
            XCTAssertTrue(String(describing: error).contains("pack refused"))
        }
        XCTAssertEqual(fixture.boots, 1)
        XCTAssertEqual(fixture.destroyed.count, 1)
        XCTAssertFalse(fixture.destroyed.contains("task-kept"))
        XCTAssertEqual(try taskIDs(fixture.root), ["task-kept"])
        XCTAssertNoThrow(try fixture.manager.admit())
    }

    func testCancellationDuringBootAndAfterSuccessCleansUpTheNewSandbox() throws {
        let booting = try makeFixture()
        booting.cancelOnBoot = true
        XCTAssertThrowsError(try booting.manager.start(startCommand(booting.root), cancellation: booting.cancellation)) { error in
            XCTAssertTrue(String(describing: error).contains("during import and boot"))
        }
        XCTAssertEqual(booting.boots, 1)
        XCTAssertEqual(booting.destroyed.count, 1)
        XCTAssertEqual(try taskIDs(booting.root), ["task-kept"])

        let ready = try makeFixture()
        ready.cancelOnExecute = true
        XCTAssertThrowsError(try ready.manager.start(startCommand(ready.root), cancellation: ready.cancellation)) { error in
            XCTAssertTrue(String(describing: error).contains("during successful creation"))
        }
        XCTAssertEqual(ready.destroyed.count, 1)
        XCTAssertEqual(try taskIDs(ready.root), ["task-kept"])
        XCTAssertNil(ready.manager.current)
        XCTAssertNoThrow(try ready.manager.admit())
    }

    func testFailedCleanupKeepsARetryableRecordAndNamesTheCommand() throws {
        let fixture = try makeFixture(failDestroy: true)
        fixture.cancelOnBoot = true
        XCTAssertThrowsError(try fixture.manager.start(startCommand(fixture.root), cancellation: fixture.cancellation)) { error in
            let failure = error as? MicroVMError
            XCTAssertTrue(failure?.message.contains("remains after failed cleanup") == true)
            XCTAssertTrue(failure?.recovery.contains("microvm rm demo --force") == true)
            XCTAssertTrue(failure?.message.contains("task-") == true)
        }
        let ids = try taskIDs(fixture.root)
        XCTAssertTrue(ids.contains("task-kept"))
        let created = try XCTUnwrap(ids.first { $0 != "task-kept" })
        let record = try fixture.manager.load(created)
        XCTAssertEqual(record.phase, "interrupted")
        XCTAssertEqual(record.name, "demo")
        XCTAssertTrue(record.message?.contains("microvm rm demo --force") == true)
        XCTAssertEqual(try String(contentsOf: fixture.keptPatch, encoding: .utf8), "kept")
        XCTAssertThrowsError(try fixture.manager.admit())
    }

    func testClosedClientCancelsCreationAndStopDoesNot() throws {
        var fds = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer {
            _ = close(fds[0])
            _ = close(fds[1])
        }
        let cancellation = CreationCancellation()
        let started = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            started.signal()
            watchCreationClient(fds[0], cancellation)
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        _ = close(fds[1])
        fds[1] = -1
        let deadline = Date().addingTimeInterval(2)
        while !cancellation.isCancelled, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(cancellation.isCancelled)

        var idleFDs = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &idleFDs), 0)
        defer {
            _ = close(idleFDs[0])
            _ = close(idleFDs[1])
        }
        let idle = CreationCancellation()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            watchCreationClient(idleFDs[0], idle)
            done.signal()
        }
        idle.stop()
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(idle.isCancelled)
    }

    private final class Fixture {
        let root: URL
        let keptPatch: URL
        let cancellation = CreationCancellation()
        var manager: TaskManager!
        var boots = 0
        var treeCalls = 0
        var destroyed: [String] = []
        var cancelOnTree = false
        var failOnPack = false
        var cancelOnBoot = false
        var cancelOnExecute = false
        init(root: URL, keptPatch: URL) {
            self.root = root
            self.keptPatch = keptPatch
        }
    }

    private func startCommand(_ root: URL) -> TaskCommand {
        var command = TaskCommand(op: "start")
        command.projectPath = root.appendingPathComponent("project").path
        command.name = "demo"
        return command
    }

    private func taskIDs(_ root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("tasks"), includingPropertiesForKeys: nil)
            .map(\.lastPathComponent).sorted()
    }

    private func makeFixture(failDestroy: Bool = false) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try MicroVMPaths(home: root).ensure()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let digest = try dataDigest(Data("runtime".utf8))
        let runtime = root.appendingPathComponent("runtimes").appendingPathComponent(digest)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try Data("runtime".utf8).write(to: runtime.appendingPathComponent("runtime.ext4"))
        for name in ["kernel", "initrd"] { try Data("image".utf8).write(to: runtime.appendingPathComponent(name)) }
        let manifest = RuntimeArtifact(
            runtimes: RuntimeArtifact.defaultRuntimes, arch: HostArch.guest, baseImageDigest: "base", artifactDigest: digest,
            tools: [:], environment: [:], formatVersion: RuntimeArtifact.currentFormatVersion, verificationCommand: ["true"])
        try JSONEncoder().encode(manifest).write(to: runtime.appendingPathComponent("runtime.json"))
        try JSONEncoder().encode([RuntimeArtifact.selectionKey(manifest.runtimes, arch: HostArch.guest): digest])
            .write(to: root.appendingPathComponent("runtime-catalog.json"))
        let kept = root.appendingPathComponent("tasks/task-kept/result")
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        let patch = kept.appendingPathComponent("changes.patch")
        try Data("kept".utf8).write(to: patch)
        let record = TaskRecord(
            id: "task-kept", name: "kept", phase: "completed", runtimeDigest: digest, createdAtUnix: unixNow(),
            expiresAtUnix: unixNow() + 86400, resultDirectory: kept.path, network: .none)
        try JSONEncoder().encode(record).write(to: root.appendingPathComponent("tasks/task-kept/task.json"))
        let fixture = Fixture(root: root, keptPatch: patch)
        fixture.manager = TaskManager(
            paths: MicroVMPaths(home: root), arch: HostArch.guest,
            boot: { request in
                fixture.boots += 1
                if fixture.cancelOnBoot { fixture.cancellation.cancel() }
                return VMRecord(
                    name: request.name, phase: .running, cpus: 2, memoryMB: 2048, daemonToken: "test",
                    createdAtUnix: unixNow(), ttlSeconds: 120, message: nil, network: .none)
            },
            execute: { _, _, _, _, _, _ in
                if fixture.cancelOnExecute { fixture.cancellation.cancel() }
                return Data()
            },
            destroy: { name in
                fixture.destroyed.append(name)
                if failDestroy { throw MicroVMError("teardown failed") }
            },
            hostTree: { name, args, _, output in
                fixture.treeCalls += 1
                if fixture.cancelOnTree, name == "microvm-workspace", args[0] == "pack" { fixture.cancellation.cancel() }
                if fixture.failOnPack, name == "microvm-workspace", args[0] == "pack" { throw MicroVMError("pack refused") }
                if let output { try Data().write(to: output) }
                if name == "microvm-workspace", args[0] == "unpack" {
                    try FileManager.default.createDirectory(atPath: args[1], withIntermediateDirectories: true)
                }
                if name == "microvm-mkruntime" { try Data().write(to: URL(fileURLWithPath: args[1])) }
                return Data("none".utf8)
            })
        try fixture.manager.recover()
        return fixture
    }
}
