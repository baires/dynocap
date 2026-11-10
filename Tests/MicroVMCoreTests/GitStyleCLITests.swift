import XCTest

@testable import MicroVMCore

final class GitStyleCLITests: XCTestCase {
    func testNamedCloneAndResources() throws {
        let invocation = try parseCommand([
            "microvm", "clone", "/tmp/project", "interview", "--cpus", "2", "--memory", "2048", "--network", "filtered",
        ])
        guard case .managed(let command) = invocation.command else { return XCTFail("expected task") }
        XCTAssertEqual(command.name, "interview")
        XCTAssertEqual(command.projectPath, "/tmp/project")
        XCTAssertEqual(command.cpus, 2)
        XCTAssertEqual(command.memoryMB, 2048)
        XCTAssertEqual(command.network, .filtered)
        guard case .managed(let remote) = try parseCommand(["microvm", "clone", "https://github.com/org/repo", "demo"]).command else {
            return XCTFail("expected remote")
        }
        XCTAssertEqual(remote.repositoryUrl, "https://github.com/org/repo")
        XCTAssertNil(remote.network)
    }
    func testListingRemovalFinishAndLegacyCommands() throws {
        XCTAssertEqual(try parseCommand(["microvm", "ls", "--json"]).command, .ls(json: true))
        guard case .managed(let remove) = try parseCommand(["microvm", "rm", "demo", "--purge"]).command else { return XCTFail() }
        XCTAssertEqual(remove.op, "remove")
        XCTAssertEqual(remove.purge, true)
        guard case .managed(let finish) = try parseCommand(["microvm", "finish", "demo"]).command else { return XCTFail() }
        XCTAssertEqual(finish.id, "demo")
        XCTAssertEqual(finish.op, "finish")
        XCTAssertEqual(try parseCommand(["microvm", "ps"]).command, .ps)
        XCTAssertEqual(try parseCommand(["microvm", "destroy", "demo"]).command, .destroy("demo"))
        guard
            case .exec(let exec) = try parseCommand([
                "microvm", "exec", "demo", "--cwd", "/tmp", "--env", "CI=1", "--timeout", "12", "--", "false",
            ]).command
        else { return XCTFail() }
        XCTAssertEqual(exec.cwd, "/tmp")
        XCTAssertEqual(exec.env, ["CI=1"])
        XCTAssertEqual(exec.timeoutSeconds, 12)
        XCTAssertEqual(exec.argv, ["false"])
    }
    func testInvalidSyntaxAndReservedNames() {
        for args in [
            ["clone", "/tmp/p"], ["clone", "/tmp/p", "task-bad"], ["clone", "/tmp/p", "runtime-verify"],
            ["ls", "bad"], ["rm"], ["finish", "demo", "--purge"], ["clone", "/tmp/p", "demo", "--memory", "0"],
        ] {
            XCTAssertThrowsError(try parseCommand(["microvm"] + args), args.joined(separator: " "))
        }
    }
}
