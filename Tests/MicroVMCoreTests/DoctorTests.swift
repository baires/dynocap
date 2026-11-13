import XCTest
@testable import MicroVMCore

final class DoctorTests: XCTestCase {
    func testCompleteSetupAndIndependentFailures() throws {
        for failure in ["none", "platform", "backend", "signing", "microvm-workspace", "microvm-mkruntime", "images", "runtime", "daemon"] {
            let fixture = try DoctorFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            var host = fixture.host
            var daemon = DoctorCheck("daemon", "ok", "fixture daemon")
            switch failure {
            case "platform": host.platformSupported = false
            case "backend": host.backend = DoctorCheck("backend", "error", "unsupported", recovery: "Use a supported Mac.")
            case "signing": host.signing = DoctorCheck("signing", "error", "unsigned", recovery: "Build and sign.")
            case "microvm-workspace", "microvm-mkruntime":
                try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(failure))
            case "images": try Data("corrupted".utf8).write(to: fixture.paths.kernel("aarch64"))
            case "runtime": try Data("corrupted".utf8).write(to: fixture.runtime.appendingPathComponent("runtime.ext4"))
            case "daemon": daemon = DoctorCheck("daemon", "error", "unreachable", recovery: "Check the socket.")
            default: break
            }
            let before = try snapshot(fixture.root)
            let report = diagnoseHost(paths: fixture.paths, executable: fixture.binary, runtimes: RuntimeArtifact.defaultRuntimes,
                                      host: host, daemon: { _ in daemon })
            XCTAssertEqual(report.ok, failure == "none", failure)
            XCTAssertEqual(report.checks.filter { $0.status == "error" }.map(\.id), failure == "none" ? [] : [failure])
            for check in report.checks where check.status == "error" { XCTAssertNotNil(check.recovery) }
            XCTAssertEqual(try snapshot(fixture.root), before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("companion-was-executed").path))
            if failure == "none" {
                let json = try object(formatDoctorReport(report, output: .json))
                XCTAssertEqual(json["ok"] as? Bool, true)
                XCTAssertEqual(Set(json.keys), ["ok", "home", "arch", "runtimes", "checks"])
                let checks = try XCTUnwrap(json["checks"] as? [[String: Any]])
                XCTAssertEqual(checks.count, 9)
                XCTAssertTrue(checks[0]["recovery"] is NSNull)
                XCTAssertTrue(checks[0]["fix"] is NSNull)
            }
        }
    }

    func testStoppedDaemonDoesNotFailOtherwiseCompleteSetup() throws {
        let fixture = try DoctorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let before = try snapshot(fixture.root)
        let report = diagnoseHost(paths: fixture.paths, executable: fixture.binary, runtimes: RuntimeArtifact.defaultRuntimes,
                                  host: fixture.host)
        XCTAssertTrue(report.ok)
        XCTAssertEqual(report.checks.last?.status, "ok")
        XCTAssertEqual(report.checks.last?.message, "Daemon is stopped; commands start it when they need it.")
        XCTAssertEqual(try snapshot(fixture.root), before)
    }

    func testRequestedRuntimeAndMissingHomeDoNotRepairAnything() throws {
        let fixture = try DoctorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let before = try snapshot(fixture.root)
        // The fixture prepares only the default node:24, so node:22 is a requested but unprepared runtime.
        let request = [RuntimeSelection(name: "node", version: "22")]
        let report = diagnoseHost(paths: fixture.paths, executable: fixture.binary, runtimes: request,
                                  host: fixture.host, daemon: { _ in DoctorCheck("daemon", "warning", "stopped") })
        XCTAssertFalse(report.ok)
        let check = try XCTUnwrap(report.checks.first { $0.id == "runtime" })
        XCTAssertEqual(check.status, "error")
        XCTAssertTrue(check.recovery?.contains("node:22") == true)
        XCTAssertEqual(try snapshot(fixture.root), before)
        let missing = fixture.root.appendingPathComponent("absent/nested/home")
        let fresh = diagnoseHost(paths: MicroVMPaths(home: missing), executable: fixture.binary, runtimes: request,
                                 host: fixture.host)
        XCTAssertFalse(fresh.ok)
        XCTAssertEqual(fresh.checks.first { $0.id == "home" }?.status, "ok")
        XCTAssertEqual(fresh.checks.first { $0.id == "daemon" }?.status, "ok")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let notDirectory = fixture.root.appendingPathComponent("home-file")
        try Data("unchanged".utf8).write(to: notDirectory)
        let blocked = diagnoseHost(paths: MicroVMPaths(home: notDirectory), executable: fixture.binary, runtimes: request,
                                   host: fixture.host)
        XCTAssertEqual(blocked.checks.first { $0.id == "home" }?.status, "error")
        XCTAssertEqual(try Data(contentsOf: notDirectory), Data("unchanged".utf8))
    }

    func testDaemonStoppedHeldLockStaleSocketAndHealthyListener() throws {
        let root = URL(fileURLWithPath: "/tmp/microvm-doctor-daemon-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = MicroVMPaths(home: root)
        XCTAssertEqual(probeDoctorDaemon(paths).status, "ok")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        try paths.ensure()
        let lock = try POSIX.openLock(paths.lock.path)
        XCTAssertEqual(probeDoctorDaemon(paths).status, "error")
        POSIX.unlock(lock)
        _ = closeFD(lock)
        XCTAssertEqual(probeDoctorDaemon(paths).status, "ok")
        try Data("stale listener".utf8).write(to: paths.socket)
        XCTAssertEqual(probeDoctorDaemon(paths).status, "error")
        try FileManager.default.removeItem(at: paths.socket)
        let daemon = Daemon(home: root, backend: UnsupportedBackend())
        try daemon.start()
        defer { daemon.stop() }
        XCTAssertEqual(probeDoctorDaemon(paths).status, "ok")
    }

    func testSilentAndIncompatibleListenersHaveBoundedFailures() throws {
        for silent in [true, false] {
            let root = URL(fileURLWithPath: "/tmp/microvm-doctor-probe-\(UUID().uuidString)")
            try MicroVMPaths(home: root).ensure()
            let paths = MicroVMPaths(home: root)
            let listener = try POSIX.listenUnix(paths.socket.path)
            let release = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                defer { finished.signal() }
                let client = POSIX.accept(listener)
                guard client >= 0 else { return }
                defer { _ = closeFD(client) }
                _ = try? ControlCodec.read(client)
                if silent {
                    _ = release.wait(timeout: .now() + 5)
                } else {
                    let legacy = Data(#"{"ok":true,"isolationPolicyVersion":1,"taskVersion":1,"taskManagementVersion":1}"#.utf8)
                    try? ControlCodec.write(client, .result(legacy))
                }
            }
            let start = ProcessInfo.processInfo.systemUptime
            let check = probeDoctorDaemon(paths)
            XCTAssertEqual(check.status, "error")
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 4)
            if !silent { XCTAssertTrue(check.recovery?.contains("restart") == true) }
            release.signal()
            XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
            _ = closeFD(listener)
            try FileManager.default.removeItem(at: root)
        }
    }

    func testDoctorProcessReportsFindingsWithoutCreatingHome() throws {
        let home = URL(fileURLWithPath: "/tmp/microvm-doctor-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        for json in [false, true] {
            let result = try runCLI(["--home", home.path, "doctor"] + (json ? ["--json"] : []))
            XCTAssertEqual(result.status, 1) // Missing image/runtime are independent of this machine's backend/signature.
            XCTAssertEqual(result.stderr, "")
            if json {
                let report = try object(result.stdout)
                XCTAssertEqual(report["ok"] as? Bool, false)
                let checks = try XCTUnwrap(report["checks"] as? [[String: Any]])
                XCTAssertEqual(checks.first { $0["id"] as? String == "daemon" }?["status"] as? String, "ok")
                // The test runs in the microvm checkout, which is not a project, so no runtime is required.
                XCTAssertEqual(checks.first { $0["id"] as? String == "runtime" }?["status"] as? String, "warning")
            } else {
                XCTAssertTrue(result.stdout.contains("WARNING runtime            No runtime is prepared yet"), result.stdout)
                XCTAssertTrue(result.stdout.contains("Run microvm doctor --fix --home \(home.path)"), result.stdout)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
        }
        let help = try runCLI(["--home", home.path, "doctor", "--help"])
        XCTAssertEqual(help.status, 0)
        let invalid = try runCLI(["--home", home.path, "doctor", "extra", "--json"])
        XCTAssertEqual(invalid.status, 2)
        XCTAssertEqual(invalid.stdout, "")
        XCTAssertNotNil(try object(invalid.stderr)["error"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
    }

    func testFixableChecksNameTheFixCommandOnlyWhenTheFixCanRun() throws {
        let fixture = try DoctorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("corrupted".utf8).write(to: fixture.paths.kernel("aarch64"))
        try Data("corrupted".utf8).write(to: fixture.runtime.appendingPathComponent("runtime.ext4"))
        let broken = DoctorCheck("daemon", "error", "outdated", recovery: "Restart it.")
        let command = "microvm doctor --fix --home /tmp/x"
        let fixable = diagnoseHost(paths: fixture.paths, executable: fixture.binary, runtimes: RuntimeArtifact.defaultRuntimes,
                                   host: fixture.host, source: fixture.root, fixCommand: command, daemon: { _ in broken })
        XCTAssertEqual(fixable.fixes, [.restartDaemon, .buildImages, .prepareRuntime])
        for check in fixable.checks where check.fix != nil { XCTAssertTrue(check.recovery?.hasPrefix("Run \(command) ") == true, check.id) }
        let text = try formatDoctorReport(fixable, output: .human)
        XCTAssertTrue(text.hasSuffix("3 required checks failed. Run \(command) to repair them.\n"), text)
        XCTAssertTrue(try XCTUnwrap(fixable.checks.first { $0.id == "runtime" }).message.contains("damaged or outdated"))

        // Without the checkout, image and runtime builds cannot run, so only the daemon stays fixable.
        let sourceless = diagnoseHost(paths: fixture.paths, executable: fixture.binary, runtimes: RuntimeArtifact.defaultRuntimes,
                                      host: fixture.host, fixCommand: command, daemon: { _ in broken })
        XCTAssertEqual(sourceless.fixes, [.restartDaemon])
        XCTAssertTrue(sourceless.checks.first { $0.id == "images" }?.recovery?.contains("from inside the microvm source checkout") == true)
        XCTAssertTrue(try formatDoctorReport(sourceless, output: .human).contains("repairs 1 of them; follow Next for the rest."))

        // A restart would stop live sandboxes, so --fix leaves the daemon alone and says why.
        try StateStore(paths: fixture.paths).save(VMRecord(name: "busy", phase: .running, cpus: 1, memoryMB: 512, daemonToken: "t", createdAtUnix: 0,
                                                            ttlSeconds: nil, message: nil))
        let busy = diagnoseHost(paths: fixture.paths, executable: fixture.binary, runtimes: RuntimeArtifact.defaultRuntimes,
                                host: fixture.host, source: fixture.root, fixCommand: command, daemon: { _ in broken })
        let daemon = try XCTUnwrap(busy.checks.first { $0.id == "daemon" })
        XCTAssertNil(daemon.fix)
        XCTAssertTrue(daemon.recovery?.contains("would stop sandbox busy") == true, daemon.recovery ?? "")

        // Runtime verification boots a guest, so an unsigned CLI blocks that fix instead of failing it later.
        var unsigned = fixture.host
        unsigned.signing = DoctorCheck("signing", "error", "unsigned", recovery: "Build and sign.")
        let blocked = diagnoseHost(paths: fixture.paths, executable: fixture.binary, runtimes: RuntimeArtifact.defaultRuntimes,
                                   host: unsigned, source: fixture.root, fixCommand: command, daemon: { _ in broken })
        let runtime = try XCTUnwrap(blocked.checks.first { $0.id == "runtime" })
        XCTAssertNil(runtime.fix)
        XCTAssertEqual(runtime.recovery, "Fix signing first, then run \(command) to prepare this runtime.")
    }

    func testDaemonOlderThanTheBinaryIsRestartable() throws {
        let fixture = try DoctorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("cli".utf8).write(to: fixture.binary)
        let healthy = DoctorCheck("daemon", "ok", "fixture daemon")
        let store = StateStore(paths: fixture.paths)
        try store.writeIdentity(DaemonIdentity(token: "t", pid: 1, startedAtUnix: unixNow() + 60))
        let current = diagnoseHost(paths: fixture.paths, executable: fixture.binary, runtimes: RuntimeArtifact.defaultRuntimes,
                                   host: fixture.host, daemon: { _ in healthy })
        XCTAssertTrue(current.ok)
        try store.writeIdentity(DaemonIdentity(token: "t", pid: 1, startedAtUnix: unixNow() - 60))
        let stale = diagnoseHost(paths: fixture.paths, executable: fixture.binary, runtimes: RuntimeArtifact.defaultRuntimes,
                                 host: fixture.host, daemon: { _ in healthy })
        let daemon = try XCTUnwrap(stale.checks.first { $0.id == "daemon" })
        XCTAssertEqual(daemon.status, "error")
        XCTAssertEqual(daemon.fix, .restartDaemon)
    }

    func testProjectFilesChooseTheRuntime() throws {
        let root = URL(fileURLWithPath: "/tmp/microvm-project-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertNil(ProjectRuntime.detect(root))
        try Data().write(to: root.appendingPathComponent("go.mod"))
        XCTAssertEqual(ProjectRuntime.detect(root), ProjectRuntime(runtime: RuntimeSelection(name: "go", version: "1.27"), marker: "go.mod"))
        try Data().write(to: root.appendingPathComponent("requirements.txt"))
        XCTAssertEqual(ProjectRuntime.detect(root)?.runtime, RuntimeSelection(name: "python", version: "3.14"))
        try Data().write(to: root.appendingPathComponent("package.json"))
        let node = try XCTUnwrap(ProjectRuntime.detect(root))
        XCTAssertEqual(node.runtime, RuntimeSelection(name: "node", version: "24"))
        XCTAssertEqual(node.note, "Using runtime node:24 (detected from package.json); choose another with --runtime.")
        XCTAssertEqual(ProjectRuntime.choose(projectPath: root.path).runtime, RuntimeSelection(name: "node", version: "24"))
        let fallback = ProjectRuntime.choose(projectPath: nil)
        XCTAssertEqual(fallback.runtime, RuntimeSelection(name: "shell", version: "1"), "URLs and marker-less projects get bash")
        XCTAssertNil(fallback.marker)
        XCTAssertEqual(ProjectRuntime.choose(projectPath: "/").runtime, fallback.runtime)
        XCTAssertTrue(fallback.note.hasPrefix("Using runtime shell:1 (bash, git and ssh;"))
        for (_, runtime) in ProjectRuntime.markers {
            XCTAssertTrue(RuntimeArtifact.supportedSelections.contains(runtime.name + ":" + runtime.version))
        }
    }

    func testSupportedSelectionsMatchTheGoCatalog() throws {
        let catalog = try String(contentsOfFile: "guest/internal/runtime/catalog.go", encoding: .utf8)
        for selection in RuntimeArtifact.supportedSelections {
            let parts = selection.split(separator: ":")
            XCTAssertTrue(catalog.contains("\"\(parts[0])\":") && catalog.contains("\"\(parts[1])\":"), selection)
        }
        XCTAssertEqual(catalog.components(separatedBy: "Recipe(").count - 1 + (catalog.contains("shellRecipe}") ? 1 : 0),
                       RuntimeArtifact.supportedSelections.count)
    }

    func testWithoutAProjectNoRuntimeIsRequired() throws {
        let fixture = try DoctorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let prepared = diagnoseHost(paths: fixture.paths, executable: fixture.binary, runtimes: [], host: fixture.host)
        XCTAssertTrue(prepared.ok)
        XCTAssertEqual(prepared.checks.first { $0.id == "runtime" }?.message, "Prepared runtimes: shell:1.")
        try FileManager.default.removeItem(at: fixture.paths.home.appendingPathComponent("runtime-catalog.json"))
        let none = diagnoseHost(paths: fixture.paths, executable: fixture.binary, runtimes: [], host: fixture.host, source: fixture.root)
        XCTAssertTrue(none.ok, "raw sandboxes need no runtime")
        let runtime = try XCTUnwrap(none.checks.first { $0.id == "runtime" })
        XCTAssertEqual(runtime.status, "warning")
        XCTAssertNil(runtime.fix)
        XCTAssertTrue(runtime.recovery?.contains("python:3.14") == true)

        let python = [RuntimeSelection(name: "python", version: "3.14")]
        let detected = diagnoseHost(paths: fixture.paths, executable: fixture.binary, runtimes: python, host: fixture.host,
                                    source: fixture.root, runtimeOrigin: "pyproject.toml")
        let missing = try XCTUnwrap(detected.checks.first { $0.id == "runtime" })
        XCTAssertEqual(missing.message, "Runtime python:3.14 is not prepared for aarch64 yet. This project's pyproject.toml needs it.")
        XCTAssertEqual(missing.fix, .prepareRuntime)

        let unknown = diagnoseHost(paths: fixture.paths, executable: fixture.binary, runtimes: [RuntimeSelection(name: "node", version: "20")],
                                   host: fixture.host, source: fixture.root)
        let unsupported = try XCTUnwrap(unknown.checks.first { $0.id == "runtime" })
        XCTAssertEqual(unsupported.message, "Runtime node:20 is not supported.")
        XCTAssertNil(unsupported.fix)
    }

    func testFixCommandKeepsOnlyNonDefaultFlags() {
        XCTAssertEqual(doctorFixCommand(home: nil, runtimes: nil), "microvm doctor --fix")
        XCTAssertEqual(doctorFixCommand(home: URL(fileURLWithPath: "/tmp/a b"), runtimes: [RuntimeSelection(name: "python", version: "3.14")]),
                       "microvm doctor --fix --home '/tmp/a b' --runtime python:3.14")
        XCTAssertEqual(doctorFixCommand(home: nil, runtimes: nil, project: "./project"), "microvm doctor --fix ./project")
    }

    func testDoctorFixParses() throws {
        XCTAssertEqual(try parseCommand(["microvm", "doctor", "--fix"]).command, .doctor(DoctorRequest(fix: true)))
        XCTAssertEqual(try parseCommand(["microvm", "doctor"]).command, .doctor(DoctorRequest()))
        XCTAssertEqual(try parseCommand(["microvm", "doctor", "/tmp", "--runtime", "go:1.27"]).command,
                       .doctor(DoctorRequest(runtimes: [RuntimeSelection(name: "go", version: "1.27")], project: "/tmp")))
        XCTAssertThrowsError(try DoctorRequest(project: "/tmp/microvm-no-such-project").validate())
        XCTAssertNoThrow(try DoctorRequest(project: "/tmp").validate())
        XCTAssertThrowsError(try parseCommand(["microvm", "doctor", "--fix=yes"]))
        XCTAssertThrowsError(try parseCommand(["microvm", "doctor", "/tmp", "/"]))
    }

    func testRepairsRunInOrderAndSkipRuntimeAfterDaemonFailure() throws {
        var report = DoctorReport(home: "/h", arch: "aarch64", runtimes: RuntimeArtifact.defaultRuntimes, checks: [
            DoctorCheck("runtime", "error", "r", fix: .prepareRuntime), DoctorCheck("images", "error", "i", fix: .buildImages),
            DoctorCheck("daemon", "error", "d", fix: .restartDaemon),
        ])
        var performed: [DoctorFix] = []
        let log = URL(fileURLWithPath: "/h/image.log")
        let repairs = repairHost(report, progress: { _, _ in }, perform: { fix in
            performed.append(fix)
            if fix == .restartDaemon { throw MicroVMError("lock stuck", recovery: "kill 1") }
            return DoctorRepairOutput(log: log, note: "moved")
        })
        XCTAssertEqual(performed, [.restartDaemon, .buildImages])
        XCTAssertEqual(repairs.map(\.status), ["failed", "fixed", "skipped"])
        XCTAssertEqual(repairs[0].recovery, "kill 1")
        XCTAssertEqual(repairs[1].logPath, log.path)
        report.repairs = repairs
        let text = try formatDoctorReport(report, output: .human)
        XCTAssertTrue(text.contains("FAILED  Restarting the daemon with this microvm build: lock stuck\n        Next: kill 1"), text)
        XCTAssertTrue(text.contains("Note: moved"))
        let json = try object(formatDoctorReport(report, output: .json))
        XCTAssertEqual((json["repairs"] as? [[String: Any]])?.map { $0["fix"] as? String }, ["restart-daemon", "build-images", "prepare-runtime"])
    }

    func testImageBuildMovesMismatchedFilesAsideInsteadOfDeletingThem() throws {
        let fixture = try DoctorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("guest"), withIntermediateDirectories: true)
        try Data("hand-built".utf8).write(to: fixture.paths.kernel("aarch64"))
        let go = fixture.root.appendingPathComponent("go")
        try Data("#!/bin/sh\nexit 3\n".utf8).write(to: go)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: go.path)
        XCTAssertThrowsError(try buildGuestImage(paths: fixture.paths, arch: "aarch64", source: source, go: go)) { error in
            let failure = error as? DoctorRepairFailure
            XCTAssertTrue(failure?.error.recovery.contains("moved to") == true, failure?.error.recovery ?? "")
        }
        let images = fixture.paths.imageDir("aarch64")
        let backups = try FileManager.default.contentsOfDirectory(atPath: images.path).filter { $0.hasPrefix("replaced-") }
        XCTAssertEqual(backups.count, 1)
        let kept = images.appendingPathComponent(backups[0]).appendingPathComponent("kernel")
        XCTAssertEqual(try Data(contentsOf: kept), Data("hand-built".utf8))
    }

    func testSourceIsFoundFromTheBuildProductOrWorkingDirectory() throws {
        let root = URL(fileURLWithPath: "/tmp/microvm-source-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let product = root.appendingPathComponent(".build/out/Products/Release")
        try FileManager.default.createDirectory(at: product, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("guest/mkimage"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("guest/mkimage/main.go"))
        try Data().write(to: root.appendingPathComponent("Package.swift"))
        let elsewhere = URL(fileURLWithPath: "/")
        XCTAssertEqual(locateMicroVMSource(executable: product.appendingPathComponent("microvm"), currentDirectory: elsewhere)?.path, root.path)
        XCTAssertEqual(locateMicroVMSource(executable: URL(fileURLWithPath: "/usr/bin/microvm"), currentDirectory: product)?.path, root.path)
        XCTAssertNil(locateMicroVMSource(executable: URL(fileURLWithPath: "/usr/bin/microvm"), currentDirectory: elsewhere))
    }

    private func object(_ string: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }

    private func snapshot(_ root: URL) throws -> [String: Data] {
        var values: [String: Data] = [:]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        while let file = enumerator.nextObject() as? URL {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { values[file.path] = try Data(contentsOf: file) }
        }
        return values
    }

    private func runCLI(_ args: [String]) throws -> DoctorProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MICROVM_BIN"] ?? ".build/debug/microvm")
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let finished = expectation(description: "doctor finishes")
        process.terminationHandler = { _ in finished.fulfill() }
        try process.run()
        wait(for: [finished], timeout: 5)
        if process.isRunning { process.terminate(); XCTFail("doctor hung") }
        return DoctorProcessResult(status: process.terminationStatus,
                                   stdout: String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                                   stderr: String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }
}

private struct DoctorProcessResult {
    var status: Int32
    var stdout: String
    var stderr: String
}

private struct DoctorFixture {
    let root = URL(fileURLWithPath: "/tmp/microvm-doctor-\(UUID().uuidString)")
    var binary: URL { root.appendingPathComponent("microvm") }
    var paths: MicroVMPaths { MicroVMPaths(home: root.appendingPathComponent("home")) }
    let runtime: URL
    var host: DoctorHost {
        DoctorHost(arch: "aarch64", platformSupported: true, backend: DoctorCheck("backend", "ok", "supported"),
                   signing: DoctorCheck("signing", "ok", "signed"))
    }

    init() throws {
        let digest = try dataDigest(Data("disk".utf8))
        runtime = root.appendingPathComponent("home/runtimes").appendingPathComponent(digest)
        try paths.ensure()
        for name in ["microvm-workspace", "microvm-mkruntime"] {
            let file = root.appendingPathComponent(name)
            try Data("#!/bin/sh\ntouch '\(root.path)/companion-was-executed'\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let images = paths.imageDir("aarch64")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try Data("kernel".utf8).write(to: paths.kernel("aarch64"))
        try Data("initrd".utf8).write(to: paths.initrd("aarch64"))
        let manifest: [String: Any] = ["arch": "aarch64", "guestPort": 5252,
                                       "kernelSHA256": try dataDigest(Data("kernel".utf8)), "initrdSHA256": try dataDigest(Data("initrd".utf8))]
        try JSONSerialization.data(withJSONObject: manifest).write(to: images.appendingPathComponent("manifest.json"))
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        for name in ["kernel", "initrd"] { try Data("image".utf8).write(to: runtime.appendingPathComponent(name)) }
        try Data("disk".utf8).write(to: runtime.appendingPathComponent("runtime.ext4"))
        let artifact = RuntimeArtifact(
            runtimes: RuntimeArtifact.defaultRuntimes, arch: "aarch64", baseImageDigest: "base", artifactDigest: digest,
            tools: [:], environment: [:], formatVersion: RuntimeArtifact.currentFormatVersion, verificationCommand: ["true"])
        try JSONEncoder().encode(artifact).write(to: runtime.appendingPathComponent("runtime.json"))
        let key = RuntimeArtifact.selectionKey(RuntimeArtifact.defaultRuntimes, arch: "aarch64")
        try JSONEncoder().encode([key: digest]).write(to: paths.home.appendingPathComponent("runtime-catalog.json"))
    }
}
