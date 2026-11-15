import Foundation

public struct InspectionSource: Codable {
    public var kind: String
    public var value: String
    public var revision: String?
}

public struct InspectionResult: Codable {
    public var directory: String
    public var available: Bool
    public var patchPath: String?
    public var reviewPath: String?
    public var changesPath: String?
}

/// Read-only management facts; CLI encoding is defined separately.
public struct SandboxInspection: Codable {
    public var id: String
    public var name: String?
    public var kind: String
    public var phase: String
    public var source: InspectionSource?
    public var runtime: String
    public var runtimes: [RuntimeSelection]?
    public var runtimeDigest: String?
    public var network: NetworkMode?
    public var createdAtUnix: Int64
    public var sandboxPhase: String?
    public var sandboxExpiresAtUnix: Int64?
    public var resultExpiresAtUnix: Int64?
    public var result: InspectionResult?
    public var unexportedWork: String?
    public var message: String?
}

extension TaskManager {
    func inspect(_ target: String, sandboxes: [VMRecord], now: Int64 = unixNow()) throws -> SandboxInspection {
        try validateVMName(target)
        let records = try records(now: now)
        if let record = records.first(where: { $0.id == target }) ?? records.first(where: { $0.name == target }) {
            let sandbox = sandboxes.first { $0.name == record.id }
            let live = sandbox.map { [.booting, .running, .stopping].contains($0.phase) } ?? false
            let source: InspectionSource?
            if let url = record.sourceUrl {
                source = InspectionSource(kind: "repository", value: url, revision: record.sourceRevision)
            } else if let path = record.sourcePath {
                source = InspectionSource(kind: "directory", value: path)
            } else {
                source = nil
            }
            let result = record.resultDirectory.map(inspectionResult)
            let work: String
            if result != nil { work = "exported" } else if record.phase == "interrupted" {
                work = live ? "unavailable_cleanup_pending" : "discarded"
            } else { work = live ? "not_exported" : "unknown" }
            return SandboxInspection(
                id: record.id, name: record.name, kind: "task", phase: record.phase, source: source,
                runtime: record.runtimes?.map { $0.name + ":" + $0.version }.joined(separator: "+") ?? "unknown",
                runtimes: record.runtimes, runtimeDigest: record.runtimeDigest, network: record.network,
                createdAtUnix: record.createdAtUnix, sandboxPhase: sandbox?.phase.rawValue,
                sandboxExpiresAtUnix: sandbox.flatMap { vm in vm.ttlSeconds.map { vm.createdAtUnix + Int64($0) } },
                resultExpiresAtUnix: record.expiresAtUnix, result: result, unexportedWork: work, message: record.message)
        }
        // Project IDs are reserved. An expired project's leftover VM record must
        // not reappear as a raw sandbox or bypass task retention.
        if !target.hasPrefix("task-"), let record = sandboxes.first(where: { $0.name == target }) {
            return SandboxInspection(
                id: record.name, name: record.name, kind: "sandbox", phase: record.phase.rawValue,
                runtime: "minimal", network: record.network, createdAtUnix: record.createdAtUnix,
                sandboxPhase: record.phase.rawValue,
                sandboxExpiresAtUnix: record.ttlSeconds.map { record.createdAtUnix + Int64($0) }, message: record.message)
        }
        throw DynoCapError("sandbox or retained result not found or expired: \(target)", code: .notFound)
    }

    private func inspectionResult(_ directory: String) -> InspectionResult {
        var isDirectory: ObjCBool = false
        let available = fm.fileExists(atPath: directory, isDirectory: &isDirectory) && isDirectory.boolValue
        func artifact(_ name: String) -> String? {
            let file = URL(fileURLWithPath: directory).appendingPathComponent(name)
            guard available, (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
            return file.path
        }
        return InspectionResult(
            directory: directory, available: available, patchPath: artifact("changes.patch"),
            reviewPath: artifact("review.txt"), changesPath: artifact("changes.json"))
    }
}
