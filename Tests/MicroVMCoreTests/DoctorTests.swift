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
        XCTAssertEqual(report.checks.last?.status, "warning")
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
        XCTAssertEqual(fresh.checks.first { $0.id == "home" }?.status, "warning")
        XCTAssertEqual(fresh.checks.first { $0.id == "daemon" }?.status, "warning")
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
        XCTAssertEqual(probeDoctorDaemon(paths).status, "warning")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        try paths.ensure()
        let lock = try POSIX.openLock(paths.lock.path)
        XCTAssertEqual(probeDoctorDaemon(paths).status, "error")
        POSIX.unlock(lock)
        _ = closeFD(lock)
        XCTAssertEqual(probeDoctorDaemon(paths).status, "warning")
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
                XCTAssertEqual(checks.first { $0["id"] as? String == "daemon" }?["status"] as? String, "warning")
            } else {
                XCTAssertTrue(result.stdout.contains("WARNING daemon"))
                XCTAssertTrue(result.stdout.contains("fetch-image.sh"))
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
        try JSONEncoder().encode(["aarch64/node@24": digest]).write(to: paths.home.appendingPathComponent("runtime-catalog.json"))
    }
}
