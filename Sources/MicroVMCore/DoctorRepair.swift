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
    public var error: MicroVMError
    public var log: URL

    public init(_ error: MicroVMError, log: URL) {
        self.error = error
        self.log = log
    }
}

extension DoctorFix {
    /// What the step does, phrased for a progress line.
    public func action(_ report: DoctorReport) -> String {
        switch self {
        case .restartDaemon: return "Restarting the daemon with this microvm build"
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
                let detail = failure?.error ?? (error as? MicroVMError) ?? MicroVMError(String(describing: error))
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
        throw MicroVMError(
            "Go is not installed or not on PATH; it compiles the guest agent",
            recovery: "Install Go 1.22 or newer (for example `brew install go`), then run microvm doctor --fix again.")
    }
    return go
}

/// Builds the guest kernel/initrd from the microvm checkout into the home's image directory.
/// Files already there failed verification, so they may be hand-built: they are moved aside, never deleted.
public func buildGuestImage(paths: MicroVMPaths, arch: String, source: URL, go: URL? = nil) throws -> DoctorRepairOutput {
    let go = try go ?? requireGo()
    try paths.ensure()
    let fm = FileManager.default
    let images = paths.imageDir(arch)
    let existing = ["kernel", "initrd", "manifest.json"].filter { fm.fileExists(atPath: images.appendingPathComponent($0).path) }
    var note: String?
    if !existing.isEmpty {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let backup = images.appendingPathComponent("replaced-\(stamp)", isDirectory: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        for name in existing {
            try fm.moveItem(at: images.appendingPathComponent(name), to: backup.appendingPathComponent(name))
        }
        note = "The previous \(existing.joined(separator: ", ")) did not match and were moved to \(backup.path)"
    }
    let log = paths.home.appendingPathComponent("image-build-\(UUID().uuidString.lowercased()).log")
    guard FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
        throw MicroVMError("cannot create the image build log at \(log.path)")
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
        throw MicroVMError("could not start \(go.path)", recovery: "Check your Go installation, then run microvm doctor --fix again.")
    }
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        throw DoctorRepairFailure(MicroVMError(
            "image build failed (status \(process.terminationStatus))" + (lastLogLine(log).map { ": \($0)" } ?? ""),
            recovery: "Read the log for the failing download or compile step, fix it, then run microvm doctor --fix again."
                + (note.map { " \($0)." } ?? "")), log: log)
    }
    return DoctorRepairOutput(log: log, note: note)
}

/// The last non-empty line of a build log: usually the error that ended the build.
func lastLogLine(_ log: URL) -> String? {
    guard let text = try? String(contentsOf: log, encoding: .utf8) else { return nil }
    return text.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        .map { String($0.prefix(200)) }
}
