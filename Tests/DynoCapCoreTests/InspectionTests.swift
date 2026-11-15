import XCTest
@testable import DynoCapCore

final class InspectionTests: XCTestCase {
    func testInspectionFactsRetentionArtifactsAndReadOnlyBehavior() throws {
        let root = URL(fileURLWithPath: "/tmp/dynocap-inspect-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = DynoCapPaths(home: root)
        try paths.ensure()
        let manager = TaskManager(
            paths: paths, arch: HostArch.guest, boot: { _ in XCTFail("inspect must not boot"); throw DynoCapError("boot") },
            execute: { _, _, _, _, _, _ in XCTFail("inspect must not execute"); return Data() },
            destroy: { _ in XCTFail("inspect must not destroy") })
        try manager.recover()
        let now: Int64 = 5000
        var running = TaskRecord(
            id: "task-running", name: "live", runtimes: RuntimeArtifact.defaultRuntimes, phase: "running", runtimeDigest: "digest",
            createdAtUnix: 1000, expiresAtUnix: 605800, sourcePath: "/tmp/source", network: .none)
        let stopped = VMRecord(
            name: "task-done", phase: .stopped, cpus: 2, memoryMB: 2048, daemonToken: "must-not-leak", createdAtUnix: 1100,
            ttlSeconds: 600, message: nil)
        var live = stopped
        live.name = running.id
        live.phase = .running
        live.createdAtUnix = now - 20
        live.ttlSeconds = 3600
        var done = running
        done.id = "task-done"
        done.name = "done"
        done.phase = "completed"
        done.sourcePath = nil
        done.sourceUrl = "https://example.com/repo.git"
        done.sourceRevision = String(repeating: "a", count: 40)
        done.resultDirectory = root.appendingPathComponent("tasks/task-done/result").path
        var lost = running
        lost.id = "task-lost"
        lost.name = nil
        lost.phase = "interrupted"
        lost.sourcePath = nil // Old records did not retain local source paths.
        lost.message = "daemon restarted; unexported edits were discarded"
        var expired = done
        expired.id = "task-expired"
        expired.name = "expired"
        expired.expiresAtUnix = now
        var failed = done
        failed.id = "task-failed"
        failed.name = "failed"
        failed.phase = "failed"
        for record in [running, done, lost, expired, failed] { try seed(record, root: root) }
        let result = try XCTUnwrap(done.resultDirectory)
        try FileManager.default.createDirectory(atPath: result, withIntermediateDirectories: true)
        try Data("patch".utf8).write(to: URL(fileURLWithPath: result).appendingPathComponent("changes.patch"))
        let before = try snapshot(root)
        let fact = try manager.inspect("live", sandboxes: [live, stopped], now: now)
        XCTAssertEqual(fact.id, running.id)
        XCTAssertEqual(fact.source?.value, "/tmp/source")
        XCTAssertEqual(fact.sandboxExpiresAtUnix, now + 3580)
        XCTAssertEqual(fact.resultExpiresAtUnix, 1000 + 7 * 86400)
        XCTAssertEqual(fact.network, NetworkMode.none)
        let retained = try manager.inspect("task-done", sandboxes: [live, stopped], now: now)
        XCTAssertEqual(retained.phase, "completed")
        XCTAssertEqual(retained.source?.revision, done.sourceRevision)
        XCTAssertEqual(retained.sandboxExpiresAtUnix, 1700)
        XCTAssertEqual(retained.resultExpiresAtUnix, done.expiresAtUnix)
        XCTAssertEqual(retained.result?.available, true)
        XCTAssertNotNil(retained.result?.patchPath)
        XCTAssertNil(retained.result?.reviewPath)
        XCTAssertEqual(retained.unexportedWork, "exported")
        let failedResult = try manager.inspect("failed", sandboxes: [], now: now)
        XCTAssertEqual(failedResult.phase, "failed")
        XCTAssertEqual(failedResult.result?.available, true)
        let interrupted = try manager.inspect(lost.id, sandboxes: [], now: now)
        XCTAssertNil(interrupted.source)
        XCTAssertNil(interrupted.sandboxExpiresAtUnix)
        XCTAssertEqual(interrupted.unexportedWork, "discarded")
        let human = try formatInspection(interrupted, output: .human, now: now)
        XCTAssertTrue(human.contains("Unexported workspace edits were discarded"))
        XCTAssertTrue(human.contains("from task creation"))
        var leftover = stopped
        leftover.name = expired.id
        for target in ["missing", "expired", expired.id] {
            XCTAssertThrowsError(try manager.inspect(target, sandboxes: [leftover], now: now)) { error in
                XCTAssertEqual((error as? DynoCapError)?.code, .notFound)
            }
        }
        XCTAssertEqual(try snapshot(root), before)
        running.phase = "interrupted"
        try seed(running, root: root)
        XCTAssertEqual(try manager.inspect("live", sandboxes: [live], now: now).unexportedWork, "unavailable_cleanup_pending")
    }

    func testJSONNullsRawSandboxAndMissingResultDirectory() throws {
        let raw = SandboxInspection(
            id: "raw", name: "raw", kind: "sandbox", phase: "stopped", runtime: "minimal", createdAtUnix: 1000,
            sandboxPhase: "stopped", sandboxExpiresAtUnix: 1100)
        let output = try formatInspection(raw, output: .json, now: 1200)
        let json = try object(output)
        XCTAssertEqual(Set(json.keys), Set([
            "id", "name", "kind", "phase", "source", "runtime", "runtimes", "runtimeDigest", "network", "createdAtUnix",
            "sandboxPhase", "sandboxExpiresAtUnix", "resultExpiresAtUnix", "result", "unexportedWork", "message",
        ]))
        for key in ["source", "runtimes", "runtimeDigest", "network", "resultExpiresAtUnix", "result", "unexportedWork", "message"] {
            XCTAssertTrue(json[key] is NSNull, key)
        }
        XCTAssertNil(json["expiresAtUnix"])
        let human = try formatInspection(raw, output: .human, now: 1200)
        XCTAssertTrue(human.contains("original deadline"))
        XCTAssertTrue(human.contains("Retention expires: not applicable"))
        XCTAssertTrue(human.contains("Network: unknown"))
        XCTAssertFalse(output.contains("daemonToken"))
    }

    func testInspectionMessagesDoNotExposeStoredCredentials() throws {
        let value = SandboxInspection(
            id: "raw", name: "raw", kind: "sandbox", phase: "failed", runtime: "minimal", createdAtUnix: 1000,
            message: "https://user:secret@example.com failed Authorization: Bearer private-token")
        for output in [CLIOutput.json, .human] {
            let text = try formatInspection(value, output: output, now: 1200)
            XCTAssertFalse(text.contains("user:secret"))
            XCTAssertFalse(text.contains("private-token"))
            XCTAssertTrue(text.contains("<redacted>"))
        }
    }

    func testCLIInspectionStreamsAndFailures() throws {
        let root = URL(fileURLWithPath: "/tmp/dynocap-inspect-cli-\(UUID().uuidString)")
        let daemon = Daemon(home: root, backend: UnsupportedBackend())
        try daemon.start()
        defer { daemon.stop(); try? FileManager.default.removeItem(at: root) }
        let now = unixNow()
        let record = TaskRecord(
            id: "task-retained", name: "done", phase: "completed", runtimeDigest: "digest", createdAtUnix: now - 100,
            expiresAtUnix: now - 100 + 604800, resultDirectory: root.appendingPathComponent("missing-result").path,
            sourcePath: "/tmp/project", network: .none)
        try seed(record, root: root)
        let store = StateStore(paths: daemon.paths)
        let raw = VMRecord(
            name: "raw", phase: .stopped, cpus: 1, memoryMB: 256, daemonToken: "private", createdAtUnix: 1000,
            ttlSeconds: 60, message: nil)
        try store.save(raw)
        let rawOutput = try runCLI(root, ["inspect", "raw", "--json"])
        XCTAssertEqual(rawOutput.status, 0, rawOutput.stderr)
        let rawJSON = try object(rawOutput.stdout)
        XCTAssertEqual(rawJSON["kind"] as? String, "sandbox")
        XCTAssertEqual(rawJSON["sandboxExpiresAtUnix"] as? Int64, 1060)
        XCTAssertTrue(rawJSON["resultExpiresAtUnix"] is NSNull)
        XCTAssertEqual(try store.load("raw"), raw)
        let original = try snapshot(root.appendingPathComponent("tasks"))
        let human = try runCLI(root, ["inspect", "done"])
        XCTAssertEqual(human.status, 0, human.stderr)
        XCTAssertEqual(human.stderr, "")
        XCTAssertTrue(human.stdout.contains("Phase: completed"))
        XCTAssertTrue(human.stdout.contains("directory unavailable"))
        let result = try runCLI(root, ["--json", "inspect", record.id])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stderr, "")
        let json = try object(result.stdout)
        let source = try XCTUnwrap(json["source"] as? [String: Any])
        XCTAssertEqual(source["value"] as? String, "/tmp/project")
        XCTAssertTrue(source["revision"] is NSNull)
        let artifact = try XCTUnwrap(json["result"] as? [String: Any])
        XCTAssertEqual(artifact["available"] as? Bool, false)
        XCTAssertTrue(artifact["patchPath"] is NSNull)
        XCTAssertTrue(json["sandboxExpiresAtUnix"] is NSNull)
        XCTAssertEqual(json["resultExpiresAtUnix"] as? Int64, record.expiresAtUnix)
        XCTAssertEqual(try snapshot(root.appendingPathComponent("tasks")), original)
        for args in [["inspect"], ["inspect", "done", "extra"], ["inspect", "done", "--purge"]] {
            let invalid = try runCLI(root, args)
            XCTAssertEqual(invalid.status, 2)
            XCTAssertEqual(invalid.stdout, "")
        }
        let missing = try runCLI(root, ["inspect", "absent", "--json"])
        XCTAssertEqual(missing.status, 1)
        XCTAssertEqual(missing.stdout, "")
        let error = try XCTUnwrap(try object(missing.stderr)["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "not_found")
    }

    private func seed(_ record: TaskRecord, root: URL) throws {
        let directory = root.appendingPathComponent("tasks").appendingPathComponent(record.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("task.json"))
    }

    private func snapshot(_ root: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        while let file = enumerator.nextObject() as? URL {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { files[file.path] = try Data(contentsOf: file) }
        }
        return files
    }

    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func runCLI(_ root: URL, _ args: [String]) throws -> InspectionProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DYNOCAP_BIN"] ?? ".build/debug/dynocap")
        process.arguments = ["--home", root.path] + args
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let finished = expectation(description: "inspect finishes")
        process.terminationHandler = { _ in finished.fulfill() }
        try process.run()
        wait(for: [finished], timeout: 5)
        if process.isRunning { process.terminate(); XCTFail("inspect hung") }
        return InspectionProcessResult(
            status: process.terminationStatus, stdout: String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }
}

private struct InspectionProcessResult {
    var status: Int32
    var stdout: String
    var stderr: String
}
