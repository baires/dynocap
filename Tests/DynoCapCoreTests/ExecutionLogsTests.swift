import XCTest
@testable import DynoCapCore

final class ExecutionLogsTests: XCTestCase {
    func testParserDiscoverySelectionAndInvalidFormats() throws {
        let value = try parseCommand(["dynocap", "logs", "demo", "--exec=2", "--home=/tmp/logs"])
        XCTAssertEqual(value.command, .logs(LogsCommand(target: "demo", execution: 2, list: false)))
        XCTAssertEqual(try parseCommand(["dynocap", "logs", "--list", "demo"]).command,
                       .logs(LogsCommand(target: "demo", list: true)))
        for args in [["logs"], ["logs", "demo", "--list", "--exec", "0"], ["logs", "demo", "--exec", "-1"],
                     ["logs", "demo", "--exec", "bad"], ["logs", "demo", "--json"], ["logs", "demo", "--list", "--json"]] {
            XCTAssertThrowsError(try parseCommand(["dynocap"] + args)) { error in XCTAssertEqual((error as? DynoCapError)?.exitCode, 2) }
        }
    }

    func testByteAccountingQuotaAndMissingOrTruncatedDetection() throws {
        let fixture = try LogFixture()
        defer { fixture.stop() }
        var record = fixture.record
        record.phase = "running"
        record.resultDirectory = nil
        record.commands = []
        let manager = TaskManager(paths: fixture.paths, arch: HostArch.guest, boot: { _ in throw DynoCapError("boot") },
                                  execute: { _, _, _, _, _, _ in Data() }, destroy: { _ in })
        manager.current = record
        manager.busy = true
        let index = try XCTUnwrap(manager.begin(record.id, argv: ["test"]))
        try manager.append(record.id, index: index, data: Data([0, 255, 65]), stderr: false)
        try manager.append(record.id, index: index, data: Data([66, 13]), stderr: true)
        manager.end(record.id, index: index, code: 7, error: nil)
        let logs = try manager.executionLogs("demo")
        XCTAssertEqual(logs.executions[0].stdout.expectedBytes, 3)
        XCTAssertEqual(logs.executions[0].stderr.expectedBytes, 2)
        XCTAssertEqual(logs.executions[0].stdout.integrity, "complete")
        XCTAssertEqual(logs.executions[0].state, "failed")
        manager.stopped(record.id, reason: "sandbox destroyed")
        let afterShutdown = try fixture.run(["logs", "demo"])
        XCTAssertEqual(afterShutdown.status, 0)
        XCTAssertEqual(afterShutdown.stdout, Data([0, 255, 65]))
        XCTAssertEqual(afterShutdown.stderr, Data([66, 13]))
        manager.current = try manager.load(record.id)
        try Data([0]).write(to: fixture.taskDirectory.appendingPathComponent("0.stdout"))
        XCTAssertEqual(try manager.executionLogs("demo").executions[0].stdout.integrity, "truncated")
        try FileManager.default.removeItem(at: fixture.taskDirectory.appendingPathComponent("0.stderr"))
        XCTAssertEqual(try manager.executionLogs("demo").executions[0].stderr.integrity, "missing")
        manager.current?.logBytes = 32 << 20
        XCTAssertThrowsError(try manager.append(record.id, index: index, data: Data([1]), stderr: false))
        XCTAssertEqual(manager.current?.commands[0].logsTruncated, true)
        let stored = try manager.load(record.id)
        XCTAssertEqual(stored.commands[0].logsTruncated, true)
    }

    func testProcessReplayPreservesLargeMixedBinaryStreamsAndFailedStatus() throws {
        let fixture = try LogFixture()
        defer { fixture.stop() }
        let listed = try fixture.run(["logs", "demo", "--list"])
        XCTAssertEqual(listed.status, 0, String(data: listed.stderr, encoding: .utf8) ?? "")
        XCTAssertEqual(listed.stderr, Data())
        let text = String(data: listed.stdout, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("INTEGRITY"))
        XCTAssertTrue(text.contains("failed"))
        XCTAssertTrue(text.contains("complete"))
        let latest = try fixture.run(["logs", "demo", "--verbose"])
        XCTAssertEqual(latest.status, 0)
        XCTAssertEqual(latest.stdout, fixture.largeOut)
        XCTAssertEqual(latest.stderr, fixture.largeErr)
        let first = try fixture.run(["logs", fixture.record.id, "--exec", "0"])
        XCTAssertEqual(first.status, 0)
        XCTAssertEqual(first.stdout, Data("first\n".utf8))
        XCTAssertEqual(first.stderr, Data())
        // The stopped sandbox is no longer required for retained logs.
        XCTAssertNil(try StateStore(paths: fixture.paths).load(fixture.record.id))
    }

    func testMissingTruncatedLegacyActiveAndExpiredLogs() throws {
        let fixture = try LogFixture()
        defer { fixture.stop() }
        try FileManager.default.removeItem(at: fixture.result.appendingPathComponent("1.stderr"))
        let missing = try fixture.run(["logs", "demo"])
        XCTAssertEqual(missing.status, 1)
        XCTAssertEqual(missing.stdout, Data())
        XCTAssertTrue(String(data: missing.stderr, encoding: .utf8)?.contains("missing logs") == true)
        try Data([1]).write(to: fixture.result.appendingPathComponent("1.stderr"))
        let truncated = try fixture.run(["logs", "demo"])
        XCTAssertEqual(truncated.status, 1)
        XCTAssertEqual(truncated.stdout, Data())
        XCTAssertTrue(String(data: truncated.stderr, encoding: .utf8)?.contains("truncated logs") == true)
        fixture.record.commands[1].stdoutBytes = nil
        fixture.record.commands[1].stderrBytes = nil
        try fixture.save()
        let legacyList = try fixture.run(["logs", "demo", "--list"])
        XCTAssertTrue(String(data: legacyList.stdout, encoding: .utf8)?.contains("unknown") == true)
        let legacy = try fixture.run(["logs", "demo"])
        XCTAssertEqual(legacy.status, 0)
        XCTAssertEqual(legacy.stderr, Data([1]))
        fixture.record.phase = "running"
        fixture.record.commands[1].endedAtUnix = nil
        try fixture.save()
        let active = try fixture.run(["logs", "demo"])
        XCTAssertEqual(active.status, 1)
        XCTAssertEqual(active.stdout, Data())
        XCTAssertTrue(String(data: active.stderr, encoding: .utf8)?.contains("still running") == true)
        fixture.record.phase = "interrupted"
        fixture.record.commands[1].stdoutBytes = 0 // Only begin metadata survived a daemon crash.
        fixture.record.commands[1].stderrBytes = 0
        try fixture.save()
        let interrupted = try fixture.run(["logs", "demo"])
        XCTAssertEqual(interrupted.status, 0)
        XCTAssertEqual(interrupted.stdout, fixture.largeOut)
        XCTAssertEqual(interrupted.stderr, Data([1]))
        fixture.record.expiresAtUnix = unixNow() - 1
        try fixture.save()
        let expired = try fixture.run(["logs", fixture.record.id])
        XCTAssertEqual(expired.status, 1)
        XCTAssertEqual(expired.stdout, Data())
        XCTAssertTrue(String(data: expired.stderr, encoding: .utf8)?.contains("expired") == true)
    }

    func testEmptyJournalUnknownExecutionAndUnsupportedTranscript() throws {
        let fixture = try LogFixture()
        defer { fixture.stop() }
        let unknown = try fixture.run(["logs", "demo", "--exec", "999"])
        XCTAssertEqual(unknown.status, 1)
        XCTAssertEqual(unknown.stdout, Data())
        fixture.record.commands[1].outputFormat = "pty-v2"
        try fixture.save()
        let future = try fixture.run(["logs", "demo"])
        XCTAssertEqual(future.status, 1)
        XCTAssertEqual(future.stdout, Data())
        XCTAssertTrue(String(data: future.stderr, encoding: .utf8)?.contains("pty-v2") == true)
        fixture.record.commands = []
        try fixture.save()
        let empty = try fixture.run(["logs", "demo", "--list"])
        XCTAssertEqual(empty.status, 0)
        XCTAssertTrue(String(data: empty.stdout, encoding: .utf8)?.contains("No recorded executions") == true)
        let replay = try fixture.run(["logs", "demo"])
        XCTAssertEqual(replay.status, 1)
        XCTAssertEqual(replay.stdout, Data())
    }
}

private struct LogProcessResult {
    var status: Int32
    var stdout: Data
    var stderr: Data
}

private final class LogFixture {
    let root = URL(fileURLWithPath: "/tmp/dynocap-logs-\(UUID().uuidString)")
    var paths: DynoCapPaths { DynoCapPaths(home: root.appendingPathComponent("home")) }
    var taskDirectory: URL { paths.home.appendingPathComponent("tasks/task-logs") }
    var result: URL { taskDirectory.appendingPathComponent("result") }
    var record: TaskRecord
    let daemon: Daemon
    let largeOut = Data(repeating: 0xff, count: 1_000_003) + Data([0, 27, 13, 10])
    let largeErr = Data(repeating: 0xfe, count: 700_001) + Data([0, 13, 10])

    init() throws {
        let now = unixNow()
        record = TaskRecord(id: "task-logs", name: "demo", phase: "failed", runtimeDigest: "digest", createdAtUnix: now,
                            expiresAtUnix: now + 86400, network: .none)
        daemon = Daemon(home: root.appendingPathComponent("home"), backend: UnsupportedBackend())
        try daemon.start()
        record.resultDirectory = result.path
        record.commands = [
            TaskCommandRecord(argv: ["echo", "first"], startedAtUnix: now - 20, endedAtUnix: now - 19, exitCode: 0,
                              stdout: "0.stdout", stderr: "0.stderr", stdoutBytes: 6, stderrBytes: 0, logsTruncated: false),
            TaskCommandRecord(argv: ["test"], startedAtUnix: now - 10, endedAtUnix: now - 9, exitCode: 7,
                              stdout: "1.stdout", stderr: "1.stderr", stdoutBytes: Int64(largeOut.count), stderrBytes: Int64(largeErr.count),
                              logsTruncated: false, outputFormat: "separate"),
        ]
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        try Data("first\n".utf8).write(to: result.appendingPathComponent("0.stdout"))
        try Data().write(to: result.appendingPathComponent("0.stderr"))
        try largeOut.write(to: result.appendingPathComponent("1.stdout"))
        try largeErr.write(to: result.appendingPathComponent("1.stderr"))
        try save()
    }

    func save() throws { try JSONEncoder().encode(record).write(to: taskDirectory.appendingPathComponent("task.json"), options: .atomic) }
    func stop() { daemon.stop(); try? FileManager.default.removeItem(at: root) }

    func run(_ args: [String]) throws -> LogProcessResult {
        let prefix = UUID().uuidString
        let outURL = root.appendingPathComponent(prefix + ".out")
        let errURL = root.appendingPathComponent(prefix + ".err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outURL)
        let errors = try FileHandle(forWritingTo: errURL)
        defer { try? output.close(); try? errors.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DYNOCAP_BIN"] ?? ".build/debug/dynocap")
        process.arguments = ["--home", paths.home.path] + args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + 5) == .success else {
            process.terminate()
            throw DynoCapError("logs process did not finish")
        }
        return LogProcessResult(status: process.terminationStatus, stdout: try Data(contentsOf: outURL), stderr: try Data(contentsOf: errURL))
    }
}
