import XCTest
@testable import MicroVMCore

final class CLITests: XCTestCase {
    func testDocumentedCommands() throws {
        let run = try parseCommand(["microvm", "run", "--name", "demo", "--cpus", "2", "--memory", "1024"])
        XCTAssertEqual(run.command, .run(RunRequest(name: "demo", cpus: 2, memoryMB: 1024, ttlSeconds: nil, bootTimeoutSeconds: 60)))

        let uname = try parseCommand(["microvm", "exec", "demo", "--", "uname", "-a"])
        XCTAssertEqual(uname.command, .exec(ExecCommand(name: "demo", argv: ["uname", "-a"], env: [], cwd: "", timeoutSeconds: 60)))

        let shell = try parseCommand(["microvm", "exec", "demo", "--", "sh", "-c", "echo hello"])
        XCTAssertEqual(shell.command, .exec(ExecCommand(name: "demo", argv: ["sh", "-c", "echo hello"], env: [], cwd: "", timeoutSeconds: 60)))

        XCTAssertEqual(try parseCommand(["microvm", "ps"]).command, .ps)
        XCTAssertEqual(try parseCommand(["microvm", "destroy", "demo"]).command, .destroy("demo"))
    }

    func testExecWithoutSeparator() throws {
        let command = try parseCommand(["microvm", "exec", "demo", "uname", "-a"])
        XCTAssertEqual(command.command, .exec(ExecCommand(name: "demo", argv: ["uname", "-a"], env: [], cwd: "", timeoutSeconds: 60)))
    }

    func testFlags() throws {
        let command = try parseCommand([
            "microvm", "--home", "/tmp/m", "exec", "--timeout", "5", "--cwd", "/tmp", "--env", "FOO=bar", "demo", "--", "id",
        ])
        XCTAssertEqual(command.home?.path, "/tmp/m")
        XCTAssertEqual(
            command.command,
            .exec(ExecCommand(name: "demo", argv: ["id"], env: ["FOO=bar"], cwd: "/tmp", timeoutSeconds: 5))
        )
        let ttl = try parseCommand(["microvm", "run", "--name", "demo", "--ttl", "30", "--boot-timeout", "10"])
        XCTAssertEqual(ttl.command, .run(RunRequest(name: "demo", cpus: 1, memoryMB: 1024, ttlSeconds: 30, bootTimeoutSeconds: 10)))
    }

    func testRejects() {
        XCTAssertThrowsError(try parseCommand(["microvm", "run"]))
        XCTAssertThrowsError(try parseCommand(["microvm", "run", "--name", "bad name"]))
        XCTAssertThrowsError(try parseCommand(["microvm", "run", "--name", "demo", "--cpus", "0"]))
        XCTAssertThrowsError(try parseCommand(["microvm", "run", "--name", "demo", "--memory", "64"]))
        XCTAssertThrowsError(try parseCommand(["microvm", "exec", "demo"]))
        XCTAssertThrowsError(try parseCommand(["microvm", "exec", "demo", "--env", "NOEQUALS", "--", "true"]))
        XCTAssertThrowsError(try parseCommand(["microvm", "nope"]))
    }

    func testHelpMentionsExec() throws {
        XCTAssertEqual(try parseCommand(["microvm"]).command, .help)
        XCTAssertTrue(helpText.contains("microvm exec"))
        XCTAssertTrue(helpText.contains("uname -a"))
    }
}

final class StateTests: XCTestCase {
    func testTransitions() {
        XCTAssertEqual(transition(.booting, .agentReady), .running)
        XCTAssertEqual(transition(.running, .stopRequested), .stopping)
        XCTAssertEqual(transition(.stopping, .guestExited), .stopped)
        XCTAssertEqual(transition(.running, .reap), .stopped)
        XCTAssertEqual(transition(.running, .fault), .failed)
        XCTAssertNil(transition(.running, .agentReady))
        XCTAssertNil(transition(.stopped, .agentReady))
        XCTAssertEqual(transition(.stopped, .reap), .stopped)
    }

    func testExpiryAndTable() {
        let record = VMRecord(
            name: "demo", phase: .running, cpus: 2, memoryMB: 1024,
            daemonToken: "t", createdAtUnix: 100, ttlSeconds: 30, message: nil
        )
        XCTAssertFalse(vmIsExpired(record, now: 129))
        XCTAssertTrue(vmIsExpired(record, now: 130))
        XCTAssertFalse(vmIsExpired(VMRecord(
            name: "demo", phase: .stopped, cpus: 1, memoryMB: 128,
            daemonToken: "t", createdAtUnix: 0, ttlSeconds: 1, message: nil
        ), now: 100))
        let table = formatProcessTable([record], now: 112)
        XCTAssertTrue(table.contains("demo"))
        XCTAssertTrue(table.contains("running"))
        XCTAssertTrue(table.contains("12s"))
        XCTAssertTrue(table.hasPrefix("NAME"))
    }

    func testStoreReap() throws {
        let home = URL(fileURLWithPath: "/tmp/microvm-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = MicroVMPaths(home: home)
        try paths.ensure()
        let store = StateStore(paths: paths)
        try store.save(VMRecord(
            name: "old", phase: .running, cpus: 1, memoryMB: 256,
            daemonToken: "previous", createdAtUnix: 1, ttlSeconds: nil, message: nil
        ))
        try store.save(VMRecord(
            name: "done", phase: .stopped, cpus: 1, memoryMB: 256,
            daemonToken: "previous", createdAtUnix: 1, ttlSeconds: nil, message: nil
        ))
        XCTAssertEqual(try store.reap(currentToken: "current"), 1)
        XCTAssertEqual(try store.load("old")?.phase, .stopped)
        XCTAssertEqual(try store.load("old")?.message, "reaped leftover VM after daemon exit")
        XCTAssertEqual(try store.load("done")?.phase, .stopped)
        XCTAssertNil(try store.load("done")?.message)
    }

    func testNameAndTail() throws {
        try validateVMName("demo.1")
        XCTAssertThrowsError(try validateVMName(".demo"))
        XCTAssertThrowsError(try validateVMName("has space"))
        XCTAssertEqual(tailText("a\nb\nc\n", lines: 2), "b\nc\n")
        XCTAssertEqual(formatAge(0), "0s")
        XCTAssertEqual(formatAge(65), "1m05s")
        XCTAssertEqual(formatAge(3661), "1h01m")
    }
}
