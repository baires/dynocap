import XCTest
@testable import MicroVMCore

final class CLIHelpTests: XCTestCase {
    func testBothHelpFormsCoverCurrentCommands() throws {
        for spec in cliCommandSpecs {
            let viaHelp = try parseCommand(["microvm", "help"] + spec.path)
            let viaFlag = try parseCommand(["microvm"] + spec.path + ["--help"])
            guard case .help(let left) = viaHelp.command, case .help(let right) = viaFlag.command else {
                return XCTFail("expected help for \(spec.path)")
            }
            XCTAssertEqual(left, spec.path)
            XCTAssertEqual(right, spec.path)
            let text = commandHelp(spec.path)
            let examples = spec.examples.joined(separator: "\n")
            for flag in spec.flags {
                XCTAssertTrue(text.contains(flag.name), "\(spec.path) missing \(flag.name)")
                XCTAssertTrue(examples.contains(flag.name), "\(spec.path) example missing \(flag.name)")
            }
            assertNoUnimplementedCommands(text)
        }
        for topic in [["task"], ["runtime"]] {
            let viaHelp = try parseCommand(["microvm", "help"] + topic)
            let viaFlag = try parseCommand(["microvm"] + topic + ["--help"])
            XCTAssertEqual(viaHelp.command, .help(topic: topic))
            XCTAssertEqual(viaFlag.command, .help(topic: topic))
            assertNoUnimplementedCommands(commandHelp(topic))
        }
        XCTAssertEqual(try parseCommand(["microvm", "help", "advanced"]).command, .help(topic: ["advanced"]))
        let top = helpText
        XCTAssertTrue(top.contains("microvm exec"))
        XCTAssertTrue(top.contains("uname -a"))
        XCTAssertTrue(top.contains("microvm help advanced"))
        let clone = try XCTUnwrap(top.range(of: "microvm clone"))
        let advanced = try XCTUnwrap(top.range(of: "microvm help advanced"))
        XCTAssertLessThan(clone.lowerBound, advanced.lowerBound)
        assertNoUnimplementedCommands(top)
        assertNoUnimplementedCommands(commandHelp(["advanced"]))
    }

    func testDocumentedExamplesParse() throws {
        setenv("MICROVM_EXAMPLE_TOKEN", "secret", 1)
        defer { unsetenv("MICROVM_EXAMPLE_TOKEN") }
        for spec in cliCommandSpecs {
            for example in spec.examples {
                let parts = example.split(separator: " ").map(String.init)
                XCTAssertNoThrow(try parseCommand(parts), example)
            }
        }
    }

    func testGlobalFlagsAndEqualsForms() throws {
        let leading = try parseCommand(["microvm", "--home", "/tmp/m", "--verbose", "ps"])
        let trailing = try parseCommand(["microvm", "ps", "--home=/tmp/m", "--verbose"])
        XCTAssertEqual(leading.home?.path, "/tmp/m")
        XCTAssertEqual(trailing.home?.path, "/tmp/m")
        XCTAssertEqual(leading.command, .ps)
        XCTAssertTrue(leading.verbose)
        XCTAssertTrue(trailing.verbose)

        let before = try parseCommand(["microvm", "--json", "ls"])
        let after = try parseCommand(["microvm", "ls", "--json"])
        XCTAssertEqual(before.output, .json)
        XCTAssertEqual(after.output, .json)
        XCTAssertEqual(before.command, .ls)

        let run = try parseCommand([
            "microvm", "run", "--name=demo", "--cpus=2", "--memory=1024", "--ttl=30", "--network=nat", "--boot-timeout=10",
        ])
        XCTAssertEqual(
            run.command,
            .run(RunRequest(
                name: "demo", cpus: 2, memoryMB: 1024, ttlSeconds: 30, bootTimeoutSeconds: 10, network: .nat
            ))
        )
        let spaced = try parseCommand([
            "microvm", "run", "--name", "demo", "--cpus", "2", "--memory", "1024", "--ttl", "30", "--network", "nat",
            "--boot-timeout", "10",
        ])
        XCTAssertEqual(spaced.command, run.command)

        let exec = try parseCommand([
            "microvm", "exec", "--timeout=5", "--cwd=/tmp", "--env=FOO=bar", "demo", "--", "id",
        ])
        XCTAssertEqual(
            exec.command,
            .exec(ExecCommand(name: "demo", argv: ["id"], env: ["FOO=bar"], cwd: "/tmp", timeoutSeconds: 5))
        )
        XCTAssertEqual(try parseCommand(["microvm", "run", "--version"]).command, .version)
        XCTAssertEqual(try parseCommand(["microvm", "--version", "run"]).command, .version)
    }

    func testGuestArgumentsStayByteForByte() throws {
        let guest = ["--home", "/tmp", "--json", "--help", "-h", "--", "--verbose=1", ""]
        let exec = try parseCommand(["microvm", "--home", "/tmp/host", "exec", "demo", "--"] + guest)
        guard case .exec(let command) = exec.command else { return XCTFail("expected exec") }
        XCTAssertEqual(command.argv, guest)
        XCTAssertEqual(exec.home?.path, "/tmp/host")
        XCTAssertFalse(exec.verbose)
        XCTAssertEqual(exec.output, .human)

        let swallowed = try parseCommand(["microvm", "exec", "demo", "uname", "--home", "/tmp"])
        guard case .exec(let raw) = swallowed.command else { return XCTFail("expected exec") }
        XCTAssertEqual(raw.argv, ["uname", "--home", "/tmp"])
        XCTAssertNil(swallowed.home)

        let task = try parseCommand(["microvm", "task", "exec", "demo", "--"] + guest)
        guard case .task(let taskCommand) = task.command else { return XCTFail("expected task") }
        XCTAssertEqual(taskCommand.argv, guest)
    }

    func testUsageErrorsExitTwoWithoutGlobalHelp() throws {
        let cases = [
            ["microvm", "nope"],
            ["microvm", "run", "--bogus"],
            ["microvm", "exec", "demo", "--json", "--", "true"],
            ["microvm", "ls", "bad"],
            ["microvm", "--json"],
            ["microvm", "help", "doctor"],
        ]
        for args in cases {
            do {
                _ = try parseCommand(args)
                XCTFail("expected error for \(args)")
            } catch let error as MicroVMError {
                XCTAssertEqual(error.exitCode, 2, args.joined(separator: " "))
                XCTAssertFalse(error.message.contains("disposable sandbox"), error.message)
                XCTAssertFalse(error.message.contains("WORKFLOW"), error.message)
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertTrue(try errorMessage(["microvm", "run", "--bogus"]).contains("--bogus"))
        XCTAssertTrue(try errorMessage(["microvm", "nope"]).contains("nope"))
        XCTAssertTrue(try errorMessage(["microvm", "exec", "demo", "--json", "--", "true"]).contains("--json"))
    }

    func testHelpAndUsageDoNotStartDaemon() throws {
        let binary = try microvmExecutable()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("microvm-cli-help-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }

        let cloneHelp = try runCLI(binary, ["--home", home.path, "help", "clone"])
        XCTAssertEqual(cloneHelp.status, 0)
        XCTAssertTrue(cloneHelp.stdout.contains("--network"))
        XCTAssertTrue(cloneHelp.stdout.contains("--ssh-key"))
        let flagHelp = try runCLI(binary, ["--home", home.path, "clone", "--help"])
        XCTAssertEqual(flagHelp.status, 0)
        XCTAssertEqual(cloneHelp.stdout, flagHelp.stdout)
        XCTAssertFalse(cloneHelp.stdout.contains("microvm doctor"))

        let unknown = try runCLI(binary, ["--home", home.path, "nope"])
        XCTAssertEqual(unknown.status, 2)
        XCTAssertTrue(unknown.stderr.contains("nope"))
        XCTAssertFalse(unknown.stderr.contains("disposable sandbox"))

        let verbose = try runCLI(binary, ["--home", home.path, "--verbose", "nope"])
        XCTAssertEqual(verbose.status, 2)
        XCTAssertTrue(verbose.stderr.contains("exit 2"))

        let badFlag = try runCLI(binary, ["--home", home.path, "run", "--bogus"])
        XCTAssertEqual(badFlag.status, 2)
        XCTAssertTrue(badFlag.stderr.contains("--bogus"))
        let inspectHelp = try runCLI(binary, ["--home", home.path, "inspect", "--help"])
        XCTAssertEqual(inspectHelp.status, 0)
        XCTAssertEqual(inspectHelp.stderr, "")
        XCTAssertTrue(inspectHelp.stdout.contains("NAME_OR_ID"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
    }

    private func assertNoUnimplementedCommands(_ text: String) {
        for hidden in ["microvm doctor", "microvm shell", "microvm logs", "microvm fork"] {
            XCTAssertFalse(text.contains(hidden), hidden)
        }
    }

    private func errorMessage(_ args: [String]) throws -> String {
        do {
            _ = try parseCommand(args)
            XCTFail("expected error")
            return ""
        } catch let error as MicroVMError {
            return error.message
        }
    }

    private func microvmExecutable() throws -> URL {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["MICROVM_BIN"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env))
        }
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            candidates.append(bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("microvm"))
        }
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent(".build/debug/microvm"))
        if let match = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) {
            return match
        }
        XCTFail("microvm executable not found in \(candidates.map(\.path))")
        throw MicroVMError("microvm executable not found")
    }

    private func runCLI(_ binary: URL, _ arguments: [String]) throws -> CLIProcessResult {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let finished = expectation(description: arguments.joined(separator: " "))
        process.terminationHandler = { _ in finished.fulfill() }
        try process.run()
        wait(for: [finished], timeout: 3)
        if process.isRunning {
            process.terminate()
            XCTFail("hung: \(arguments)")
        }
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CLIProcessResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

private struct CLIProcessResult {
    var status: Int32
    var stdout: String
    var stderr: String
}
