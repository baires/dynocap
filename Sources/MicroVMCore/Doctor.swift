import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A repair `doctor --fix` can perform without the user running anything else. Cases are in repair order:
/// the runtime is verified through the daemon, so the daemon is repaired first.
public enum DoctorFix: String, Encodable, CaseIterable {
    case restartDaemon = "restart-daemon"
    case buildImages = "build-images"
    case prepareRuntime = "prepare-runtime"
}

public struct DoctorCheck: Encodable {
    public var id: String
    public var status: String
    public var message: String
    public var recovery: String?
    /// Set when `doctor --fix` can repair this check on this machine; recovery then names that command.
    public var fix: DoctorFix?

    public init(_ id: String, _ status: String, _ message: String, recovery: String? = nil, fix: DoctorFix? = nil) {
        self.id = id
        self.status = status
        self.message = message
        self.recovery = recovery
        self.fix = fix
    }

    enum CodingKeys: String, CodingKey { case id, status, message, recovery, fix }
    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(id, forKey: .id)
        try fields.encode(status, forKey: .status)
        try fields.encode(message, forKey: .message)
        try fields.encode(recovery, forKey: .recovery)
        try fields.encode(fix, forKey: .fix)
    }
}

public struct DoctorReport: Encodable {
    public var ok: Bool { !checks.contains { $0.status == "error" } }
    public var home: String
    public var arch: String
    public var runtimes: [RuntimeSelection]
    public var checks: [DoctorCheck]
    /// What `doctor --fix` attempted before this report was collected; nil without --fix.
    public var repairs: [DoctorRepair]?
    /// The exact `doctor --fix` command for this home and runtime, so suggestions can be pasted as printed.
    public var fixCommand = "microvm doctor --fix"

    public var fixes: [DoctorFix] { DoctorFix.allCases.filter { fix in checks.contains { $0.fix == fix } } }

    enum CodingKeys: String, CodingKey { case ok, home, arch, runtimes, checks, repairs }
    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(ok, forKey: .ok)
        try fields.encode(home, forKey: .home)
        try fields.encode(arch, forKey: .arch)
        try fields.encode(runtimes, forKey: .runtimes)
        try fields.encode(checks, forKey: .checks)
        try fields.encodeIfPresent(repairs, forKey: .repairs)
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
/// `source` is the microvm checkout that image and runtime builds need; without one those checks are not fixable.
/// Empty `runtimes` means no project chose one: the runtime check then reports what is prepared instead of requiring one.
/// `runtimeOrigin` names the project file a detected runtime came from.
public func diagnoseHost(
    paths: MicroVMPaths, executable: URL, runtimes: [RuntimeSelection], host: DoctorHost, source: URL? = nil,
    runtimeOrigin: String? = nil, fixCommand: String = "microvm doctor --fix",
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
    var images = doctorImages(paths: paths, arch: arch)
    if images.status == "error" {
        let bundled = source?.appendingPathComponent("images").appendingPathComponent(arch)
        if source == nil {
            images.recovery = "Run \(fixCommand) from inside the microvm source checkout to build the guest image."
        } else if let bundled, guestImageIsValid(directory: bundled, arch: arch) {
            images.recovery = "Run \(fixCommand) to copy the bundled guest image into the home."
            images.fix = .buildImages
        } else {
            images.recovery = "Run \(fixCommand) to build the guest image (downloads pinned Alpine files; needs Go)."
            images.fix = .buildImages
        }
    }
    checks.append(images)
    var runtime = runtimes.isEmpty ? doctorPreparedRuntimes(paths: paths, arch: arch)
        : doctorRuntime(paths: paths, arch: arch, runtimes: runtimes, origin: runtimeOrigin)
    if runtime.status == "error" && runtime.recovery == nil {
        let label = runtimeLabel(runtimes)
        runtime.recovery = source == nil ? "Run \(fixCommand) from inside the microvm source checkout to prepare \(label)."
            : "Run \(fixCommand) to prepare \(label) (downloads verified inputs; takes a few minutes)."
        runtime.fix = source == nil ? nil : .prepareRuntime
    }
    // Preparation verifies the runtime in a guest, which cannot boot until the checks --fix cannot repair pass.
    if runtime.fix != nil, let blocker = checks.first(where: { $0.status == "error" && $0.fix == nil }) {
        runtime.fix = nil
        runtime.recovery = "Fix \(blocker.id) first, then run \(fixCommand) to prepare this runtime."
    }
    checks.append(runtime)
    checks.append(doctorDaemonFix(doctorDaemonAge(daemon(paths), paths: paths, executable: executable), paths: paths, fixCommand: fixCommand))
    var report = DoctorReport(home: paths.home.path, arch: arch, runtimes: runtimes, checks: checks)
    report.fixCommand = fixCommand
    return report
}

/// The microvm checkout beside the executable (a `.build` product) or around the working directory.
public func locateMicroVMSource(executable: URL, currentDirectory: URL) -> URL? {
    for start in [executable.deletingLastPathComponent(), currentDirectory] {
        var candidate = start.standardizedFileURL
        while true {
            let marker = candidate.appendingPathComponent("guest/mkimage/main.go").path
            if FileManager.default.fileExists(atPath: marker),
               FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path) {
                return candidate
            }
            guard candidate.path != "/" else { break }
            candidate.deleteLastPathComponent()
        }
    }
    return nil
}

/// The `doctor --fix` command that repairs what this doctor run checked, repeating only the arguments the user gave.
public func doctorFixCommand(home: URL?, runtimes: [RuntimeSelection]?, project: String? = nil) -> String {
    var words = ["microvm", "doctor", "--fix"]
    if let project { words.append(shellWord(project)) }
    if let home { words += ["--home", shellWord(home.path)] }
    if let runtimes { words += ["--runtime", shellWord(runtimeLabel(runtimes))] }
    return words.joined(separator: " ")
}

/// Quotes a shell word only when it needs it, so suggested commands read like ones a person types.
func shellWord(_ value: String) -> String {
    let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@%+=:,./-_"))
    return !value.isEmpty && value.unicodeScalars.allSatisfy(plain.contains) ? value : shellQuote(value)
}

private func runtimeLabel(_ runtimes: [RuntimeSelection]) -> String {
    runtimes.map { $0.name + ":" + $0.version }.joined(separator: ",")
}

/// Raw sandboxes need no runtime, so with no project to judge by, a missing runtime is a pointer, not a failure.
private func doctorPreparedRuntimes(paths: MicroVMPaths, arch: String) -> DoctorCheck {
    let prepared = RuntimeArtifact.preparedSelections(home: paths.home, arch: arch)
    guard prepared.isEmpty else { return DoctorCheck("runtime", "ok", "Prepared runtimes: \(prepared.joined(separator: ", ")).") }
    return DoctorCheck(
        "runtime", "warning", "No runtime is prepared yet; cloning a project needs the one it uses.",
        recovery: "Run microvm doctor --fix inside your project to prepare the runtime it needs, or pass --runtime with one of "
            + RuntimeArtifact.supportedSelections.joined(separator: ", ") + ".")
}

/// Errors without a recovery are ones `doctor --fix` can prepare away; the caller adds that step.
private func doctorRuntime(paths: MicroVMPaths, arch: String, runtimes: [RuntimeSelection], origin: String?) -> DoctorCheck {
    let label = runtimeLabel(runtimes)
    let unsupported = runtimes.map { $0.name + ":" + $0.version }.filter { !RuntimeArtifact.supportedSelections.contains($0) }
    guard unsupported.isEmpty else {
        return DoctorCheck("runtime", "error", "Runtime \(unsupported.joined(separator: ", ")) is not supported.",
                           recovery: "Choose one of \(RuntimeArtifact.supportedSelections.joined(separator: ", ")) with --runtime.")
    }
    let needed = origin.map { " This project's \($0) needs it." } ?? ""
    let message: String
    do {
        let directory: URL
        do {
            directory = try RuntimeArtifact.directory(runtimes, home: paths.home, arch: arch)
        } catch {
            throw MicroVMError("Runtime \(label) is not prepared for \(arch) yet.\(needed)")
        }
        do {
            let artifact = try RuntimeArtifact.resolve(runtimes, directory: directory, arch: arch)
            guard artifact.artifactDigest == directory.lastPathComponent else { throw MicroVMError("runtime catalog and manifest digests disagree") }
            try RuntimeArtifact.verifyFiles(artifact, directory: directory)
        } catch {
            let detail = (error as? MicroVMError)?.message ?? "cannot read the runtime artifact"
            throw MicroVMError("Prepared runtime \(label) is damaged or outdated: \(detail).")
        }
        return DoctorCheck("runtime", "ok", "Runtime \(label) is prepared and verified.\(origin.map { " Detected from \($0)." } ?? "")")
    } catch {
        message = (error as? MicroVMError)?.message ?? "Cannot read the runtime \(label)."
    }
    return DoctorCheck("runtime", "error", message)
}

/// A daemon that started before this CLI was rebuilt still runs the old code: it can lack capabilities or the
/// virtualization entitlement even when its ping looks healthy.
private func doctorDaemonAge(_ check: DoctorCheck, paths: MicroVMPaths, executable: URL) -> DoctorCheck {
    guard check.status == "ok", let data = try? Data(contentsOf: paths.identity),
          let identity = try? JSONDecoder().decode(DaemonIdentity.self, from: data),
          let built = (try? executable.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
          Int64(built.timeIntervalSince1970) > identity.startedAtUnix else { return check }
    return DoctorCheck("daemon", "error", "The running daemon started before this microvm binary was rebuilt, so it runs the old build.")
}

/// A broken or outdated daemon is restarted by --fix, unless that would stop sandboxes someone is using.
private func doctorDaemonFix(_ check: DoctorCheck, paths: MicroVMPaths, fixCommand: String) -> DoctorCheck {
    guard check.status == "error" else { return check }
    var check = check
    let live = ((try? StateStore(paths: paths).list()) ?? []).filter { $0.phase == .booting || $0.phase == .running }.map(\.name)
    if live.isEmpty {
        check.recovery = "Run \(fixCommand) to restart the daemon with this microvm build."
        check.fix = .restartDaemon
    } else {
        check.recovery = "Restarting the daemon would stop \(live.count == 1 ? "sandbox" : "sandboxes") \(live.joined(separator: ", ")). "
            + "Finish or remove \(live.count == 1 ? "it" : "them") with the CLI that created \(live.count == 1 ? "it" : "them"), then run \(fixCommand)."
    }
    return check
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
    guard valid else {
        return DoctorCheck("home", "error", "Home does not exist and its parent is not writable: \(home.path)",
                           recovery: "Choose a writable --home PATH or correct the parent directory's permissions.")
    }
    return DoctorCheck("home", "ok", "Home will be created on first use: \(home.path)")
}

private struct DoctorImageManifest: Decodable {
    var arch: String
    var guestPort: Int
    var kernelSHA256: String
    var initrdSHA256: String
}

func guestImageIsValid(directory: URL, arch: String) -> Bool {
    guard let manifest = try? JSONDecoder().decode(DoctorImageManifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json"))),
          manifest.arch == arch, manifest.guestPort == Int(MicroVMInfo.guestPort),
          manifest.kernelSHA256.count == 64, manifest.initrdSHA256.count == 64,
          (try? fileDigest(directory.appendingPathComponent("kernel"))) == manifest.kernelSHA256,
          (try? fileDigest(directory.appendingPathComponent("initrd"))) == manifest.initrdSHA256 else { return false }
    return true
}

private func doctorImages(paths: MicroVMPaths, arch: String) -> DoctorCheck {
    let directory = paths.imageDir(arch)
    if guestImageIsValid(directory: directory, arch: arch) {
        return DoctorCheck("images", "ok", "Kernel and initrd hashes match the image manifest for \(arch).")
    }
    let present = FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path)
    return DoctorCheck("images", "error", present ? "The guest image for \(arch) does not match its manifest."
                           : "The guest image for \(arch) has not been built yet.")
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
    let width = (safe.checks.map(\.id.count).max() ?? 0) + 2
    let indent = String(repeating: " ", count: 8 + width)
    var lines = ["Home: \(safe.home)", ""]
    for repair in safe.repairs ?? [] {
        lines.append("\(repair.status.uppercased().padding(toLength: 8, withPad: " ", startingAt: 0))\(repair.summary)")
        if let note = repair.note { lines.append("        Note: \(note)") }
        if let log = repair.logPath { lines.append("        Log: \(log)") }
        if let recovery = repair.recovery { lines.append("        Next: \(recovery)") }
    }
    if safe.repairs?.isEmpty == false { lines.append("") }
    for check in safe.checks {
        lines.append(check.status.uppercased().padding(toLength: 8, withPad: " ", startingAt: 0)
            + check.id.padding(toLength: width, withPad: " ", startingAt: 0) + check.message)
        if check.status != "ok", let recovery = check.recovery { lines.append(indent + "Next: " + recovery) }
    }
    lines.append("")
    lines.append(doctorSummary(safe))
    return lines.joined(separator: "\n") + "\n"
}

private func doctorSummary(_ report: DoctorReport) -> String {
    let failed = report.checks.filter { $0.status == "error" }
    guard !failed.isEmpty else { return "Required checks passed." }
    let fixable = failed.filter { $0.fix != nil }.count
    let problems = failed.count == 1 ? "1 required check failed" : "\(failed.count) required checks failed"
    if fixable == failed.count { return "\(problems). Run \(report.fixCommand) to repair \(fixable == 1 ? "it" : "them")." }
    if fixable > 0 { return "\(problems). \(report.fixCommand) repairs \(fixable) of them; follow Next for the rest." }
    return "\(problems). Follow Next for each one."
}
