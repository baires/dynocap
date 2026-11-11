import XCTest
@testable import MicroVMCore

final class CLIListingTests: XCTestCase {
    private let now: Int64 = 1_794_352_000

    private func entry(_ id: String = "task-demo", name: String? = "demo") -> ManagedEntry {
        ManagedEntry(
            id: id, name: name, kind: "task", phase: "running", runtime: "node:22", network: .none,
            resultDirectory: nil, sandboxExpiresAtUnix: now + 90, resultExpiresAtUnix: now + 604800)
    }

    func testHumanColumnsDurationsAndEmptyOutput() {
        XCTAssertEqual(formatSandboxList([], now: now), "No sandboxes or retained results.\n")
        let text = formatSandboxList([entry()], now: now)
        XCTAssertTrue(text.hasPrefix("NAME/ID  PHASE"), text)
        XCTAssertTrue(text.contains("TTL"))
        XCTAssertTrue(text.contains("RETENTION"))
        XCTAssertTrue(text.contains("1m left"))
        XCTAssertTrue(text.contains("7d left"))
        XCTAssertFalse(text.contains("\t"))
        XCTAssertFalse(text.contains("\u{1b}"))
        for (seconds, expected) in [(0, "expired"), (59, "59s left"), (60, "1m left"),
                                    (3600, "1h left"), (86400, "1d left"), (-1, "expired")] {
            var value = entry()
            value.sandboxExpiresAtUnix = now + Int64(seconds)
            XCTAssertTrue(formatSandboxList([value], now: now).contains(expected))
        }
    }

    func testNarrowLayoutKeepsValuesAndSanitizesControls() {
        var value = entry(name: nil)
        value.phase = "interrupted"
        value.sandboxExpiresAtUnix = nil
        value.resultDirectory = "/a/very/long/result/directory\n\u{1b}[31m"
        let text = formatSandboxList([value], now: now, width: 20)
        XCTAssertTrue(text.hasPrefix("NAME/ID: task-demo\nPHASE: interrupted"), text)
        XCTAssertTrue(text.contains("TTL: -"))
        XCTAssertTrue(text.contains("RETENTION: 7d left"))
        XCTAssertTrue(text.split(separator: "\n").allSatisfy { $0.count <= 20 })
        XCTAssertFalse(text.contains("\u{1b}"))
        XCTAssertTrue(text.replacingOccurrences(of: "\n", with: "").contains("/a/very/long/result/directory"))
        XCTAssertTrue(formatSandboxList([value], now: now, width: 1).split(separator: "\n").allSatisfy { $0.count == 1 })
    }

    func testJSONContractHasExplicitNullsAndIndependentDeadlines() throws {
        var legacy = entry("task-old", name: nil)
        legacy.network = nil
        legacy.sandboxExpiresAtUnix = nil
        legacy.resultExpiresAtUnix = nil
        legacy.expiresAtUnix = 123 // Must not leak the daemon's ambiguous legacy field.
        let text = try formatSandboxListJSON([legacy, entry()])
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["id"] as? String }, ["task-demo", "task-old"])
        XCTAssertEqual(Set(rows[0].keys), Set([
            "id", "name", "kind", "phase", "runtime", "network", "sandboxExpiresAtUnix", "resultExpiresAtUnix", "resultDirectory",
        ]))
        XCTAssertEqual(rows[0]["sandboxExpiresAtUnix"] as? Int64, now + 90)
        XCTAssertEqual(rows[0]["resultExpiresAtUnix"] as? Int64, now + 604800)
        for key in ["name", "network", "sandboxExpiresAtUnix", "resultExpiresAtUnix", "resultDirectory"] {
            XCTAssertTrue(rows[1][key] is NSNull, key)
        }
        XCTAssertEqual(try formatSandboxListJSON([]), "[]\n")
    }

    func testCLIStreamsForEmptyAndPopulatedLists() throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("microvm-list-\(UUID().uuidString)")
        let daemon = Daemon(home: root, backend: UnsupportedBackend())
        try daemon.start()
        defer {
            daemon.stop()
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertEqual(try runCLI(root).stdout, "No sandboxes or retained results.\n")
        XCTAssertEqual(try runCLI(root, json: true).stdout, "[]\n")

        let created = unixNow()
        let store = StateStore(paths: daemon.paths)
        try store.save(VMRecord(
            name: "raw", phase: .running, cpus: 1, memoryMB: 256, daemonToken: "test",
            createdAtUnix: created, ttlSeconds: 3600, message: nil, network: .none))
        for (id, phase) in [("task-done", "completed"), ("task-lost", "interrupted")] {
            let directory = root.appendingPathComponent("tasks/\(id)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let record = TaskRecord(
                id: id, phase: phase, runtimeDigest: "digest", createdAtUnix: created,
                expiresAtUnix: created + 604800,
                resultDirectory: phase == "completed" ? directory.appendingPathComponent("result").path : nil, network: .none)
            try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("task.json"))
        }
        let human = try runCLI(root).stdout
        XCTAssertTrue(human.contains("RETENTION"))
        XCTAssertTrue(human.contains("raw"))
        XCTAssertTrue(human.contains("completed"))
        XCTAssertTrue(human.contains("interrupted"))
        let json = try runCLI(root, json: true).stdout
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0]["sandboxExpiresAtUnix"] as? Int64, created + 3600)
        XCTAssertTrue(rows[0]["resultExpiresAtUnix"] is NSNull)
        XCTAssertTrue(rows[1]["sandboxExpiresAtUnix"] is NSNull)
        XCTAssertEqual(rows[1]["resultExpiresAtUnix"] as? Int64, created + 604800)
        XCTAssertEqual(rows[1]["resultDirectory"] as? String, root.appendingPathComponent("tasks/task-done/result").path)
        XCTAssertTrue(rows[2]["resultDirectory"] is NSNull)
    }

    private func runCLI(_ home: URL, json: Bool = false) throws -> (stdout: String, stderr: String) {
        let binary = ProcessInfo.processInfo.environment["MICROVM_BIN"] ?? ".build/debug/microvm"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--home", home.path, "ls"] + (json ? ["--json"] : [])
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        environment["COLUMNS"] = "20" // Redirected stdout keeps the deterministic non-terminal layout.
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let finished = expectation(description: "ls finishes")
        process.terminationHandler = { _ in finished.fulfill() }
        try process.run()
        wait(for: [finished], timeout: 5)
        if process.isRunning {
            process.terminate()
            XCTFail("ls hung")
        }
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, stderr)
        XCTAssertEqual(stderr, "")
        XCTAssertFalse(stdout.contains("\u{1b}"))
        return (stdout, stderr)
    }
}
