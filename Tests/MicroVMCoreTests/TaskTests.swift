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
            tools: ["node": "22.23.4"], environment: [:], formatVersion: RuntimeArtifact.currentFormatVersion, verificationCommand: ["true"]
        )
        try JSONEncoder().encode(manifest).write(to: runtime.appendingPathComponent("runtime.json"))
        try JSONEncoder().encode(["aarch64/node@24": String(repeating: "a", count: 64)]).write(
            to: root.appendingPathComponent("runtime-catalog.json"))
        let tasks = manager(root)
        try tasks.recover()
        var request = TaskCommand(op: "start")
        request.projectPath = root.path
        request.runtimes = [RuntimeSelection(name: "cobol", version: "85")]
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
        let seeds = root.appendingPathComponent(DependencyCache.directoryName)
        let legacySeeds = root.appendingPathComponent("npm-cache")
        try FileManager.default.createDirectory(at: legacySeeds, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: seeds, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: seeds.appendingPathComponent("unfinished.partial"))
        try manager(root).recover()
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: seeds.appendingPathComponent("unfinished.partial").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacySeeds.path))
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
            environment: [:], formatVersion: RuntimeArtifact.currentFormatVersion, verificationCommand: [], dependencyCache: npmSpec)
        let first = try DependencyCache.key(baseline: root, runtime: runtime)
        runtime.artifactDigest = "second"
        XCTAssertNotEqual(first, try DependencyCache.key(baseline: root, runtime: runtime))
        runtime.artifactDigest = "first"
        try Data("lock two".utf8).write(to: root.appendingPathComponent("package-lock.json"))
        XCTAssertNotEqual(first, try DependencyCache.key(baseline: root, runtime: runtime))
    }
    private let npmSpec = DependencyCacheSpec(
        lockfiles: ["package-lock.json"], configFiles: [".npmrc"], directory: "/work/npm-cache/_cacache",
        registry: "https://registry.npmjs.org/", verifyCommand: ["npm", "cache", "verify"], incompatibleEnvPrefixes: ["npm_config_"],
        incompatibleArgSubstrings: ["registry"])
    func testDependencyCacheKeyFollowsTheDeclaredSpec() throws {
        let root = try home()
        var runtime = RuntimeArtifact(
            runtimes: RuntimeArtifact.defaultRuntimes, arch: "aarch64", baseImageDigest: "base", artifactDigest: "disk", tools: [:],
            environment: [:], formatVersion: RuntimeArtifact.currentFormatVersion, verificationCommand: [])
        try Data("lock".utf8).write(to: root.appendingPathComponent("package-lock.json"))
        XCTAssertNil(try DependencyCache.key(baseline: root, runtime: runtime), "a runtime without a cache spec gets no seed")
        runtime.dependencyCache = npmSpec
        let npm = try XCTUnwrap(try DependencyCache.key(baseline: root, runtime: runtime))
        try Data("registry=https://example.com/".utf8).write(to: root.appendingPathComponent(".npmrc"))
        XCTAssertNotEqual(npm, try DependencyCache.key(baseline: root, runtime: runtime), "config files are part of the key")
        runtime.dependencyCache = DependencyCacheSpec(lockfiles: ["uv.lock"], directory: "/work/uv-cache", registry: "https://pypi.org/simple")
        XCTAssertNil(try DependencyCache.key(baseline: root, runtime: runtime), "a missing lockfile gets no seed")
        try Data("lock".utf8).write(to: root.appendingPathComponent("uv.lock"))
        XCTAssertNotNil(try DependencyCache.key(baseline: root, runtime: runtime))
    }
    func testIncompatibleCommandsFollowTheDeclaredSpec() {
        XCTAssertTrue(DependencyCache.compatibleCommand(argv: ["npm", "ci"], env: ["CI=1"], spec: npmSpec))
        XCTAssertFalse(DependencyCache.compatibleCommand(argv: ["npm", "ci"], env: ["NPM_CONFIG_CACHE=/tmp"], spec: npmSpec))
        XCTAssertFalse(DependencyCache.compatibleCommand(argv: ["npm", "ci", "--registry=https://x"], env: [], spec: npmSpec))
        let go = DependencyCacheSpec(
            lockfiles: ["go.sum"], directory: "/work/go/pkg/mod/cache/download", registry: "https://proxy.golang.org",
            incompatibleEnvPrefixes: ["GOPROXY"])
        XCTAssertTrue(DependencyCache.compatibleCommand(argv: ["go", "test", "--registry"], env: [], spec: go))
        XCTAssertFalse(DependencyCache.compatibleCommand(argv: ["go", "build"], env: ["GOPROXY=off"], spec: go))
    }
    func testTaskAndTransferControlFrames() throws {
        var task = TaskCommand(op: "start")
        task.projectPath = "/tmp/project"
        task.runtimes = RuntimeArtifact.defaultRuntimes
        task.reportProgress = true
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
    /// The daemon picks the runtime for every client (CLI, MCP, SDK): project files first, then bash.
    func testOmittedRuntimeFollowsTheProjectThenFallsBackToShell() throws {
        let root = try home()
        let tasks = manager(root)
        try tasks.recover()
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var request = TaskCommand(op: "start")
        request.projectPath = project.path
        func refusal() -> String {
            do { _ = try tasks.start(request) } catch { return (error as? MicroVMError)?.message ?? "\(error)" }
            return "started"
        }
        XCTAssertEqual(refusal(), "runtime shell:1 is not prepared yet")
        try Data().write(to: project.appendingPathComponent("pyproject.toml"))
        XCTAssertEqual(refusal(), "runtime python:3.14 is not prepared yet")
        request.projectPath = nil
        request.repositoryUrl = "https://example.invalid/repo.git"
        request.network = .nat
        XCTAssertEqual(refusal(), "runtime shell:1 is not prepared yet", "a URL cannot be inspected before boot")
    }

    func testCatalogKeepsSelectionsSeparate() throws {
        let root = try home()
        let first = String(repeating: "a", count: 64)
        let second = String(repeating: "b", count: 64)
        try JSONEncoder().encode(["aarch64/node@22": first, "aarch64/shell@1": second]).write(
            to: root.appendingPathComponent("runtime-catalog.json"))
        XCTAssertEqual(try RuntimeArtifact.directory(nil, home: root, arch: "aarch64").lastPathComponent, second, "shell:1 is the default")
        XCTAssertEqual(
            try RuntimeArtifact.directory([RuntimeSelection(name: "node", version: "22")], home: root, arch: "aarch64").lastPathComponent,
            first)
        XCTAssertThrowsError(
            try RuntimeArtifact.directory([RuntimeSelection(name: "python", version: "3.13")], home: root, arch: "aarch64"))
    }

    func testOlderIsolationCapabilityRemainsReadable() throws {
        let data = Data("{\"ok\":true,\"isolationPolicyVersion\":1}".utf8)
        let capability = try JSONDecoder().decode(PolicyCapabilities.self, from: data)
        XCTAssertTrue(capability.ok)
        XCTAssertEqual(capability.isolationPolicyVersion, 1)
        XCTAssertNil(capability.taskVersion)
        XCTAssertNil(capability.inspectionVersion)
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

    func testLegacyRuntimeRequiresPreparation() throws {
        let root = try home()
        let legacy = RuntimeArtifact(
            runtimes: RuntimeArtifact.defaultRuntimes, arch: "aarch64", baseImageDigest: "base", artifactDigest: "disk", tools: [:],
            environment: [:], formatVersion: 2, verificationCommand: [])
        try JSONEncoder().encode(legacy).write(to: root.appendingPathComponent("runtime.json"))
        XCTAssertThrowsError(try RuntimeArtifact.resolve(nil, directory: root, arch: "aarch64")) { error in
            XCTAssertTrue((error as? MicroVMError)?.message.contains("outdated") == true)
            XCTAssertTrue((error as? MicroVMError)?.recovery.contains("runtime prepare") == true)
        }
    }

}
