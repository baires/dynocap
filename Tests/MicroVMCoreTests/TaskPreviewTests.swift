import Foundation
import XCTest

@testable import MicroVMCore

final class TaskPreviewTests: XCTestCase {
    private func fixture(fail: Bool = false, oversized: Bool = false, stop: Bool = false) throws -> (TaskManager, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try MicroVMPaths(home: root).ensure()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var tasks: TaskManager!
        tasks = TaskManager(
            paths: MicroVMPaths(home: root), arch: "aarch64", boot: { _ in throw MicroVMError("boot") },
            execute: { _, _, _, _, output, _ in
                XCTAssertThrowsError(try tasks.begin("task-preview", argv: ["mutate"]))
                XCTAssertThrowsError(try tasks.admit())
                if fail { throw MicroVMError("export failed") }
                if let output { try Data("archive".utf8).write(to: output) }
                if stop { tasks.stopped("task-preview", reason: "TTL expired") }
                return Data()
            }, destroy: { _ in XCTFail("diff must not destroy") },
            hostTree: { _, args, _, _ in
                let destination = URL(fileURLWithPath: args.last!)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                if args[0] == "result" {
                    for name in ["changes.patch", "review.txt", "changes.json"] {
                        try Data("review".utf8).write(to: destination.appendingPathComponent(name))
                    }
                    if oversized {
                        let file = destination.appendingPathComponent("large")
                        FileManager.default.createFile(atPath: file.path, contents: nil)
                        let handle = try FileHandle(forWritingTo: file)
                        try handle.truncate(atOffset: 257 << 20)
                        try handle.close()
                    }
                }
                return Data()
            })
        try tasks.recover()
        let record = TaskRecord(
            id: "task-preview", phase: "running", runtimeDigest: "digest", createdAtUnix: unixNow(),
            expiresAtUnix: unixNow() + 86400, network: .none)
        let directory = root.appendingPathComponent("tasks/task-preview")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tasks.current = record
        tasks.busy = true
        try tasks.save(record)
        return (tasks, directory)
    }

    func testPreviewReturnsPathsReplacesPreviousAndReopensAdmission() throws {
        let (tasks, directory) = try fixture()
        let first = try tasks.preview("task-preview", requireOffline: true, permitFiltered: false)
        XCTAssertEqual(try String(contentsOfFile: first.patchPath, encoding: .utf8), "review")
        XCTAssertEqual(tasks.current?.phase, "running")
        XCTAssertNil(tasks.current?.resultDirectory)
        let second = try tasks.preview("task-preview", requireOffline: true, permitFiltered: false)
        XCTAssertEqual(first.directory, second.directory)
        XCTAssertFalse(tasks.reviewing)
        XCTAssertNotNil(try tasks.begin("task-preview", argv: ["true"]))
        for name in ["preview.partial", "preview-export.tar", "preview-tree"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
        }
    }
    func testBusyAndNetworkPolicies() throws {
        let (tasks, _) = try fixture()
        tasks.active = 1
        XCTAssertThrowsError(try tasks.preview("task-preview", requireOffline: false, permitFiltered: true))
        tasks.active = 0
        tasks.current?.network = .nat
        try tasks.save(tasks.current!)
        XCTAssertThrowsError(try tasks.preview("task-preview", requireOffline: true, permitFiltered: false))
        XCTAssertFalse(tasks.reviewing)
    }
    func testFailureQuotaAndTTLDiscardPartialPreview() throws {
        for options in [(true, false, false), (false, true, false), (false, false, true)] {
            let (tasks, directory) = try fixture(fail: options.0, oversized: options.1, stop: options.2)
            XCTAssertThrowsError(try tasks.preview("task-preview", requireOffline: true, permitFiltered: false))
            XCTAssertFalse(tasks.reviewing)
            for name in ["preview", "preview.partial", "preview-export.tar", "preview-tree"] {
                XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
            }
        }
    }
    func testPublishedReviewNeedsNoGuest() throws {
        let (tasks, directory) = try fixture(fail: true)
        tasks.current?.resultDirectory = directory.appendingPathComponent("result").path
        try tasks.save(tasks.current!)
        tasks.current = nil
        let preview = try tasks.preview("task-preview", requireOffline: true, permitFiltered: false)
        XCTAssertTrue(preview.patchPath.hasSuffix("result/changes.patch"))
    }
}
