import Foundation
import XCTest

@testable import MicroVMCore

final class CLIFinishTests: XCTestCase {
    func testHumanFinishReportsShutdownArtifactsRetentionAndQuotedApplyCommand() throws {
        let now: Int64 = 1_700_000_000
        let directory = "/tmp/my result/changes's/result"
        var record = sampleRecord(name: "demo", phase: "completed", expiresAtUnix: now + 2 * 86400 + 30)
        record.resultDirectory = directory
        let text = try formatFinishResult(TaskDescriptor(record), output: .human, now: now)
        let patch = directory + "/changes.patch"
        let quoted = "'" + patch.replacingOccurrences(of: "'", with: "'\\''") + "'"
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertFalse(text.contains("\u{001B}"))
        XCTAssertTrue(text.contains("Stopped sandbox: demo"))
        XCTAssertTrue(text.contains("ID: \(record.id)"))
        XCTAssertTrue(text.contains("Phase: completed"))
        XCTAssertTrue(text.contains("Patch: \(patch)"))
        XCTAssertTrue(text.contains("Result directory: \(directory)"))
        XCTAssertTrue(text.contains("Result retention: 2d left ("))
        XCTAssertTrue(text.contains("uncommitted"))
        XCTAssertTrue(text.contains("does not modify the host checkout"))
        XCTAssertTrue(text.contains("git apply --check \(quoted) && git apply \(quoted)"))
        XCTAssertFalse(text.contains("Guest commands failed"))
    }

    func testJSONFinishDistinguishesPriorGuestFailureFromSuccessfulExport() throws {
        let now: Int64 = 1_700_000_000
        var failed = sampleRecord(name: "demo", phase: "failed", expiresAtUnix: now + 90)
        failed.resultDirectory = "/results/task"
        let object = try jsonObject(formatFinishResult(TaskDescriptor(failed), output: .json, now: now))
        XCTAssertEqual(object["phase"] as? String, "failed")
        XCTAssertEqual(object["sandbox"] as? String, "stopped")
        XCTAssertEqual(object["priorCommandFailure"] as? Bool, true)
        XCTAssertEqual(object["resultDirectory"] as? String, "/results/task")
        XCTAssertEqual(object["patch"] as? String, "/results/task/changes.patch")
        XCTAssertEqual(object["resultExpiresAtUnix"] as? Int, Int(now + 90))
        XCTAssertEqual(object["baseline"] as? String, "imported_checkout_including_uncommitted_changes")
        XCTAssertEqual(object["hostCheckout"] as? String, "unchanged")
        XCTAssertTrue((object["applyCommand"] as? String)?.contains("git apply --check ") == true)
        let human = try formatFinishResult(TaskDescriptor(failed), output: .human, now: now)
        XCTAssertTrue(human.contains("Guest commands failed before export"))
        XCTAssertTrue(human.contains("not an export or teardown failure"))
    }

    func testFinishWarnsAboutChangesThatRunCode() throws {
        let now: Int64 = 1_700_000_000
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("finish-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("""
        [{"path":".husky/pre-commit","kind":"added","mode":493,"sensitive":"Git hooks run on commit"},
         {"path":"notes.txt","kind":"modified","mode":420}]
        """.utf8).write(to: directory.appendingPathComponent("changes.json"))
        var record = sampleRecord(name: "demo", phase: "completed", expiresAtUnix: now + 90)
        record.resultDirectory = directory.path
        let human = try formatFinishResult(TaskDescriptor(record), output: .human, now: now)
        XCTAssertTrue(human.contains("Review carefully before applying."))
        XCTAssertTrue(human.contains("  added .husky/pre-commit: Git hooks run on commit"))
        XCTAssertFalse(human.contains("notes.txt"))
        let object = try jsonObject(formatFinishResult(TaskDescriptor(record), output: .json, now: now))
        let flagged = try XCTUnwrap(object["sensitivePaths"] as? [[String: Any]])
        XCTAssertEqual(flagged.map { $0["path"] as? String }, [".husky/pre-commit"])
        XCTAssertEqual(sensitiveChanges(resultDirectory: "/nonexistent"), [])
    }

    func testFinishKeepsArtifactsAppliesPatchAndLeavesSourceUntouched() throws {
        let fixture = try runningTask()
        let source = fixture.root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("alpha\n".utf8).write(to: source.appendingPathComponent("hello.txt"))
        fixture.tasks.current?.sourcePath = source.path
        try fixture.tasks.save(fixture.tasks.current!)
        let record = try fixture.tasks.finish("task-finish", requireOffline: true, permitFiltered: false)
        XCTAssertEqual(record.phase, "completed")
        XCTAssertEqual(fixture.destroys, 1)
        XCTAssertEqual(fixture.executions, 1)
        let result = URL(fileURLWithPath: try XCTUnwrap(record.resultDirectory))
        XCTAssertEqual(try String(contentsOf: result.appendingPathComponent("changes.patch"), encoding: .utf8), patchText)
        XCTAssertEqual(try String(contentsOf: result.appendingPathComponent("review.txt"), encoding: .utf8), "review")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.appendingPathComponent("runtime.json").path))
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("hello.txt"), encoding: .utf8), "alpha\n")
        try assertPatchApplies(toMatchingCopyOf: fixture.directory.appendingPathComponent("baseline"), patch: result.appendingPathComponent("changes.patch"))
        let again = try fixture.tasks.finish("task-finish", requireOffline: true, permitFiltered: false)
        XCTAssertEqual(again.resultDirectory, record.resultDirectory)
        XCTAssertEqual(fixture.executions, 1)
        XCTAssertEqual(fixture.destroys, 2)
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("hello.txt"), encoding: .utf8), "alpha\n")
    }

    func testPriorGuestFailureStillExportsAndExportFailureStaysRetryable() throws {
        let failedGuest = try runningTask()
        failedGuest.tasks.current?.commands = [
            TaskCommandRecord(
                argv: ["false"], startedAtUnix: unixNow(), endedAtUnix: unixNow(), exitCode: 1, stdout: "0.stdout", stderr: "0.stderr")
        ]
        try failedGuest.tasks.save(failedGuest.tasks.current!)
        let exported = try failedGuest.tasks.finish("task-finish", requireOffline: false, permitFiltered: nil)
        XCTAssertEqual(exported.phase, "failed")
        XCTAssertNotNil(exported.resultDirectory)

        let broken = try runningTask(exportError: "pack failed")
        XCTAssertThrowsError(try broken.tasks.finish("task-finish", requireOffline: true, permitFiltered: false)) { error in
            let failure = error as? MicroVMError
            XCTAssertTrue(failure?.message.contains("export failed") == true)
            XCTAssertTrue(failure?.message.contains("pack failed") == true)
            XCTAssertFalse(failure?.message.contains("teardown") == true)
            XCTAssertTrue(failure?.recovery.contains("microvm finish interview") == true)
        }
        XCTAssertEqual(broken.tasks.current?.phase, "running")
        XCTAssertNil(broken.tasks.current?.resultDirectory)
        XCTAssertEqual(broken.destroys, 0)
        let recovered = try broken.tasks.finish("task-finish", requireOffline: true, permitFiltered: false)
        XCTAssertEqual(recovered.phase, "completed")
        XCTAssertNotNil(recovered.resultDirectory)
    }

    func testTeardownFailureKeepsTheExportedResultAndNamesTheFailure() throws {
        let fixture = try runningTask(teardownError: "backend destroy failed")
        XCTAssertThrowsError(try fixture.tasks.finish("task-finish", requireOffline: true, permitFiltered: false)) { error in
            let failure = error as? MicroVMError
            XCTAssertTrue(failure?.message.contains("teardown failed after export") == true)
            XCTAssertTrue(failure?.message.contains("backend destroy failed") == true)
            XCTAssertFalse(failure?.message.contains("export failed") == true)
            XCTAssertTrue(failure?.recovery.contains("microvm finish interview") == true)
        }
        let saved = try fixture.tasks.load("task-finish")
        XCTAssertEqual(saved.phase, "completed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: try XCTUnwrap(saved.resultDirectory)).appendingPathComponent("changes.patch").path))
        let retried = try fixture.tasks.finish("task-finish", requireOffline: true, permitFiltered: false)
        XCTAssertEqual(retried.resultDirectory, saved.resultDirectory)
        XCTAssertEqual(fixture.executions, 1)
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        let data = Data(text.utf8)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(object)
    }

    private func sampleRecord(name: String, phase: String, expiresAtUnix: Int64) -> TaskRecord {
        TaskRecord(
            id: "task-finish", name: name, phase: phase, runtimeDigest: "digest", createdAtUnix: expiresAtUnix - 7 * 86400,
            expiresAtUnix: expiresAtUnix, network: .none)
    }

    private func assertPatchApplies(toMatchingCopyOf baseline: URL, patch: URL) throws {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: baseline.appendingPathComponent("hello.txt"), to: copy.appendingPathComponent("hello.txt"))
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        check.currentDirectoryURL = copy
        check.arguments = ["apply", "--check", patch.path]
        try check.run()
        check.waitUntilExit()
        XCTAssertEqual(check.terminationStatus, 0)
        let apply = Process()
        apply.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        apply.currentDirectoryURL = copy
        apply.arguments = ["apply", patch.path]
        try apply.run()
        apply.waitUntilExit()
        XCTAssertEqual(apply.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: copy.appendingPathComponent("hello.txt"), encoding: .utf8), "beta\n")
    }

    private func runningTask(exportError: String? = nil, teardownError: String? = nil) throws -> FinishFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try MicroVMPaths(home: root).ensure()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("runtimes/digest")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: runtime.appendingPathComponent("runtime.json"))
        let fixture = FinishFixture(root: root)
        var tasks: TaskManager!
        tasks = TaskManager(
            paths: MicroVMPaths(home: root), arch: "aarch64", boot: { _ in throw MicroVMError("boot") },
            execute: { _, _, _, _, output, _ in
                fixture.executions += 1
                if let exportError = fixture.exportError {
                    fixture.exportError = nil
                    throw MicroVMError(exportError)
                }
                if let output { try Data("archive".utf8).write(to: output) }
                return Data()
            },
            destroy: { _ in
                fixture.destroys += 1
                if let teardownError = fixture.teardownError {
                    fixture.teardownError = nil
                    throw MicroVMError(teardownError)
                }
            },
            hostTree: { _, args, _, _ in
                let destination = URL(fileURLWithPath: args.last!)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                if args[0] == "result" {
                    try Data(patchText.utf8).write(to: destination.appendingPathComponent("changes.patch"))
                    try Data("review".utf8).write(to: destination.appendingPathComponent("review.txt"))
                    try Data("{}\n".utf8).write(to: destination.appendingPathComponent("changes.json"))
                } else if args[0] == "unpack" {
                    try Data("alpha\n".utf8).write(to: destination.appendingPathComponent("hello.txt"))
                }
                return Data()
            })
        fixture.tasks = tasks
        fixture.exportError = exportError
        fixture.teardownError = teardownError
        try tasks.recover()
        let directory = root.appendingPathComponent("tasks/task-finish")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("baseline"), withIntermediateDirectories: true)
        try Data("alpha\n".utf8).write(to: directory.appendingPathComponent("baseline/hello.txt"))
        let record = TaskRecord(
            id: "task-finish", name: "interview", phase: "running", runtimeDigest: "digest", createdAtUnix: unixNow(),
            expiresAtUnix: unixNow() + 86400, network: .none)
        tasks.current = record
        tasks.busy = true
        try tasks.save(record)
        fixture.directory = directory
        return fixture
    }
}

private final class FinishFixture {
    let root: URL
    var directory: URL!
    var tasks: TaskManager!
    var executions = 0
    var destroys = 0
    var exportError: String?
    var teardownError: String?
    init(root: URL) { self.root = root }
}

private let patchText = """
diff --git a/hello.txt b/hello.txt
--- a/hello.txt
+++ b/hello.txt
@@ -1 +1 @@
-alpha
+beta

"""
