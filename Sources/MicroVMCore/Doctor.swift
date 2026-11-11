import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct DoctorCheck: Encodable {
    public var id: String
    public var status: String
    public var message: String
    public var recovery: String?

    public init(_ id: String, _ status: String, _ message: String, recovery: String? = nil) {
        self.id = id
        self.status = status
        self.message = message
        self.recovery = recovery
    }

    enum CodingKeys: String, CodingKey { case id, status, message, recovery }
    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(id, forKey: .id)
        try fields.encode(status, forKey: .status)
        try fields.encode(message, forKey: .message)
        try fields.encode(recovery, forKey: .recovery)
    }
}

public struct DoctorReport: Encodable {
    public var ok: Bool { !checks.contains { $0.status == "error" } }
    public var home: String
    public var arch: String
    public var runtimes: [RuntimeSelection]
    public var checks: [DoctorCheck]

    enum CodingKeys: String, CodingKey { case ok, home, arch, runtimes, checks }
    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(ok, forKey: .ok)
        try fields.encode(home, forKey: .home)
        try fields.encode(arch, forKey: .arch)
        try fields.encode(runtimes, forKey: .runtimes)
        try fields.encode(checks, forKey: .checks)
    }
}

public struct DoctorHost {
    public var arch: String
    public var platformSupported: Bool
    public var backend: DoctorCheck
    public var signing: DoctorCheck

    public init(arch: String, platformSupported: Bool, backend: DoctorCheck, signing: DoctorCheck) {
        self.arch = arch
        self.platformSupported = platformSupported
        self.backend = backend
        self.signing = signing
    }
}

/// Platform/backend facts are supplied by the executable's backend module, not guessed by the portable collector.
public func diagnoseHost(
    paths: MicroVMPaths, executable: URL, runtimes: [RuntimeSelection], host: DoctorHost,
    daemon: (MicroVMPaths) -> DoctorCheck = probeDoctorDaemon
) -> DoctorReport {
    let fm = FileManager.default
    let arch = host.arch
    let supported = host.platformSupported && ["aarch64", "x86_64"].contains(arch)
    var checks = [DoctorCheck(
        "platform", supported ? "ok" : "error",
        supported ? "macOS 13+; guest architecture \(arch)" : "Linux sandboxes require macOS 13+ with a supported host architecture.",
        recovery: supported ? nil : "Run the signed release CLI on a supported Mac.")]
    checks += [host.backend, host.signing]
    checks.append(doctorHomeAccess(paths.home))
    let companions = executable.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
    for name in ["microvm-workspace", "microvm-mkruntime"] {
        let file = companions.appendingPathComponent(name)
        let valid = fm.isExecutableFile(atPath: file.path) && (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        checks.append(DoctorCheck(
            name, valid ? "ok" : "error", valid ? "Executable companion: \(file.path)" : "Missing or non-executable companion: \(file.path)",
            recovery: valid ? nil : "Run ./scripts/build-macos.sh and keep both companions beside the installed microvm binary."))
    }
    checks.append(doctorImages(paths: paths, arch: arch))
    do {
        let directory = try RuntimeArtifact.directory(runtimes, home: paths.home, arch: arch)
        let artifact = try RuntimeArtifact.resolve(runtimes, directory: directory, arch: arch)
        guard artifact.artifactDigest == directory.lastPathComponent else { throw MicroVMError("runtime catalog and manifest digests disagree") }
        try RuntimeArtifact.verifyFiles(artifact, directory: directory)
        checks.append(DoctorCheck("runtime", "ok", "Matching runtime manifest, disk hash, and boot files: \(directory.path)"))
    } catch {
        checks.append(DoctorCheck("runtime", "error", (error as? MicroVMError)?.message ?? "Cannot read the matching runtime artifact.",
                                  recovery: RuntimeArtifact.preparationInstruction(runtimes)))
    }
    checks.append(daemon(paths))
    return DoctorReport(home: paths.home.path, arch: arch, runtimes: runtimes, checks: checks)
}

private func doctorHomeAccess(_ home: URL) -> DoctorCheck {
    let fm = FileManager.default
    guard home.appendingPathComponent("daemon.sock").path.utf8.count < 104 else {
        return DoctorCheck("home", "error", "Home would exceed the Unix socket path limit.", recovery: "Choose a shorter --home PATH.")
    }
    var directory: ObjCBool = false
    if fm.fileExists(atPath: home.path, isDirectory: &directory) {
        let valid = directory.boolValue && fm.isReadableFile(atPath: home.path) && fm.isWritableFile(atPath: home.path)
            && access(home.path, X_OK) == 0
        let message = valid ? "Home is readable, writable, and searchable: \(home.path)" : "Home is inaccessible or not a directory: \(home.path)"
        return DoctorCheck("home", valid ? "ok" : "error", message,
                           recovery: valid ? nil : "Choose a readable, writable directory with --home PATH, or correct its permissions.")
    }
    var ancestor = home.deletingLastPathComponent()
    while !fm.fileExists(atPath: ancestor.path), ancestor.path != "/" { ancestor.deleteLastPathComponent() }
    let valid = fm.fileExists(atPath: ancestor.path, isDirectory: &directory) && directory.boolValue
        && fm.isWritableFile(atPath: ancestor.path) && access(ancestor.path, X_OK) == 0
    return DoctorCheck("home", valid ? "warning" : "error", "Home does not exist: \(home.path)",
                       recovery: valid ? "An operational command can create this home; doctor leaves it absent."
                           : "Choose a writable --home PATH or correct the parent directory's permissions.")
}

private struct DoctorImageManifest: Decodable {
    var arch: String
    var guestPort: Int
    var kernelSHA256: String
    var initrdSHA256: String
}

private func doctorImages(paths: MicroVMPaths, arch: String) -> DoctorCheck {
    do {
        let manifest = try JSONDecoder().decode(DoctorImageManifest.self, from: Data(contentsOf: paths.imageDir(arch).appendingPathComponent("manifest.json")))
        guard manifest.arch == arch, manifest.guestPort == Int(MicroVMInfo.guestPort),
              manifest.kernelSHA256.count == 64, manifest.initrdSHA256.count == 64,
              try fileDigest(paths.kernel(arch)) == manifest.kernelSHA256,
              try fileDigest(paths.initrd(arch)) == manifest.initrdSHA256 else { throw MicroVMError("image manifest or file hashes do not match") }
        return DoctorCheck("images", "ok", "Kernel and initrd hashes match the image manifest for \(arch).")
    } catch {
        return DoctorCheck("images", "error", "Missing, unreadable, or mismatched kernel/initrd/manifest for \(arch).",
                           recovery: "From the microvm source tree, run MICROVM_HOME=\(shellQuote(paths.home.path)) ./scripts/fetch-image.sh explicitly.")
    }
}

public func formatDoctorReport(_ report: DoctorReport, output: CLIOutput, arguments: [String] = []) throws -> String {
    var safe = report
    let secrets = cliFailureOptions(arguments).secrets
    safe.home = safeDiagnostic(safe.home, secrets: secrets)
    for index in safe.checks.indices {
        safe.checks[index].message = safeDiagnostic(safe.checks[index].message, secrets: secrets)
        safe.checks[index].recovery = safe.checks[index].recovery.map { safeDiagnostic($0, secrets: secrets) }
    }
    if output == .json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (String(data: try encoder.encode(safe), encoding: .utf8) ?? "") + "\n"
    }
    let lines = safe.checks.map { check in
        "\(check.status.uppercased()) \(check.id): \(check.message)" + (check.recovery.map { "\n  Next: " + $0 } ?? "")
    }
    return (["Home: \(safe.home)"] + lines + [safe.ok ? "Required checks passed." : "Required checks failed."]).joined(separator: "\n") + "\n"
}
