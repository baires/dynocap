import XCTest

@testable import DynoCapCore

/// Checks every exposed command against docs/reference/cli/commands.mdx: help, JSON support,
/// usage errors, and the overlapping forms that must behave like their primary command.
final class CLICommandMatrixTests: XCTestCase {
    /// A minimal valid invocation for every command in the help specs.
    private static let samples: [[String]: [String]] = [
        ["runtime", "prepare"]: ["runtime", "prepare", "."],
        ["clone"]: ["clone", "./project", "demo"],
        ["ls"]: ["ls"],
        ["doctor"]: ["doctor"],
        ["logs"]: ["logs", "demo"],
        ["inspect"]: ["inspect", "demo"],
        ["exec"]: ["exec", "demo", "--", "true"],
        ["shell"]: ["shell", "demo"],
        ["diff"]: ["diff", "demo"],
        ["finish"]: ["finish", "demo"],
        ["rm"]: ["rm", "demo"],
        ["run"]: ["run", "--name", "demo"],
        ["ps"]: ["ps"],
        ["destroy"]: ["destroy", "demo"],
        ["daemon"]: ["daemon"],
        ["task", "start"]: ["task", "start", "./project"],
        ["task", "exec"]: ["task", "exec", "demo", "--", "true"],
        ["task", "finish"]: ["task", "finish", "demo"],
        ["version"]: ["version"],
        ["help"]: ["help"],
    ]

    /// Adds an option before a guest command separator so it stays a dynocap flag.
    private func with(_ sample: [String], _ flag: String) -> [String] {
        guard let separator = sample.firstIndex(of: "--") else { return sample + [flag] }
        return Array(sample[..<separator]) + [flag] + Array(sample[separator...])
    }

    private struct MatrixRow {
        var group: String
        var json: Bool
    }

    private func matrixRows() throws -> [[String]: MatrixRow] {
        let text = try String(contentsOfFile: "docs/reference/cli/commands.mdx", encoding: .utf8)
        var rows: [[String]: MatrixRow] = [:]
        for line in text.split(separator: "\n") where line.hasPrefix("| `dynocap ") {
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            let command = cells[0].trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            let path = command.split(separator: " ").dropFirst().map(String.init)
            XCTAssertNil(rows[path], "duplicate matrix row \(command)")
            XCTAssertTrue(["yes", "no"].contains(cells[3]), line.description)
            rows[path] = MatrixRow(group: cells[1], json: cells[3] == "yes")
        }
        return rows
    }

    func testMatrixDocumentsEveryCommandAndItsJSONSupport() throws {
        let specs = Set(cliCommandSpecs.map(\.path))
        XCTAssertEqual(specs, Set(Self.samples.keys), "every command needs a sample invocation")
        let rows = try matrixRows()
        XCTAssertEqual(Set(rows.keys), specs, "docs/reference/cli/commands.mdx lists exactly the exposed commands")
        for spec in cliCommandSpecs {
            let row = try XCTUnwrap(rows[spec.path])
            XCTAssertEqual(row.json, spec.allowsJSON, spec.path.joined(separator: " "))
            XCTAssertEqual(row.group, spec.group == .primary ? "primary" : "advanced", spec.path.joined(separator: " "))
            XCTAssertEqual(spec.flags.contains { $0.name == "--json" }, spec.allowsJSON, "help lists --json only where it works")
        }
    }

    func testEveryCommandParsesHelpJSONAndUnknownFlagsConsistently() throws {
        for spec in cliCommandSpecs {
            let path = spec.path
            let sample = try XCTUnwrap(Self.samples[path])
            let label = path.joined(separator: " ")
            XCTAssertNoThrow(try parseCommand(["dynocap"] + sample), label)
            XCTAssertEqual(try parseCommand(["dynocap"] + path + ["--help"]).command, .help(topic: path), label)
            XCTAssertEqual(try parseCommand(["dynocap", "help"] + path).command, .help(topic: path), label)
            let help = commandHelp(path)
            XCTAssertTrue(help.hasPrefix("dynocap " + label + "\n"), label)
            let sections = help.components(separatedBy: "\n")
            let usage = try XCTUnwrap(sections.firstIndex(of: "USAGE"), label)
            let examples = try XCTUnwrap(sections.firstIndex(of: "EXAMPLES"), label)
            let details = try XCTUnwrap(sections.firstIndex(of: "DETAILS"), label)
            let globals = try XCTUnwrap(sections.firstIndex(of: "GLOBAL OPTIONS"), label)
            XCTAssertEqual([usage, examples, details, globals], [usage, examples, details, globals].sorted(), label)
            XCTAssertEqual(sections[usage + 1], "  " + spec.usage, label)
            XCTAssertTrue(try parseCommand(["dynocap"] + path + ["--help", "--no-color"]).noColor, label)
            for args in [with(sample, "--no-color"), ["--no-color"] + sample] {
                XCTAssertTrue(try parseCommand(["dynocap"] + args).noColor, label)
            }
            XCTAssertThrowsError(try parseCommand(["dynocap"] + with(sample, "--bogus")), label) {
                XCTAssertEqual(($0 as? DynoCapError)?.exitCode, 2, label)
                XCTAssertTrue(($0 as? DynoCapError)?.message.contains("--bogus") == true, label)
            }
            for args in [with(sample, "--json"), ["--json"] + sample] {
                if spec.allowsJSON {
                    XCTAssertEqual(try parseCommand(["dynocap"] + args).output, .json, label)
                } else {
                    XCTAssertThrowsError(try parseCommand(["dynocap"] + args), label) {
                        XCTAssertEqual(($0 as? DynoCapError)?.exitCode, 2, label)
                        XCTAssertTrue(($0 as? DynoCapError)?.message.contains("does not support --json") == true, label)
                    }
                }
            }
        }
    }

    func testOverlappingFormsBuildTheSameRequests() throws {
        let flagSets: [[String]] = [
            [], ["--timeout", "5"], ["--timeout=300", "--cwd", "/tmp"], ["--env", "CI=1", "--env=A=b"],
            ["-i"], ["--no-input"], ["-t"], ["-it"], ["--tty", "--cwd=/work"],
        ]
        for flags in flagSets {
            guard case .exec(let exec) = try parseCommand(["dynocap", "exec", "demo"] + flags + ["--", "npm", "test", "--json"]).command,
                  case .taskExec(let task) = try parseCommand(["dynocap", "task", "exec", "demo"] + flags + ["--", "npm", "test", "--json"]).command
            else { return XCTFail("expected exec forms for \(flags)") }
            XCTAssertEqual(exec, task, "\(flags)")
        }
        guard case .taskExec(let defaults) = try parseCommand(["dynocap", "task", "exec", "demo", "--", "true"]).command else {
            return XCTFail("expected task exec")
        }
        XCTAssertEqual(defaults.timeoutSeconds, 60)
        XCTAssertEqual(defaults.cwd, "", "the daemon picks /workspace for a project and / for a raw sandbox")
        for flags in [["--timeout", "0"], ["--no-input", "-t"], ["--env", "bad"]] {
            XCTAssertThrowsError(try parseCommand(["dynocap", "task", "exec", "demo"] + flags + ["--", "true"]), "\(flags)") {
                XCTAssertEqual(($0 as? DynoCapError)?.exitCode, 2)
            }
        }
        XCTAssertThrowsError(try parseCommand(["dynocap", "task", "exec", "demo"])) {
            XCTAssertEqual(($0 as? DynoCapError)?.message, "task exec requires a command. Example: dynocap task exec demo -- uname -a")
        }

        guard case .managed(let clone) = try parseCommand(["dynocap", "clone", "/tmp/p", "demo", "--ttl", "60", "--network", "nat"]).command,
              case .task(let start) = try parseCommand(["dynocap", "task", "start", "/tmp/p", "--name", "demo", "--ttl", "60", "--network", "nat"]).command
        else { return XCTFail("expected creation forms") }
        XCTAssertEqual(clone, start)
        guard case .managed(let finish) = try parseCommand(["dynocap", "finish", "demo"]).command,
              case .task(let taskFinish) = try parseCommand(["dynocap", "task", "finish", "demo"]).command
        else { return XCTFail("expected finish forms") }
        XCTAssertEqual(finish, taskFinish)
        for flags in [[], ["--force"]] {
            guard case .managed(let rm) = try parseCommand(["dynocap", "rm", "demo"] + flags).command,
                  case .destroy(let destroy) = try parseCommand(["dynocap", "destroy", "demo"] + flags).command
            else { return XCTFail("expected removal forms") }
            XCTAssertEqual(rm, destroy, "\(flags)")
            XCTAssertEqual(destroy.op, "remove")
            XCTAssertEqual(destroy.force, !flags.isEmpty)
            XCTAssertEqual(destroy.purge, false)
        }
        XCTAssertThrowsError(try parseCommand(["dynocap", "destroy", "demo", "--purge"])) {
            XCTAssertEqual(($0 as? DynoCapError)?.exitCode, 2, "destroy keeps retained results; purge is rm's")
        }
    }

    func testEveryCommandAtTheProcessBoundaryWithoutADaemon() throws {
        let home = URL(fileURLWithPath: "/tmp/dynocap-matrix-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        for spec in cliCommandSpecs {
            let path = spec.path
            let label = path.joined(separator: " ")
            let sample = try XCTUnwrap(Self.samples[path])
            for args in [["help"] + path, path + ["--help"]] {
                let result = try runCLI(home: home, args)
                XCTAssertEqual(result.status, 0, label)
                XCTAssertEqual(result.stdout, commandHelp(path), label)
                XCTAssertEqual(result.stderr, "", label)
            }
            let bogus = try runCLI(home: home, with(sample, "--bogus"))
            XCTAssertEqual(bogus.status, 2, label)
            XCTAssertEqual(bogus.stdout, "", label)
            XCTAssertTrue(bogus.stderr.contains("unknown flag --bogus"), "\(label): \(bogus.stderr)")
            if !spec.allowsJSON {
                let json = try runCLI(home: home, with(sample, "--json"))
                XCTAssertEqual(json.status, 2, label)
                XCTAssertEqual(json.stdout, "", label)
                let error = try JSONSerialization.jsonObject(with: Data(json.stderr.utf8)) as? [String: Any]
                XCTAssertEqual((error?["error"] as? [String: Any])?["code"] as? String, "invalid_usage", label)
            }
        }
        let version = try runCLI(home: home, ["version", "--json"])
        XCTAssertEqual(version.status, 0)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(version.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "guestArch", "virtualizationAvailable"])
        XCTAssertEqual(object["version"] as? String, DynoCapInfo.version)
        XCTAssertEqual(try runCLI(home: home, ["--version", "--json"]).stdout, version.stdout)
        XCTAssertEqual(try runCLI(home: home, ["version"]).stdout, DynoCapInfo.describe())
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path), "help, usage errors, and version start no daemon")
    }

    func testAdvancedFormsMatchPrimaryFormsAgainstADaemon() throws {
        let harness = try MatrixHarness()
        defer { harness.close() }
        let human = try runCLI(home: harness.home, ["run", "--name", "raw", "--ttl", "600"])
        XCTAssertEqual(human.status, 0, human.stderr)
        XCTAssertTrue(human.stdout.hasPrefix("Created raw sandbox: raw\nPhase: running\nNetwork: none\nTTL: "), human.stdout)
        XCTAssertTrue(human.stdout.contains("remaining ("), human.stdout)
        XCTAssertTrue(human.stdout.contains("expiration or removal discards everything in it"), human.stdout)
        XCTAssertTrue(human.stdout.contains("Next: dynocap --home \(shellWord(harness.home.path)) exec raw -- uname -a"), human.stdout)
        XCTAssertEqual(human.stderr, "Booting the sandbox...\n")
        let json = try runCLI(home: harness.home, ["run", "--name", "raw2", "--network", "none", "--json"])
        XCTAssertEqual(json.status, 0, json.stderr)
        XCTAssertEqual(json.stderr, "", "JSON suppresses progress")
        let created = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(Set(created.keys), ["name", "kind", "phase", "network", "ttlSeconds", "sandboxExpiresAtUnix",
                                           "onSandboxExpiration", "nextCommand"])
        XCTAssertEqual(created["kind"] as? String, "sandbox")
        XCTAssertEqual(created["onSandboxExpiration"] as? String, "discard_sandbox")
        let record = try XCTUnwrap(try harness.client.ps().first { $0.name == "raw2" })
        XCTAssertEqual((created["sandboxExpiresAtUnix"] as? NSNumber)?.int64Value, record.createdAtUnix + 1800)

        // ps is ls limited to raw sandboxes, in both formats.
        let ps = try runCLI(home: harness.home, ["ps", "--json"])
        let ls = try runCLI(home: harness.home, ["ls", "--json"])
        XCTAssertEqual(ps.status, 0, ps.stderr)
        XCTAssertEqual(ps.stdout, ls.stdout, "only raw sandboxes exist, so the listings match")
        let listed = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(ps.stdout.utf8)) as? [[String: Any]])
        XCTAssertEqual(listed.map { $0["name"] as? String }, ["raw", "raw2"])
        XCTAssertEqual(Set(listed.map { $0["kind"] as? String }), ["sandbox"])
        // A minute boundary changes both the text and the column padding, so compare the rows with either removed.
        func layout(_ text: String) -> String {
            text.replacingOccurrences(of: #"\d+[smhd] left"#, with: "N", options: .regularExpression)
                .replacingOccurrences(of: #" +"#, with: " ", options: .regularExpression)
        }
        let psHuman = try runCLI(home: harness.home, ["ps"])
        XCTAssertEqual(layout(psHuman.stdout), layout(try runCLI(home: harness.home, ["ls"]).stdout))
        XCTAssertTrue(psHuman.stdout.hasPrefix("NAME/ID  PHASE"), psHuman.stdout)

        // exec and task exec send identical requests and report the same streams and status.
        for flags in [[], ["--timeout", "5", "--cwd", "/tmp", "--env", "CI=1"], ["--no-input"]] {
            var results: [(CLIResult, ExecRequest)] = []
            for command in [["exec"], ["task", "exec"]] {
                let result = try runCLI(home: harness.home, command + ["raw"] + flags + ["--", "fail", "--json"])
                results.append((result, try XCTUnwrap(harness.backend.requests.last)))
            }
            let (exec, execRequest) = results[0]
            let (task, taskRequest) = results[1]
            XCTAssertEqual(exec.status, 7, "\(flags)")
            XCTAssertEqual(task.status, exec.status, "\(flags)")
            XCTAssertEqual(task.stdout, exec.stdout)
            XCTAssertEqual(task.stderr, exec.stderr)
            XCTAssertEqual(exec.stdout, "fail --json\n")
            XCTAssertEqual(exec.stderr, "failed\n")
            XCTAssertEqual(taskRequest.argv, execRequest.argv)
            XCTAssertEqual(taskRequest.cwd, execRequest.cwd)
            XCTAssertEqual(taskRequest.env, execRequest.env)
            XCTAssertEqual(taskRequest.timeoutSeconds, execRequest.timeoutSeconds)
            XCTAssertEqual(taskRequest.streamStdin, execRequest.streamStdin)
        }
        XCTAssertEqual(harness.backend.requests.first?.timeoutSeconds, 60)
        XCTAssertEqual(harness.backend.requests.first?.cwd, "/")

        // destroy follows rm's removal intent: a live sandbox needs --force.
        let refused = try runCLI(home: harness.home, ["destroy", "raw"])
        XCTAssertEqual(refused.status, 1)
        XCTAssertEqual(refused.stdout, "")
        XCTAssertTrue(refused.stderr.contains("dynocap: destroy: refusing to remove live sandbox raw"), refused.stderr)
        XCTAssertTrue(refused.stderr.contains("--force"), refused.stderr)
        let refusedJSON = try runCLI(home: harness.home, ["destroy", "raw", "--json"])
        XCTAssertEqual(refusedJSON.status, 1)
        let error = try JSONSerialization.jsonObject(with: Data(refusedJSON.stderr.utf8)) as? [String: Any]
        XCTAssertEqual((error?["error"] as? [String: Any])?["code"] as? String, "invalid_phase")
        XCTAssertEqual(try harness.client.ps().map(\.name).sorted(), ["raw", "raw2"], "refusal changed nothing")

        let destroyed = try runCLI(home: harness.home, ["destroy", "raw", "--force", "--json"])
        let removed = try runCLI(home: harness.home, ["rm", "raw2", "--force", "--json"])
        for (result, name) in [(destroyed, "raw"), (removed, "raw2")] {
            XCTAssertEqual(result.status, 0, result.stderr)
            XCTAssertEqual(result.stderr, "")
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
            XCTAssertEqual(object["target"] as? String, name)
            XCTAssertEqual(object["removed"] as? Bool, true)
            XCTAssertEqual(object["purged"] as? Bool, false)
        }
        XCTAssertEqual(try runCLI(home: harness.home, ["ps"]).stdout, "No raw sandboxes.\n")
        XCTAssertEqual(try runCLI(home: harness.home, ["ps", "--json"]).stdout, "[]\n")

        // Documented SDK distinction: Sandbox.destroy and dynocap_destroy send the daemon's destroy
        // request, which discards a live raw sandbox without a force flag (and refuses a live project).
        _ = try harness.client.run(RunRequest(name: "sdk", cpus: 1, memoryMB: 256, ttlSeconds: 60, bootTimeoutSeconds: 5))
        XCTAssertNoThrow(try harness.client.destroy("sdk"))
        XCTAssertEqual(try harness.client.ps(), [])
    }

    // MARK: - Process helpers

    private struct CLIResult {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    private func runCLI(home: URL, _ args: [String]) throws -> CLIResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DYNOCAP_BIN"] ?? ".build/debug/dynocap")
        process.arguments = ["--home", home.path] + args
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CLIResult(
            status: process.terminationStatus, stdout: String(bytes: stdout, encoding: .utf8) ?? "",
            stderr: String(bytes: stderr, encoding: .utf8) ?? "")
    }
}

private final class MatrixHarness {
    let home = URL(fileURLWithPath: "/tmp/dynocap-matrix-daemon-\(UUID().uuidString)")
    let backend = MatrixBackend()
    let daemon: Daemon
    let client: DaemonClient

    init() throws {
        daemon = Daemon(home: home, backend: backend)
        try daemon.start()
        let paths = daemon.paths
        try FileManager.default.createDirectory(at: paths.imageDir(HostArch.guest), withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: paths.kernel(HostArch.guest).path, contents: Data("kernel".utf8))
        _ = FileManager.default.createFile(atPath: paths.initrd(HostArch.guest).path, contents: Data("initrd".utf8))
        client = DaemonClient(socketPath: paths.socket.path)
    }

    func close() {
        daemon.stop()
        try? FileManager.default.removeItem(at: home)
    }
}

/// Echoes argv to stdout. `fail` also writes stderr and exits 7.
private final class MatrixBackend: VMBackend {
    var onGuestExit: ((String, UUID, String?) -> Void)?
    private let lock = NSLock()
    private var recorded: [ExecRequest] = []

    var requests: [ExecRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func boot(_ request: BootRequest, completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
    func destroy(name: String, completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
    func cancelExec(name: String, id: UInt32) {}
    func writeStdin(name: String, id: UInt32, data: Data) throws {}
    func closeStdin(name: String, id: UInt32) throws {}

    func exec(_ request: ExecRequest, emit: @escaping (ExecEvent) -> Void) {
        lock.lock()
        recorded.append(request)
        lock.unlock()
        emit(.stdout(Data((request.argv.joined(separator: " ") + "\n").utf8)))
        if request.argv.first == "fail" {
            emit(.stderr(Data("failed\n".utf8)))
            emit(.finished(code: 7, signal: 0))
        } else {
            emit(.finished(code: 0, signal: 0))
        }
    }
}
