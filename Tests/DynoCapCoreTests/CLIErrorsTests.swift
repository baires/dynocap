import XCTest
@testable import DynoCapCore

final class CLIErrorsTests: XCTestCase {
    func testSharedControlErrorVectors() throws {
        struct Vector: Decodable {
            var error: DynoCapError
            var hex: String
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let vectors = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: root.appendingPathComponent("testdata/control-error-vectors.json")))
        for vector in vectors {
            let frame = try ControlCodec.encode(.error(daemonErrorText(vector.error)))
            XCTAssertEqual(frame.map { String(format: "%02x", $0) }.joined(), vector.hex)
            XCTAssertEqual(daemonError(daemonErrorText(vector.error)), vector.error)
        }
    }

    func testTypedErrorRoundTripAndNoMessageMatching() throws {
        let expected = DynoCapError("deadline reached", exitCode: 124, code: .commandTimeout)
        let frame = try ControlCodec.decode(ControlCodec.encode(.error(daemonErrorText(expected))))
        guard case .error(let text) = frame else { return XCTFail("expected error") }
        XCTAssertEqual(daemonError(text), expected)
        XCTAssertEqual(daemonError("dependency lookup timed out").exitCode, 1)
        XCTAssertEqual(daemonError("dependency lookup timed out").code, .operationFailed)
        XCTAssertEqual(daemonError("dynocap-error-v1:{}").exitCode, 1)
    }

    func testJSONFailureSchemaAndSafeVerboseDiagnostics() throws {
        let secret = "short-token-value"
        let key = "test-key-value"
        setenv("DYNOCAP_TEST_API_KEY", key, 1)
        defer { unsetenv("DYNOCAP_TEST_API_KEY") }
        let error = DynoCapError("fetch https://user:pass@example.com/repo?token=hidden failed: \(secret) \(key)")
        let args = ["dynocap", "clone", "url", "demo", "--json", "--verbose", "--env", "TOKEN=\(secret)"]
        let result = formatCLIFailure(error, arguments: args)
        for value in [secret, key, "user:pass", "token=hidden"] { XCTAssertFalse(result.text.contains(value), value) }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])
        let failure = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(Set(failure.keys), ["code", "message", "recovery", "exitCode"])
        XCTAssertEqual(failure["code"] as? String, "operation_failed")
        XCTAssertEqual(failure["exitCode"] as? Int, 1)
        XCTAssertNotNil(object["diagnostics"])
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertFalse(result.text.contains("\u{1b}"))
    }

    func testKnownSecretFieldsAndAuthorizationAreRedacted() {
        let input = #"GITHUB_TOKEN=abc123 Authorization: Bearer xyz456 {"gitToken":"json-secret"} password='with spaces'"#
        let result = formatCLIFailure(DynoCapError(input), arguments: ["dynocap", "ls", "--verbose"])
        for secret in ["abc123", "xyz456", "json-secret", "with spaces"] {
            XCTAssertFalse(result.text.contains(secret), result.text)
        }
    }

    func testFailureFlagsRespectGuestAndValuedArgumentBoundaries() {
        for args in [
            ["dynocap", "exec", "demo", "--", "echo", "--json", "--verbose"],
            ["dynocap", "exec", "demo", "echo", "--json", "--verbose"],
            ["dynocap", "task", "exec", "demo", "--", "echo", "--json", "--verbose"],
            ["dynocap", "ls", "--home", "--json"],
        ] {
            XCTAssertFalse(cliFailureOptions(args).json, args.joined(separator: " "))
            XCTAssertFalse(cliFailureOptions(args).verbose, args.joined(separator: " "))
        }
        XCTAssertTrue(cliFailureOptions(["dynocap", "--json", "ls", "--bogus"]).json)
    }

    func testProcessErrorsAndContentStreams() throws {
        let home = URL(fileURLWithPath: "/tmp/dynocap-errors-\(UUID().uuidString)")
        let daemon = Daemon(home: home, backend: ErrorTestBackend())
        try daemon.start()
        defer {
            daemon.stop()
            try? FileManager.default.removeItem(at: home)
        }
        let images = daemon.paths.imageDir(HostArch.guest)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try Data("kernel".utf8).write(to: daemon.paths.kernel(HostArch.guest))
        try Data("initrd".utf8).write(to: daemon.paths.initrd(HostArch.guest))
        let client = DaemonClient(socketPath: daemon.paths.socket.path)
        _ = try client.run(RunRequest(name: "demo", cpus: 1, memoryMB: 256, ttlSeconds: 300, bootTimeoutSeconds: 5))

        let missing = try runCLI(home, ["exec", "missing", "--", "true"])
        XCTAssertEqual(missing.status, 1)
        XCTAssertEqual(missing.stdout, Data())
        XCTAssertTrue(missing.errorText.contains("missing"))
        XCTAssertTrue(missing.errorText.contains("dynocap ls"))
        XCTAssertFalse(missing.errorText.contains("dynocap-error-v1:"))

        for command in [["exec", "demo", "--json", "--", "true"], ["diff", "demo", "--json"], ["logs", "demo", "--json"]] {
            let invalid = try runCLI(home, command)
            XCTAssertEqual(invalid.status, 2)
            XCTAssertEqual(invalid.stdout, Data())
            XCTAssertTrue(invalid.errorText.contains("--json"))
        }
        let invalid = try runCLI(home, ["ls", "--json", "--bad"])
        XCTAssertEqual(invalid.status, 2)
        XCTAssertEqual(invalid.stdout, Data())
        let failure = try jsonError(invalid.stderr)
        XCTAssertEqual(failure["code"] as? String, "invalid_usage")

        for (command, code) in [("fail", 7), ("signal", 143), ("misleading", 1), ("hang", 124)] {
            let result = try runCLI(home, ["exec", "demo", "--verbose", "--timeout", "1", "--", command])
            XCTAssertEqual(result.status, Int32(code), result.errorText)
            if command == "misleading" {
                XCTAssertTrue(result.errorText.contains("lookup timed out"))
            } else if command == "hang" {
                XCTAssertTrue(result.errorText.contains("--timeout"))
            } else {
                XCTAssertEqual(result.stdout, ErrorTestBackend.stdout)
                XCTAssertEqual(result.stderr, ErrorTestBackend.stderr)
            }
        }
        let credentials = try runCLI(home, ["exec", "demo", "--verbose", "--env", "TOKEN=selected-secret", "--", "credentials"])
        XCTAssertEqual(credentials.status, 1)
        XCTAssertFalse(credentials.errorText.contains("selected-secret"))
        XCTAssertFalse(credentials.errorText.contains("user:pass"))
        XCTAssertTrue(credentials.errorText.contains("code=operation_failed"))
        // Retained patches are content, even when they contain terminal controls and non-UTF-8 bytes.
        let directory = home.appendingPathComponent("tasks/task-old")
        let result = directory.appendingPathComponent("result")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        let patch = Data([0, 255, 27, 10, 65, 13, 10])
        try patch.write(to: result.appendingPathComponent("changes.patch"))
        let record = TaskRecord(
            id: "task-old", name: "old", phase: "completed", runtimeDigest: "digest", createdAtUnix: unixNow(),
            expiresAtUnix: unixNow() + 86400, resultDirectory: result.path, network: .none)
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("task.json"))
        let diff = try runCLI(home, ["diff", "old", "--verbose"])
        XCTAssertEqual(diff.status, 0)
        XCTAssertEqual(diff.stdout, patch)
        XCTAssertEqual(diff.stderr, Data())
    }

    func testUnavailableDaemonAndJSONStderr() throws {
        let home = URL(fileURLWithPath: "/tmp/dynocap-unavailable-\(UUID().uuidString)")
        try DynoCapPaths(home: home).ensure()
        defer { try? FileManager.default.removeItem(at: home) }
        // Hold the daemon's lock without a listener: an auto-start cannot acquire this home.
        let lock = try POSIX.openLock(home.appendingPathComponent("daemon.lock").path)
        defer { POSIX.unlock(lock); _ = closeFD(lock) }
        XCTAssertThrowsError(try DaemonClient(socketPath: home.appendingPathComponent("daemon.sock").path).ping()) { error in
            XCTAssertEqual((error as? DynoCapError)?.code, .daemonUnavailable)
        }
        let result = try runCLI(home, ["ls", "--json", "--verbose"])
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.stdout, Data())
        let failure = try jsonError(result.stderr)
        XCTAssertEqual(failure["code"] as? String, "daemon_unavailable")
        XCTAssertTrue((failure["recovery"] as? String)?.contains("daemon.log") == true)
    }

    private func jsonError(_ data: Data) throws -> [String: Any] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["error"] as? [String: Any])
    }

    private func runCLI(_ home: URL, _ args: [String]) throws -> ErrorProcessResult {
        let binary = ProcessInfo.processInfo.environment["DYNOCAP_BIN"] ?? ".build/debug/dynocap"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--home", home.path] + args
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let finished = expectation(description: "CLI completes")
        process.terminationHandler = { _ in finished.fulfill() }
        try process.run()
        wait(for: [finished], timeout: 8)
        if process.isRunning { process.terminate(); XCTFail("CLI hung") }
        return ErrorProcessResult(
            status: process.terminationStatus, stdout: stdout.fileHandleForReading.readDataToEndOfFile(),
            stderr: stderr.fileHandleForReading.readDataToEndOfFile())
    }
}

private struct ErrorProcessResult {
    var status: Int32
    var stdout: Data
    var stderr: Data
    var errorText: String { String(data: stderr, encoding: .utf8) ?? "" }
}

private final class ErrorTestBackend: VMBackend {
    var onGuestExit: ((String, UUID, String?) -> Void)?
    static let stdout = Data([65, 0, 255, 27, 10])
    static let stderr = Data([66, 13, 10, 254])

    func boot(_ request: BootRequest, completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
    func destroy(name: String, completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
    func cancelExec(name: String, id: UInt32) {}
    func exec(_ request: ExecRequest, emit: @escaping (ExecEvent) -> Void) {
        switch request.argv.first {
        case "hang": return
        case "misleading": emit(.failed("lookup timed out while reading configuration"))
        case "credentials": emit(.failed("https://user:pass@example.com \(request.env.joined(separator: " "))"))
        default:
            emit(.stdout(Self.stdout))
            emit(.stderr(Self.stderr))
            emit(.finished(code: 7, signal: request.argv.first == "signal" ? 15 : 0))
        }
    }
}
