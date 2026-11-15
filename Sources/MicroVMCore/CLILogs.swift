import Foundation

public func formatExecutionList(_ logs: ExecutionLogs, arguments: [String] = []) -> String {
    guard !logs.executions.isEmpty else { return "No recorded executions for \(logs.name ?? logs.id).\n" }
    let secrets = cliFailureOptions(arguments).secrets
    var lines = ["EXEC  STATE  STARTED (UTC)  EXIT  STDOUT_BYTES  STDERR_BYTES  INTEGRITY  FORMAT  COMMAND"]
    for execution in logs.executions {
        let integrity: String
        let terminal = execution.format == "terminal"
        let values = terminal ? [execution.stdout.integrity] : [execution.stdout.integrity, execution.stderr.integrity]
        if values.contains("missing") { integrity = "missing" } else if values.contains("truncated") { integrity = "truncated" } else {
            integrity = values.contains("unknown") ? "unknown" : "complete"
        }
        let date = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(execution.startedAtUnix)))
        lines.append([
            String(execution.id), execution.state, date, execution.exitCode.map(String.init) ?? "-",
            execution.stdout.bytes.map(String.init) ?? "-", terminal ? "-" : execution.stderr.bytes.map(String.init) ?? "-", integrity,
            execution.format, execution.command,
        ].map { safeDiagnostic($0, secrets: secrets) }.joined(separator: "  "))
    }
    return lines.joined(separator: "\n") + "\n"
}

/// Copies each ordinary stream independently. It does not claim to restore cross-stream chronology.
/// A terminal transcript is already one chronological stream and is copied to stdout alone.
/// A filter, set when that output is a terminal, keeps guest escape sequences from acting on it.
public func replayExecutionLogs(
    _ logs: ExecutionLogs, execution: Int?, stdout: FileHandle = .standardOutput, stderr: FileHandle = .standardError,
    stdoutFilter: TerminalSanitizer? = nil, stderrFilter: TerminalSanitizer? = nil
) throws {
    guard let entry = execution.flatMap({ id in logs.executions.first { $0.id == id } }) ?? (execution == nil ? logs.executions.last : nil) else {
        throw MicroVMError("no recorded execution\(execution.map { " \($0)" } ?? "") for \(logs.name ?? logs.id)", code: .notFound,
                           recovery: "Run microvm logs NAME_OR_ID --list to discover available execution IDs.")
    }
    guard entry.format == "separate" || entry.format == "terminal" else {
        throw MicroVMError("execution \(entry.id) uses unsupported log format \(entry.format)",
                           recovery: "Use a CLI that supports this transcript format; separate stdout/stderr replay is unavailable.")
    }
    guard entry.state != "running" else {
        throw MicroVMError("execution \(entry.id) is still running", code: .invalidPhase,
                           recovery: "Wait for it to end, or use logs --list and --exec N to select an earlier execution.")
    }
    let streams = entry.format == "terminal" ? [entry.stdout] : [entry.stdout, entry.stderr]
    for stream in streams {
        guard ["complete", "unknown"].contains(stream.integrity) else {
            throw MicroVMError("execution \(entry.id) has \(stream.integrity) logs; replay refused before output",
                               recovery: "Use logs --list to check integrity; inspect surviving files in \(logs.directory)."
                                   + " Missing bytes cannot be reconstructed.")
        }
    }
    let out = try openLog(entry.stdout, directory: logs.directory)
    defer { try? out.close() }
    if entry.format == "terminal" {
        try checkLogLength(out, entry.stdout)
        try copyLog(out, to: stdout, bytes: entry.stdout.bytes ?? 0, filter: stdoutFilter)
        return
    }
    let err = try openLog(entry.stderr, directory: logs.directory)
    defer { try? err.close() }
    // Validate both handles before writing either stream, including races with finish/expiry/external truncation.
    for (file, stream) in [(out, entry.stdout), (err, entry.stderr)] { try checkLogLength(file, stream) }
    try copyLog(out, to: stdout, bytes: entry.stdout.bytes ?? 0, filter: stdoutFilter)
    try copyLog(err, to: stderr, bytes: entry.stderr.bytes ?? 0, filter: stderrFilter)
}

private func checkLogLength(_ file: FileHandle, _ stream: RecordedLogStream) throws {
    guard let bytes = stream.bytes, bytes >= 0, try file.seekToEnd() == UInt64(bytes) else {
        throw MicroVMError("execution logs changed while being opened", recovery: "Retry logs after the execution and finalization have ended.")
    }
    try file.seek(toOffset: 0)
}

private func openLog(_ stream: RecordedLogStream, directory: String) throws -> FileHandle {
    guard !stream.fileName.contains("/"), stream.fileName != ".", stream.fileName != ".." else {
        throw MicroVMError("invalid execution log path")
    }
    do { return try FileHandle(forReadingFrom: URL(fileURLWithPath: directory).appendingPathComponent(stream.fileName)) } catch {
        throw MicroVMError("execution log is missing or unreadable: \(stream.fileName)",
                           recovery: "Run logs --list again; the task may have expired or its files may have been removed.")
    }
}

private func copyLog(_ source: FileHandle, to output: FileHandle, bytes: Int64, filter: TerminalSanitizer?) throws {
    var filter = filter
    defer { if let rest = filter?.finish(), !rest.isEmpty { try? output.write(contentsOf: rest) } }
    var remaining = bytes
    while remaining > 0 {
        guard let chunk = try source.read(upToCount: Int(min(65536, remaining))), !chunk.isEmpty else {
            throw MicroVMError("execution log was truncated during replay", recovery: "Inspect the retained files; output already written is partial.")
        }
        try output.write(contentsOf: filter?.filter(chunk) ?? chunk)
        remaining -= Int64(chunk.count)
    }
}
