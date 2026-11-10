import Foundation
import XCTest

@testable import MicroVMCore

final class TaskTests: XCTestCase {
    private func home() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("microvm-task-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func manager(_ home: URL) -> TaskManager {
        TaskManager(
            paths: MicroVMPaths(home: home), arch: "aarch64", boot: { _ in throw MicroVMError("unexpected boot") },
            execute: { _, _, _, _, _, _ in throw MicroVMError("unexpected execution") }, destroy: { _ in })
    }
    func testUnsupportedSelectionDoesNotAllocate() throws {
        let root = try home()
        let runtime = root.appendingPathComponent("runtimes/" + String(repeating: "a", count: 64))
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let manifest = RuntimeArtifact(
            runtimes: RuntimeArtifact.defaultRuntimes, arch: "aarch64", baseImageDigest: "base", artifactDigest: "artifact",
            tools: ["node": "22.23.4"], environment: [:], formatVersion: 1, verificationCommand: ["true"])
        try JSONEncoder().encode(manifest).write(to: runtime.appendingPathComponent("runtime.json"))
        try JSONEncoder().encode(["aarch64/node@22": String(repeating: "a", count: 64)]).write(
            to: root.appendingPathComponent("runtime-catalog.json"))
        let tasks = manager(root)
        try tasks.recover()
        var request = TaskCommand(op: "start")
        request.projectPath = root.path
        request.runtimes = [RuntimeSelection(name: "node", version: "24")]
        XCTAssertThrowsError(try tasks.start(request))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("tasks").path), [])
    }
    func testRestartRemovesUnexportedDiskAndKeepsLogsAndPublishedResults() throws {
        let root = try home()
        let directory = root.appendingPathComponent("tasks/task-test")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = TaskRecord(
            id: "task-test", phase: "running", runtimeDigest: "digest", createdAtUnix: unixNow(), expiresAtUnix: unixNow() + 86400,
            network: .none)
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("task.json"))
        for name in ["workspace.ext4", "0.stdout"] { try Data("data".utf8).write(to: directory.appendingPathComponent(name)) }
        let candidate = root.appendingPathComponent("runtime-candidate")
        let seeds = root.appendingPathComponent("npm-cache")
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: seeds, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: seeds.appendingPathComponent("unfinished.partial"))
        try manager(root).recover()
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: seeds.appendingPathComponent("unfinished.partial").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("workspace.ext4").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("0.stdout").path))
        let recovered = try JSONDecoder().decode(TaskRecord.self, from: Data(contentsOf: directory.appendingPathComponent("task.json")))
        XCTAssertEqual(recovered.phase, "interrupted")
    }
    func testSingleTaskAdmission() throws {
        let tasks = manager(try home())
        try tasks.recover()
        try tasks.admit()
        XCTAssertThrowsError(try tasks.admit())
        tasks.release()
        XCTAssertNoThrow(try tasks.admit())
        tasks.release()
    }
    func testDependencyCacheSeparatesLockfilesAndRuntimeDigests() throws {
        let root = try home()
        try Data("lock one".utf8).write(to: root.appendingPathComponent("package-lock.json"))
        var runtime = RuntimeArtifact(
            runtimes: RuntimeArtifact.defaultRuntimes, arch: "aarch64", baseImageDigest: "base", artifactDigest: "first", tools: [:],
            environment: [:], formatVersion: 1, verificationCommand: [])
        let first = try DependencyCache.key(baseline: root, runtime: runtime)
        runtime.artifactDigest = "second"
        XCTAssertNotEqual(first, try DependencyCache.key(baseline: root, runtime: runtime))
        runtime.artifactDigest = "first"
        try Data("lock two".utf8).write(to: root.appendingPathComponent("package-lock.json"))
        XCTAssertNotEqual(first, try DependencyCache.key(baseline: root, runtime: runtime))
    }
    func testTaskAndTransferControlFrames() throws {
        var task = TaskCommand(op: "start")
        task.projectPath = "/tmp/project"
        task.runtimes = RuntimeArtifact.defaultRuntimes
        for message in [
            ControlMessage.task(task),
            .transfer(
                TransferCommand(name: "demo", direction: "upload", localPath: "/tmp/project", guestPath: "/workspace", requireOffline: true)
            ),
        ] {
            XCTAssertEqual(try ControlCodec.decode(ControlCodec.encode(message)), message)
        }
    }
    func testRetentionCapacityAndExpiry() throws {
        let root = try home()
        let tasks = manager(root)
        try tasks.recover()
        let directory = root.appendingPathComponent("tasks/task-capacity")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var record = TaskRecord(
            id: "task-capacity", phase: "completed", runtimeDigest: "digest", createdAtUnix: unixNow(), expiresAtUnix: unixNow() + 86400,
            network: .none)
        let file = directory.appendingPathComponent("retained")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 900 << 20)
        try handle.close()
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("task.json"))
        XCTAssertThrowsError(try tasks.admit())
        record.expiresAtUnix = unixNow() - 1
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("task.json"))
        tasks.sweepExpired()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertNoThrow(try tasks.admit())
        tasks.release()
    }
    func testCatalogKeepsSelectionsSeparate() throws {
        let root = try home()
        let first = String(repeating: "a", count: 64)
        let second = String(repeating: "b", count: 64)
        try JSONEncoder().encode(["aarch64/node@22": first, "aarch64/node@24": second]).write(
            to: root.appendingPathComponent("runtime-catalog.json"))
        XCTAssertEqual(try RuntimeArtifact.directory(nil, home: root, arch: "aarch64").lastPathComponent, first)
        XCTAssertEqual(
            try RuntimeArtifact.directory([RuntimeSelection(name: "node", version: "24")], home: root, arch: "aarch64").lastPathComponent,
            second)
        XCTAssertThrowsError(
            try RuntimeArtifact.directory([RuntimeSelection(name: "python", version: "3.13")], home: root, arch: "aarch64"))
    }

    func testOlderIsolationCapabilityRemainsReadable() throws {
        let data = Data("{\"ok\":true,\"isolationPolicyVersion\":1}".utf8)
        let capability = try JSONDecoder().decode(PolicyCapabilities.self, from: data)
        XCTAssertTrue(capability.ok)
        XCTAssertEqual(capability.isolationPolicyVersion, 1)
        XCTAssertNil(capability.taskVersion)
    }

    func testPublishCreatesMissingCommandLogs() throws {
        let root = try home()
        let source = root.appendingPathComponent("0.stdout")
        try Data("hello".utf8).write(to: source)
        let stage = root.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try publishCommandLog(from: source, to: stage.appendingPathComponent("0.stdout"))
        try publishCommandLog(from: root.appendingPathComponent("0.stderr"), to: stage.appendingPathComponent("0.stderr"))
        XCTAssertEqual(try String(contentsOf: stage.appendingPathComponent("0.stdout"), encoding: .utf8), "hello")
        XCTAssertEqual(try Data(contentsOf: stage.appendingPathComponent("0.stderr")).count, 0)
    }

    func testDigests() throws {
        let root = try home()
        let file = root.appendingPathComponent("input")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try fileDigest(file), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(try dataDigest(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

}
