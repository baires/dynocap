import XCTest
@testable import MicroVMCore

final class CLICreationTests: XCTestCase {
    func testCreationRenderersUseActualDeadlineAndExplicitNulls() throws {
        let now: Int64 = 1_794_352_000
        let home = URL(fileURLWithPath: "/tmp/home with 'quote")
        let record = TaskRecord(
            id: "task-demo", name: "demo", runtimes: RuntimeArtifact.defaultRuntimes, phase: "running", runtimeDigest: "digest",
            createdAtUnix: now - 20, expiresAtUnix: now + 604780, network: .none)
        let sandbox = VMRecord(
            name: record.id, phase: .running, cpus: 2, memoryMB: 2048, daemonToken: "private", createdAtUnix: now - 10,
            ttlSeconds: 60, message: nil)
        let descriptor = TaskDescriptor(record, sandbox: sandbox)
        var command = TaskCommand(op: "start")
        command.projectPath = "/tmp/project"
        let human = try formatCreationResult(descriptor, command: command, home: home, output: .human, now: now)
        for expected in ["Created sandbox: demo", "Phase: running", "node:24", "Network: none", "TTL: 50s remaining",
                         "discards unexported", "Source (directory): /tmp/project", "exec demo -- pwd", "'\\''"] {
            XCTAssertTrue(human.contains(expected), expected)
        }
        let json = try object(formatCreationResult(descriptor, command: command, home: home, output: .json, now: now))
        XCTAssertEqual(json["sandboxExpiresAtUnix"] as? Int64, now + 50)
        XCTAssertEqual(json["resultExpiresAtUnix"] as? Int64, record.expiresAtUnix)
        XCTAssertNil(json["runtimeDigest"])
        XCTAssertNil(json["timingsMS"])
        let source = try XCTUnwrap(json["source"] as? [String: Any])
        XCTAssertTrue(source["revision"] is NSNull)
        XCTAssertEqual(json["onSandboxExpiration"] as? String, "discard_unexported_work")
        var unnamed = record
        unnamed.name = nil
        let legacy = try object(formatCreationResult(TaskDescriptor(unnamed), command: command, home: home, output: .json, now: now))
        XCTAssertTrue(legacy["name"] is NSNull)
        XCTAssertTrue(legacy["sandboxExpiresAtUnix"] is NSNull)
        XCTAssertTrue((legacy["nextCommand"] as? String)?.contains("exec task-demo") == true)
    }

    func testMissingRuntimeDoesNotAllocateOrSubstitute() throws {
        let root = URL(fileURLWithPath: "/tmp/microvm-missing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = MicroVMPaths(home: root)
        try paths.ensure()
        let manager = TaskManager(
            paths: paths, arch: "aarch64", boot: { _ in XCTFail("must not boot"); throw MicroVMError("boot") },
            execute: { _, _, _, _, _, _ in XCTFail("must not execute"); throw MicroVMError("exec") }, destroy: { _ in },
            hostTree: { _, _, _, _ in XCTFail("must not prepare or import"); return Data() })
        try manager.recover()
        var command = TaskCommand(op: "start")
        command.projectPath = root.path
        command.runtimes = [RuntimeSelection(name: "node", version: "24")]
        XCTAssertThrowsError(try manager.start(command)) { error in
            let failure = error as? MicroVMError
            XCTAssertTrue(failure?.recovery.contains("runtime prepare") == true)
            XCTAssertTrue(failure?.recovery.contains("node:24") == true)
            XCTAssertFalse(failure?.recovery.contains("node:22") == true)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("tasks").path), [])
        command.projectPath = nil
        command.repositoryUrl = "https://example.com/repo.git"
        XCTAssertThrowsError(try manager.start(command)) { error in
            XCTAssertTrue(String(describing: error).contains("--network"))
        }
    }

    func testCreationStagesAndSuccessfulTaskUseInjectedCompanions() throws {
        let root = URL(fileURLWithPath: "/tmp/microvm-stages-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = MicroVMPaths(home: root)
        try paths.ensure()
        let digest = try dataDigest(Data("runtime".utf8))
        let directory = root.appendingPathComponent("runtimes").appendingPathComponent(digest)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("runtime".utf8).write(to: directory.appendingPathComponent("runtime.ext4"))
        for name in ["kernel", "initrd"] { try Data("image".utf8).write(to: directory.appendingPathComponent(name)) }
        let manifest = RuntimeArtifact(
            runtimes: RuntimeArtifact.defaultRuntimes, arch: HostArch.guest, baseImageDigest: "base", artifactDigest: digest,
            tools: [:], environment: [:], formatVersion: RuntimeArtifact.currentFormatVersion, verificationCommand: ["true"])
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("runtime.json"))
        try JSONEncoder().encode([RuntimeArtifact.selectionKey(manifest.runtimes, arch: HostArch.guest): digest])
            .write(to: root.appendingPathComponent("runtime-catalog.json"))
        var stages: [CreationStage] = []
        let manager = TaskManager(
            paths: paths, arch: HostArch.guest, boot: { request in
                XCTAssertTrue(stages.contains(.booting))
                XCTAssertEqual(request.network, NetworkMode.none)
                return VMRecord(
                    name: request.name, phase: .running, cpus: 2, memoryMB: 2048, daemonToken: "test", createdAtUnix: unixNow(),
                    ttlSeconds: 120, message: nil, network: NetworkMode.none)
            }, execute: { _, _, _, _, _, _ in Data() }, destroy: { _ in },
            hostTree: { name, args, _, output in
                if let output { try Data().write(to: output) }
                if name == "microvm-workspace", args[0] == "unpack" {
                    try FileManager.default.createDirectory(atPath: args[1], withIntermediateDirectories: true)
                }
                if name == "microvm-mkruntime" { try Data().write(to: URL(fileURLWithPath: args[1])) }
                return Data("none".utf8)
            })
        try manager.recover()
        var command = TaskCommand(op: "start")
        command.projectPath = root.appendingPathComponent("project").path
        command.name = "demo"
        let record = try manager.start(command, progress: { stages.append($0) })
        XCTAssertEqual(record.phase, "running")
        XCTAssertEqual(record.sourcePath, command.projectPath)
        XCTAssertEqual(record.runtimes, RuntimeArtifact.defaultRuntimes)
        XCTAssertEqual(record.network, .none)
        XCTAssertEqual(stages.first, .checkingRuntime)
        XCTAssertTrue(stages.contains(.populatingWorkspace))
        XCTAssertFalse(stages.contains(.waitingForNetwork))
        XCTAssertLessThan(try XCTUnwrap(stages.firstIndex(of: .creatingWorkspace)), try XCTUnwrap(stages.firstIndex(of: .booting)))
    }

    func testVerifiedPreparationRepairsIncompletePublishedArtifact() throws {
        let root = URL(fileURLWithPath: "/tmp/microvm-repair-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = MicroVMPaths(home: root)
        try paths.ensure()
        let digest = try dataDigest(Data("runtime".utf8))
        let candidate = root.appendingPathComponent("runtime-candidate")
        let published = root.appendingPathComponent("runtimes").appendingPathComponent(digest)
        let manifest = RuntimeArtifact(
            runtimes: RuntimeArtifact.defaultRuntimes, arch: HostArch.guest, baseImageDigest: "base", artifactDigest: digest,
            tools: [:], environment: [:], formatVersion: RuntimeArtifact.currentFormatVersion, verificationCommand: ["true"])
        let manager = TaskManager(
            paths: paths, arch: HostArch.guest, boot: { request in
                VMRecord(name: request.name, phase: .running, cpus: 2, memoryMB: 2048, daemonToken: "test", createdAtUnix: unixNow(),
                         ttlSeconds: 120, message: nil)
            }, execute: { _, _, _, _, _, _ in Data() }, destroy: { _ in },
            hostTree: { _, args, _, _ in try Data().write(to: URL(fileURLWithPath: args[1])); return Data() })
        try manager.recover()
        for directory in [candidate, published] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("runtime".utf8).write(to: directory.appendingPathComponent("runtime.ext4"))
            try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("runtime.json"))
            for name in ["kernel", "initrd"] { try Data("image".utf8).write(to: directory.appendingPathComponent(name)) }
        }
        try FileManager.default.removeItem(at: published.appendingPathComponent("initrd"))
        XCTAssertThrowsError(try RuntimeArtifact.verifyFiles(manifest, directory: published))
        let verified = try manager.verifyRuntime(nil)
        XCTAssertEqual(verified.artifactDigest, digest)
        XCTAssertNoThrow(try RuntimeArtifact.verifyFiles(manifest, directory: published))
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
    }

    func testProcessCreationSourcesModesAndProgressIsolation() throws {
        let fixture = try CreationFixture()
        defer { fixture.stop() }
        let human = try runCLI(fixture, ["clone", "/tmp/local project", "demo"])
        XCTAssertEqual(human.status, 0, human.errorText)
        XCTAssertTrue(human.outputText.contains("Source (directory): /tmp/local project"))
        XCTAssertTrue(human.outputText.contains("TTL:"))
        XCTAssertTrue(human.errorText.contains("Booting the sandbox"))
        XCTAssertFalse(human.outputText.contains("Booting the sandbox"))
        XCTAssertFalse(human.errorText.contains("\u{1b}"))
        let json = try runCLI(fixture, ["--json", "clone", "https://example.com/repo.git", "demo", "--network", "nat"])
        XCTAssertEqual(json.status, 0, json.errorText)
        XCTAssertEqual(json.stderr, Data())
        let result = try object(json.outputText)
        XCTAssertEqual(result["network"] as? String, "nat")
        let source = try XCTUnwrap(result["source"] as? [String: Any])
        XCTAssertEqual(source["kind"] as? String, "repository")
        XCTAssertEqual(source["value"] as? String, "https://example.com/repo.git")
        XCTAssertEqual(source["revision"] as? String, String(repeating: "a", count: 40))
        let failed = try runCLI(fixture, ["clone", "https://example.com/repo.git", "demo", "--json"])
        XCTAssertEqual(failed.status, 1)
        XCTAssertEqual(failed.stdout, Data())
        XCTAssertTrue(failed.errorText.contains("--network"))
        XCTAssertNotNil(try object(failed.errorText)["error"])
    }

    func testProcessRuntimePreparationCapturesBothCompanionStreams() throws {
        let fixture = try CreationFixture()
        defer { fixture.stop() }
        let args = ["runtime", "prepare", fixture.root.path, "--runtime", "node:22"]
        for json in [false, true] {
            let result = try runCLI(fixture, args + (json ? ["--json"] : []))
            XCTAssertEqual(result.status, 0, result.errorText)
            XCTAssertFalse(result.outputText.contains("COMPANION"))
            XCTAssertFalse(result.errorText.contains("COMPANION"))
            if json {
                XCTAssertEqual(result.stderr, Data())
                let value = try object(result.outputText)
                XCTAssertEqual(value["verified"] as? Bool, true)
                XCTAssertEqual(value["artifactDigest"] as? String, String(repeating: "a", count: 64))
                let log = try XCTUnwrap(value["buildLogPath"] as? String)
                let text = try String(contentsOfFile: log, encoding: .utf8)
                XCTAssertTrue(text.contains("COMPANION_STDOUT"))
                XCTAssertTrue(text.contains("COMPANION_STDERR"))
            } else {
                XCTAssertTrue(result.outputText.contains("Runtime ready: node:22"))
                XCTAssertTrue(result.errorText.contains("Preparing the runtime"))
                XCTAssertTrue(result.errorText.contains("Verifying the prepared runtime"))
            }
        }
        let failed = try runCLI(fixture, args + ["--json"], status: "9")
        XCTAssertEqual(failed.status, 1)
        XCTAssertEqual(failed.stdout, Data())
        XCTAssertFalse(failed.errorText.contains("COMPANION"))
        XCTAssertNotNil(try object(failed.errorText)["error"])
        XCTAssertTrue(failed.errorText.contains("runtime-preparation-"))
        try FileManager.default.removeItem(at: fixture.companion)
        let missing = try runCLI(fixture, args + ["--json"])
        XCTAssertEqual(missing.status, 1)
        XCTAssertTrue(missing.errorText.contains("build-macos.sh"))
        XCTAssertEqual(missing.stdout, Data())
    }

    func testVerificationFailureHasNoSuccessOrCompanionOutput() throws {
        let fixture = try CreationFixture(failVerification: true)
        defer { fixture.stop() }
        let result = try runCLI(fixture, ["runtime", "prepare", fixture.root.path, "--json"])
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.stdout, Data())
        XCTAssertFalse(result.errorText.contains("COMPANION"))
        XCTAssertTrue(result.errorText.contains("verification rejected"))
        XCTAssertTrue(result.errorText.contains("Runtime build log:"))
        XCTAssertNotNil(try object(result.errorText)["error"])
    }

    private func object(_ string: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }

    func testTaskStartReportsCreationLikeClone() throws {
        let fixture = try CreationFixture()
        defer { fixture.stop() }
        func deadlineFree(_ text: String) -> [String] {
            text.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("TTL:") }
        }
        let clone = try runCLI(fixture, ["clone", "/tmp/local project", "demo", "--ttl", "600"])
        let start = try runCLI(fixture, ["task", "start", "/tmp/local project", "--name", "demo", "--ttl", "600"])
        XCTAssertEqual(start.status, 0, start.errorText)
        XCTAssertEqual(deadlineFree(start.outputText), deadlineFree(clone.outputText))
        XCTAssertEqual(start.errorText, clone.errorText, "the same progress lines on stderr")
        XCTAssertTrue(start.errorText.contains("Booting the sandbox"))

        let cloneJSON = try object(try runCLI(fixture, ["clone", "/tmp/local project", "demo", "--json"]).outputText)
        let startRun = try runCLI(fixture, ["task", "start", "/tmp/local project", "--name", "demo", "--json"])
        XCTAssertEqual(startRun.stderr, Data(), "JSON suppresses progress")
        var startJSON = try object(startRun.outputText)
        var expected = cloneJSON
        for key in ["sandboxExpiresAtUnix", "resultExpiresAtUnix"] {
            XCTAssertNotNil(startJSON.removeValue(forKey: key))
            XCTAssertNotNil(expected.removeValue(forKey: key))
        }
        XCTAssertEqual(NSDictionary(dictionary: startJSON), NSDictionary(dictionary: expected))
    }

    private func runCLI(_ fixture: CreationFixture, _ args: [String], status: String = "0") throws -> CreationProcessResult {
        let process = Process()
        process.executableURL = fixture.binary
        process.arguments = ["--home", fixture.home.path] + args
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        environment["MICROVM_TEST_PREP_STATUS"] = status
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let finished = expectation(description: "creation CLI finishes")
        process.terminationHandler = { _ in finished.fulfill() }
        try process.run()
        wait(for: [finished], timeout: 5)
        if process.isRunning { process.terminate(); XCTFail("CLI hung") }
        return CreationProcessResult(
            status: process.terminationStatus, stdout: output.fileHandleForReading.readDataToEndOfFile(),
            stderr: errors.fileHandleForReading.readDataToEndOfFile())
    }
}

private struct CreationProcessResult {
    var status: Int32
    var stdout: Data
    var stderr: Data
    var outputText: String { String(data: stdout, encoding: .utf8) ?? "" }
    var errorText: String { String(data: stderr, encoding: .utf8) ?? "" }
}

/// Process-boundary fixture: speaks only the management requests used in this ticket.
private final class CreationFixture {
    let root = URL(fileURLWithPath: "/tmp/microvm-creation-\(UUID().uuidString)")
    var home: URL { root.appendingPathComponent("home") }
    var binary: URL { root.appendingPathComponent("microvm") }
    var companion: URL { root.appendingPathComponent("microvm-mkruntime") }
    private let failVerification: Bool
    private var listener: Int32 = -1
    private let stopped = DispatchSemaphore(value: 0)

    init(failVerification: Bool = false) throws {
        self.failVerification = failVerification
        try MicroVMPaths(home: home).ensure()
        let executable = ProcessInfo.processInfo.environment["MICROVM_BIN"] ?? ".build/debug/microvm"
        try FileManager.default.copyItem(at: URL(fileURLWithPath: executable), to: binary)
        let script = "#!/bin/sh\nprintf '%s\\n' COMPANION_STDOUT\nprintf '%s\\n' COMPANION_STDERR >&2\nexit \"${MICROVM_TEST_PREP_STATUS:-0}\"\n"
        try Data(script.utf8).write(to: companion)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: companion.path)
        listener = try POSIX.listenUnix(home.appendingPathComponent("daemon.sock").path)
        let fd = listener
        Thread.detachNewThread { [self] in
            defer { stopped.signal() }
            while true {
                let client = POSIX.accept(fd)
                if client < 0 { return }
                defer { _ = closeFD(client) }
                do {
                    if try !respond(client) { return }
                } catch { try? ControlCodec.write(client, .error(daemonErrorText(error))) }
            }
        }
    }

    func stop() {
        // A shutdown request wakes accept without racing a reused descriptor.
        if let fd = try? POSIX.connectUnix(home.appendingPathComponent("daemon.sock").path) {
            try? ControlCodec.write(fd, .shutdown)
            _ = closeFD(fd)
        }
        _ = stopped.wait(timeout: .now() + 2)
        try? FileManager.default.removeItem(at: root)
    }

    private func respond(_ fd: Int32) throws -> Bool {
        switch try ControlCodec.read(fd) {
        case .shutdown:
            _ = closeFD(listener)
            return false
        case .ping:
            try ControlCodec.write(fd, .result(JSONEncoder().encode(PolicyCapabilities())))
        case .task(let command) where command.op == "start":
            _ = try TaskSourceResolver.resolve(command)
            if command.reportProgress == true {
                try ControlCodec.write(fd, .stderr(Data((CreationStage.booting.rawValue + "\n").utf8)))
            }
            let now = unixNow()
            let record = TaskRecord(
                id: "task-demo", name: command.name, runtimes: command.runtimes ?? RuntimeArtifact.defaultRuntimes,
                phase: "running", runtimeDigest: "private-digest", createdAtUnix: now, expiresAtUnix: now + 604800,
                sourceUrl: command.repositoryUrl, sourceRevision: command.repositoryUrl == nil ? nil : String(repeating: "a", count: 40),
                network: command.network ?? .none)
            let sandbox = VMRecord(
                name: record.id, phase: .running, cpus: 2, memoryMB: 2048, daemonToken: "secret", createdAtUnix: now - 10,
                ttlSeconds: command.ttlSeconds ?? 1800, message: nil)
            try ControlCodec.write(fd, .result(JSONEncoder().encode(TaskDescriptor(record, sandbox: sandbox))))
        case .task(let command) where command.op == "runtimeVerify":
            if failVerification { throw MicroVMError("verification rejected") }
            let artifact = RuntimeArtifact(
                runtimes: command.runtimes ?? RuntimeArtifact.defaultRuntimes, arch: HostArch.guest, baseImageDigest: "base",
                artifactDigest: String(repeating: "a", count: 64), tools: [:], environment: [:],
                formatVersion: RuntimeArtifact.currentFormatVersion, verificationCommand: ["true"])
            try ControlCodec.write(fd, .result(JSONEncoder().encode(artifact)))
        default: throw MicroVMError("unexpected fixture request")
        }
        return true
    }
}
