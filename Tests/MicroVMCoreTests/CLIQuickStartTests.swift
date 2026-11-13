import XCTest

@testable import MicroVMCore

/// The README quick start and `microvm help` teach one workflow; this keeps them identical and runnable.
final class CLIQuickStartTests: XCTestCase {
    private var lines: [String] { quickStart.split(separator: "\n").map(String.init) }

    func testReadmeQuickStartIsTheHelpWorkflow() throws {
        let readme = try String(contentsOfFile: "README.md", encoding: .utf8)
        let marker = try XCTUnwrap(readme.range(of: "<!-- quick start: kept identical to `microvm help` by CLIQuickStartTests -->"))
        let tail = readme[marker.upperBound...]
        let open = try XCTUnwrap(tail.range(of: "```sh\n"))
        let close = try XCTUnwrap(tail[open.upperBound...].range(of: "```"))
        XCTAssertEqual(String(tail[open.upperBound..<close.lowerBound]), quickStart + "\n")
        let help = commandHelp([])
        let block = lines.map { "  " + $0 }.joined(separator: "\n")
        XCTAssertTrue(help.contains("WORKFLOW\n" + block + "\n\nRUNTIMES"), help)
    }

    func testEveryWorkflowLineParses() throws {
        var commands: [CLICommand] = []
        for line in lines {
            let command = line.components(separatedBy: " #").first!.trimmingCharacters(in: .whitespaces)
            let args = command.split(separator: " ").map(String.init)
            XCTAssertEqual(args.first, "microvm", line)
            commands.append(try parseCommand(args).command)
        }
        // Explicit preparation, an explicitly networked install, then offline work.
        XCTAssertEqual(commands.first, .doctor(DoctorRequest(fix: true, project: "./project")))
        let clones = commands.compactMap { command -> TaskCommand? in
            guard case .managed(let task) = command, task.op == "start" else { return nil }
            return task
        }
        XCTAssertEqual(clones.map(\.name), ["deps", "demo"])
        XCTAssertEqual(clones.map(\.network), [.filtered, nil], "demo uses the offline default")
        let execs = commands.compactMap { command -> ExecCommand? in
            guard case .exec(let exec) = command else { return nil }
            return exec
        }
        XCTAssertEqual(execs.map(\.argv), [["npm", "ci"], ["npm", "ci", "--offline"], ["npm", "test"]])
        XCTAssertEqual(execs.first?.timeoutSeconds, 300)
        XCTAssertTrue(commands.contains { if case .shell = $0 { return true } else { return false } })
        let removals = commands.compactMap { command -> TaskCommand? in
            guard case .managed(let task) = command, task.op == "remove" else { return nil }
            return task
        }
        XCTAssertEqual(removals.map(\.force), [false, false], "both sandboxes are finished before rm")
    }
}
