import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One `doctor --fix` step and how it ended.
public struct DoctorRepair: Encodable {
    public var fix: DoctorFix
    /// fixed, failed, or skipped.
    public var status: String
    public var summary: String
    public var recovery: String?
    public var logPath: String?
    /// Something the user should know even on success, such as where replaced files were moved.
    public var note: String?
    public var seconds: Double

    enum CodingKeys: String, CodingKey { case fix, status, summary, recovery, logPath, note, seconds }
    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(fix, forKey: .fix)
        try fields.encode(status, forKey: .status)
        try fields.encode(summary, forKey: .summary)
        try fields.encode(recovery, forKey: .recovery)
        try fields.encode(logPath, forKey: .logPath)
        try fields.encode(note, forKey: .note)
        try fields.encode((seconds * 10).rounded() / 10, forKey: .seconds)
    }
}

/// What a successful fix leaves behind for the report.
public struct DoctorRepairOutput {
    public var log: URL?
    public var note: String?

    public init(log: URL? = nil, note: String? = nil) {
        self.log = log
        self.note = note
    }
}

/// A failure that keeps the build log the user should read.
public struct DoctorRepairFailure: Error {
    public var error: DynoCapError
    public var log: URL

    public init(_ error: DynoCapError, log: URL) {
        self.error = error
        self.log = log
    }
}

extension DoctorFix {
    /// What the step does, phrased for a progress line.
    public func action(_ report: DoctorReport) -> String {
        switch self {
        case .restartDaemon: return "Restarting the daemon with this dynocap build"
        case .buildImages: return "Building the guest image for \(report.arch)"
        case .prepareRuntime: return "Preparing runtime " + report.runtimes.map { $0.name + ":" + $0.version }.joined(separator: ", ")
        }
    }
}

/// Runs each fix the report offers, in repair order. Runtime preparation verifies through the daemon,
/// so it is skipped when the daemon restart failed.
public func repairHost(
    _ report: DoctorReport, progress: (DoctorFix, DoctorRepair?) -> Void, perform: (DoctorFix) throws -> DoctorRepairOutput
) -> [DoctorRepair] {
    var repairs: [DoctorRepair] = []
    for fix in report.fixes {
        progress(fix, nil)
        let started = ProcessInfo.processInfo.systemUptime
        var repair = DoctorRepair(fix: fix, status: "fixed", summary: fix.action(report), seconds: 0)
        if fix == .prepareRuntime, repairs.contains(where: { $0.fix == .restartDaemon && $0.status == "failed" }) {
            repair.status = "skipped"
            repair.summary += ": skipped because the daemon restart failed"
        } else {
            do {
                let output = try perform(fix)
                repair.logPath = output.log?.path
                repair.note = output.note
            } catch {
                let failure = error as? DoctorRepairFailure
                let detail = failure?.error ?? (error as? DynoCapError) ?? DynoCapError(String(describing: error))
                repair.status = "failed"
                repair.summary += ": " + detail.message
                repair.recovery = detail.recovery.isEmpty ? nil : detail.recovery
                repair.logPath = failure?.log.path
            }
        }
        repair.seconds = ProcessInfo.processInfo.systemUptime - started
        progress(fix, repair)
        repairs.append(repair)
    }
    return repairs
}

/// Finds a tool on PATH the way a shell would, so a missing toolchain is reported before a build starts.
public func findOnPath(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
    let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/local/go/bin"]
    for directory in directories where !directory.isEmpty {
        let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    return nil
}

/// Image and runtime builds compile the guest agent, so both need Go.
public func requireGo() throws -> URL {
    guard let go = findOnPath("go") else {
        throw DynoCapError(
            "Go is not installed or not on PATH; it compiles the guest agent",
            recovery: "Install Go 1.22 or newer (for example `brew install go`), then run dynocap doctor --fix again.")
    }
    return go
}

/// Builds the guest kernel/initrd from the dynocap checkout into the home's image directory.
/// A valid `images/<arch>` beside the checkout is copied when the home image is missing or does not match.
/// A missing or damaged bundle still compiles with Go. Files already in the home may be hand-built, so they
/// are moved aside, never deleted.
public func buildGuestImage(paths: DynoCapPaths, arch: String, source: URL, go: URL? = nil) throws -> DoctorRepairOutput {
    if let copied = try installBundledGuestImage(paths: paths, arch: arch, source: source) {
        return copied
    }
    let go = try go ?? requireGo()
    try paths.ensure()
    let images = paths.imageDir(arch)
    try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
    let note = try moveAsideImageFiles(in: images)
    let log = paths.home.appendingPathComponent("image-build-\(UUID().uuidString.lowercased()).log")
    guard FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
        throw DynoCapError("cannot create the image build log at \(log.path)")
    }
    let handle = try FileHandle(forWritingTo: log)
    defer { try? handle.close() }
    let process = Process()
    process.executableURL = go
    process.currentDirectoryURL = source.appendingPathComponent("guest")
    process.arguments = [
        "run", "./mkimage", "--arch", arch, "--out", paths.imageDir(arch).path, "--cache", paths.cache.path, "--repo", source.path,
    ]
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = go.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = handle
    process.standardError = handle
    do { try process.run() } catch {
        throw DynoCapError("could not start \(go.path)", recovery: "Check your Go installation, then run dynocap doctor --fix again.")
    }
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        throw DoctorRepairFailure(DynoCapError(
            "image build failed (status \(process.terminationStatus))" + (lastLogLine(log).map { ": \($0)" } ?? ""),
            recovery: "Read the log for the failing download or compile step, fix it, then run dynocap doctor --fix again."
                + (note.map { " \($0)." } ?? "")), log: log)
    }
    return DoctorRepairOutput(log: log, note: note)
}

/// Copies `source/images/<arch>` into the home when that bundle matches its manifest.
/// Returns nil when the bundle is missing or damaged so the caller compiles with Go.
func installBundledGuestImage(paths: DynoCapPaths, arch: String, source: URL) throws -> DoctorRepairOutput? {
    let bundled = source.appendingPathComponent("images").appendingPathComponent(arch)
    guard guestImageIsValid(directory: bundled, arch: arch) else { return nil }
    try paths.ensure()
    let images = paths.imageDir(arch)
    try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
    let retired = try moveAsideImageFiles(in: images)
    for name in ["kernel", "initrd", "manifest.json"] {
        try FileManager.default.copyItem(at: bundled.appendingPathComponent(name), to: images.appendingPathComponent(name))
    }
    var note = "Copied the bundled \(arch) guest image into \(images.path)."
    if let retired { note += " " + retired }
    return DoctorRepairOutput(note: note)
}

/// Moves kernel, initrd, and manifest.json into `replaced-<time>` when any of them are present.
private func moveAsideImageFiles(in images: URL) throws -> String? {
    let fm = FileManager.default
    let names = ["kernel", "initrd", "manifest.json"]
    let existing = names.filter { fm.fileExists(atPath: images.appendingPathComponent($0).path) }
    guard !existing.isEmpty else { return nil }
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
    let backup = images.appendingPathComponent("replaced-\(stamp)", isDirectory: true)
    try fm.createDirectory(at: backup, withIntermediateDirectories: true)
    for name in existing {
        try fm.moveItem(at: images.appendingPathComponent(name), to: backup.appendingPathComponent(name))
    }
    return "The previous \(existing.joined(separator: ", ")) did not match and were moved to \(backup.path)"
}

/// The last useful line of a build log. `go run` appends `exit status N` after the tool's own error,
/// and that status is already in the summary, so the line before it is the one a person can act on.
func lastLogLine(_ log: URL) -> String? {
    guard let text = try? String(contentsOf: log, encoding: .utf8) else { return nil }
    let lines = text.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    return lines.reversed().first { line in
        line.trimmingCharacters(in: .whitespaces).range(of: #"^exit status \d+$"#, options: .regularExpression) == nil
    }.map { String($0.prefix(200)) }
}
