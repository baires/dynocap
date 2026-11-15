import XCTest
@testable import DynoCapCore

final class CLIHelpTests: XCTestCase {
    func testBothHelpFormsCoverCurrentCommands() throws {
        for spec in cliCommandSpecs {
            let viaHelp = try parseCommand(["dynocap", "help"] + spec.path)
            let viaFlag = try parseCommand(["dynocap"] + spec.path + ["--help"])
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
            let viaHelp = try parseCommand(["dynocap", "help"] + topic)
            let viaFlag = try parseCommand(["dynocap"] + topic + ["--help"])
            XCTAssertEqual(viaHelp.command, .help(topic: topic))
            XCTAssertEqual(viaFlag.command, .help(topic: topic))
            assertNoUnimplementedCommands(commandHelp(topic))
        }
        XCTAssertEqual(try parseCommand(["dynocap", "help", "advanced"]).command, .help(topic: ["advanced"]))
        let top = helpText
        XCTAssertTrue(top.contains("dynocap exec"))
        XCTAssertTrue(top.contains("npm ci --offline"))
        XCTAssertTrue(top.contains("dynocap help advanced"))
        let clone = try XCTUnwrap(top.range(of: "dynocap clone"))
        let advanced = try XCTUnwrap(top.range(of: "dynocap help advanced"))
        XCTAssertLessThan(clone.lowerBound, advanced.lowerBound)
        assertNoUnimplementedCommands(top)
        assertNoUnimplementedCommands(commandHelp(["advanced"]))
    }

    func testDocumentedExamplesParse() throws {
        setenv("DYNOCAP_EXAMPLE_TOKEN", "secret", 1)
        defer { unsetenv("DYNOCAP_EXAMPLE_TOKEN") }
        for spec in cliCommandSpecs {
            for example in spec.examples {
                let parts = example.split(separator: " ").map(String.init)
                XCTAssertNoThrow(try parseCommand(parts), example)
            }
        }
    }

    func testGlobalFlagsAndEqualsForms() throws {
        let leading = try parseCommand(["dynocap", "--home", "/tmp/m", "--verbose", "ps"])
        let trailing = try parseCommand(["dynocap", "ps", "--home=/tmp/m", "--verbose"])
        XCTAssertEqual(leading.home?.path, "/tmp/m")
        XCTAssertEqual(trailing.home?.path, "/tmp/m")
        XCTAssertEqual(leading.command, .ps)
        XCTAssertTrue(leading.verbose)
        XCTAssertTrue(trailing.verbose)

        let before = try parseCommand(["dynocap", "--json", "ls"])
        let after = try parseCommand(["dynocap", "ls", "--json"])
        XCTAssertEqual(before.output, .json)
        XCTAssertEqual(after.output, .json)
        XCTAssertEqual(before.command, .ls)

        let run = try parseCommand([
            "dynocap", "run", "--name=demo", "--cpus=2", "--memory=1024", "--ttl=30", "--network=nat", "--boot-timeout=10",
        ])
        XCTAssertEqual(
            run.command,
            .run(RunRequest(
                name: "demo", cpus: 2, memoryMB: 1024, ttlSeconds: 30, bootTimeoutSeconds: 10, network: .nat
            ))
        )
        let spaced = try parseCommand([
            "dynocap", "run", "--name", "demo", "--cpus", "2", "--memory", "1024", "--ttl", "30", "--network", "nat",
            "--boot-timeout", "10",
        ])
        XCTAssertEqual(spaced.command, run.command)

        let exec = try parseCommand([
            "dynocap", "exec", "--timeout=5", "--cwd=/tmp", "--env=FOO=bar", "demo", "--", "id",
        ])
        XCTAssertEqual(
            exec.command,
            .exec(ExecCommand(name: "demo", argv: ["id"], env: ["FOO=bar"], cwd: "/tmp", timeoutSeconds: 5))
        )
        XCTAssertEqual(try parseCommand(["dynocap", "run", "--version"]).command, .version)
        XCTAssertEqual(try parseCommand(["dynocap", "--version", "run"]).command, .version)
    }

    func testGuestArgumentsStayByteForByte() throws {
        let guest = ["--home", "/tmp", "--json", "--help", "-h", "--", "--verbose=1", ""]
        let exec = try parseCommand(["dynocap", "--home", "/tmp/host", "exec", "demo", "--"] + guest)
        guard case .exec(let command) = exec.command else { return XCTFail("expected exec") }
        XCTAssertEqual(command.argv, guest)
        XCTAssertEqual(exec.home?.path, "/tmp/host")
        XCTAssertFalse(exec.verbose)
        XCTAssertEqual(exec.output, .human)

        let swallowed = try parseCommand(["dynocap", "exec", "demo", "uname", "--home", "/tmp"])
        guard case .exec(let raw) = swallowed.command else { return XCTFail("expected exec") }
        XCTAssertEqual(raw.argv, ["uname", "--home", "/tmp"])
        XCTAssertNil(swallowed.home)

        let task = try parseCommand(["dynocap", "task", "exec", "demo", "--"] + guest)
        guard case .taskExec(let taskCommand) = task.command else { return XCTFail("expected task exec") }
        XCTAssertEqual(taskCommand.argv, guest)
    }

    func testUsageErrorsExitTwoWithoutGlobalHelp() throws {
        let cases = [
            ["dynocap", "nope"],
            ["dynocap", "run", "--bogus"],
            ["dynocap", "exec", "demo", "--json", "--", "true"],
            ["dynocap", "ls", "bad"],
            ["dynocap", "--json"],
            ["dynocap", "help", "unknown-command"],
        ]
        for args in cases {
            do {
                _ = try parseCommand(args)
                XCTFail("expected error for \(args)")
            } catch let error as DynoCapError {
                XCTAssertEqual(error.exitCode, 2, args.joined(separator: " "))
                XCTAssertFalse(error.message.contains("disposable sandbox"), error.message)
                XCTAssertFalse(error.message.contains("WORKFLOW"), error.message)
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertTrue(try errorMessage(["dynocap", "run", "--bogus"]).contains("--bogus"))
        XCTAssertTrue(try errorMessage(["dynocap", "nope"]).contains("nope"))
        XCTAssertTrue(try errorMessage(["dynocap", "exec", "demo", "--json", "--", "true"]).contains("--json"))
    }

    func testHelpAndUsageDoNotStartDaemon() throws {
        let binary = try dynocapExecutable()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dynocap-cli-help-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }

        let cloneHelp = try runCLI(binary, ["--home", home.path, "help", "clone"])
        XCTAssertEqual(cloneHelp.status, 0)
        XCTAssertTrue(cloneHelp.stdout.contains("--network"))
        XCTAssertTrue(cloneHelp.stdout.contains("--ssh-key"))
        let flagHelp = try runCLI(binary, ["--home", home.path, "clone", "--help"])
        XCTAssertEqual(flagHelp.status, 0)
        XCTAssertEqual(cloneHelp.stdout, flagHelp.stdout)
        XCTAssertFalse(cloneHelp.stdout.contains("dynocap doctor"))

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
        let logsHelp = try runCLI(binary, ["--home", home.path, "logs", "--help"])
        XCTAssertEqual(logsHelp.status, 0)
        XCTAssertEqual(logsHelp.stderr, "")
        XCTAssertTrue(logsHelp.stdout.contains("--exec"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
    }

    private func assertNoUnimplementedCommands(_ text: String) {
        for hidden in ["dynocap fork"] {
            XCTAssertFalse(text.contains(hidden), hidden)
        }
    }

    private func errorMessage(_ args: [String]) throws -> String {
        do {
            _ = try parseCommand(args)
            XCTFail("expected error")
            return ""
        } catch let error as DynoCapError {
            return error.message
        }
    }

    private func dynocapExecutable() throws -> URL {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["DYNOCAP_BIN"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env))
        }
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            candidates.append(bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("dynocap"))
        }
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent(".build/debug/dynocap"))
        if let match = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) {
            return match
        }
        XCTFail("dynocap executable not found in \(candidates.map(\.path))")
        throw DynoCapError("dynocap executable not found")
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
