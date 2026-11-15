import Foundation

public struct RecordedLogStream: Codable {
    public var fileName: String
    public var bytes: Int64?
    public var expectedBytes: Int64?
    public var integrity: String
}

/// For format `terminal`, `stdout` is the combined terminal transcript and `stderr` is `absent`.
public struct RecordedExecution: Codable {
    public var id: Int
    public var command: String
    public var state: String
    public var startedAtUnix: Int64
    public var endedAtUnix: Int64?
    public var exitCode: Int32?
    public var format: String
    public var stdout: RecordedLogStream
    public var stderr: RecordedLogStream
}

public struct ExecutionLogs: Codable {
    public var id: String
    public var name: String?
    public var resultExpiresAtUnix: Int64
    public var directory: String
    public var executions: [RecordedExecution]
}

extension TaskManager {
    func executionLogs(_ target: String, now: Int64 = unixNow()) throws -> ExecutionLogs {
        try validateVMName(target)
        let records = try records(now: now)
        guard let record = records.first(where: { $0.id == target }) ?? records.first(where: { $0.name == target }) else {
            throw DynoCapError(
                "project task logs not found or expired: \(target)", code: .notFound,
                recovery: "Run dynocap ls to select a retained project task; raw sandboxes do not record execution logs.")
        }
        let directory = record.resultDirectory.map { URL(fileURLWithPath: $0) } ?? dir(record.id)
        let executions = try record.commands.enumerated().map { index, command -> RecordedExecution in
            // The journal owns these names. Never let a corrupt entry turn log replay into arbitrary file access.
            let output = command.isTerminal ? "\(index).terminal" : "\(index).stdout"
            guard command.stdout == output, command.stderr == "\(index).stderr" else {
                throw DynoCapError("execution \(index) has invalid log filenames",
                                   recovery: "Inspect the retained task record; log replay will not follow arbitrary paths.")
            }
            let active = command.endedAtUnix == nil && ["starting", "running", "finalizing"].contains(record.phase)
            let state: String
            if active { state = "running" } else if command.endedAtUnix == nil { state = "interrupted" } else {
                if command.error != nil || (command.exitCode ?? 0) != 0 { state = "failed" } else {
                    state = command.exitCode == 0 ? "completed" : "unknown"
                }
            }
            func stream(_ name: String, expected: Int64?) -> RecordedLogStream {
                let file = directory.appendingPathComponent(name)
                let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                let bytes = values?.isRegularFile == true ? values?.fileSize.map(Int64.init) : nil
                let integrity: String
                let finalLengthDiffers = expected != nil && command.endedAtUnix != nil && expected != bytes
                if bytes == nil { integrity = "missing" } else if command.logsTruncated == true || finalLengthDiffers {
                    integrity = "truncated"
                } else if expected == nil || active || command.endedAtUnix == nil { integrity = "unknown" } else { integrity = "complete" }
                return RecordedLogStream(fileName: name, bytes: bytes, expectedBytes: expected, integrity: integrity)
            }
            let label = String((command.argv.first ?? "unknown").prefix(48))
            let boundedLabel = String(bytes: label.utf8.prefix(192), encoding: .utf8) ?? "unknown"
            return RecordedExecution(
                id: index, command: boundedLabel, state: state,
                startedAtUnix: command.startedAtUnix, endedAtUnix: command.endedAtUnix, exitCode: command.exitCode,
                format: command.outputFormat ?? "separate", stdout: stream(command.stdout, expected: command.stdoutBytes),
                // A terminal has no stderr recording. `absent` keeps the field for older CLIs, which refuse the format.
                stderr: command.isTerminal
                    ? RecordedLogStream(fileName: command.stderr, bytes: nil, expectedBytes: nil, integrity: "absent")
                    : stream(command.stderr, expected: command.stderrBytes))
        }
        return ExecutionLogs(id: record.id, name: record.name, resultExpiresAtUnix: record.expiresAtUnix,
                             directory: directory.path, executions: executions)
    }
}
