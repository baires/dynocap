import Foundation

public struct TaskCommand: Codable, Equatable {
    public var op: String
    public var name: String?
    public var purge: Bool?
    public var id: String?
    public var projectPath: String?
    public var repositoryUrl: String?
    public var ref: String?
    public var gitToken: String?
    public var sshKeyPath: String?
    public var runtimes: [RuntimeSelection]?
    public var network: NetworkMode?
    public var ttlSeconds: Int?
    public var cpus: Int?
    public var memoryMB: Int?
    public var argv: [String]?
    public var requireOffline: Bool?
    public var permitFiltered: Bool?
    public var reportProgress: Bool?
    public init(op: String) { self.op = op }
}

public struct TaskCommandRecord: Codable {
    var argv: [String]
    var startedAtUnix: Int64
    var endedAtUnix: Int64?
    var exitCode: Int32?
    var error: String?
    var stdout: String
    var stderr: String
    var stdoutBytes: Int64?
    var stderrBytes: Int64?
    var logsTruncated: Bool?
    var outputFormat: String?
}

public struct TaskRecord: Codable {
    public var id: String
    public var name: String?
    public var runtimes: [RuntimeSelection]?
    public var phase: String
    public var runtimeDigest: String
    public var createdAtUnix: Int64
    public var expiresAtUnix: Int64
    public var resultDirectory: String?
    public var sourcePath: String?
    public var sourceUrl: String?
    public var sourceRevision: String?
    public var network: NetworkMode
    var commands: [TaskCommandRecord] = []
    var logBytes: Int = 0
    var message: String?
    var dependencyCacheKey: String?
    var timingsMS: [String: Double] = [:]
}

public struct TaskDescriptor: Codable {
    public var id: String
    public var name: String?
    public var runtimes: [RuntimeSelection]?
    public var phase: String
    public var runtimeDigest: String
    public var createdAtUnix: Int64
    public var expiresAtUnix: Int64
    public var sandboxExpiresAtUnix: Int64?
    public var resultDirectory: String?
    public var sourceUrl: String?
    public var sourceRevision: String?
    public var timingsMS: [String: Double]
    public var network: NetworkMode
    init(_ record: TaskRecord, sandbox: VMRecord? = nil) {
        id = record.id
        name = record.name
        runtimes = record.runtimes
        network = record.network
        phase = record.phase
        runtimeDigest = record.runtimeDigest
        createdAtUnix = record.createdAtUnix
        expiresAtUnix = record.expiresAtUnix
        sandboxExpiresAtUnix = sandbox.flatMap { vm in vm.ttlSeconds.map { vm.createdAtUnix + Int64($0) } }
        resultDirectory = record.resultDirectory
        sourceUrl = record.sourceUrl
        sourceRevision = record.sourceRevision
        timingsMS = record.timingsMS
    }
}

/// Owns task admission, records, host logs and finalization. Runtime contents are opaque.
final class TaskManager {
    typealias Execute = (String, [String], [String], URL?, URL?, Int64) throws -> Data
    let paths: MicroVMPaths
    let arch: String
    let boot: (RunRequest) throws -> VMRecord
    let execute: Execute
    let destroy: (String) throws -> Void
    let namespace = NSRecursiveLock()
    var reservedNames: Set<String> = []
    let condition = NSCondition()
    var current: TaskRecord?
    var busy = false
    var active = 0
    var reviewing = false
    let hostTree: (String, [String], URL?, URL?) throws -> Data
    let fm = FileManager.default
    var root: URL { paths.home.appendingPathComponent("tasks") }
    func dir(_ id: String) -> URL { root.appendingPathComponent(id) }
    func save(_ record: TaskRecord) throws {
        try JSONEncoder().encode(record).write(to: dir(record.id).appendingPathComponent("task.json"), options: .atomic)
    }
    func load(_ id: String) throws -> TaskRecord {
        try validateVMName(id)
        return try JSONDecoder().decode(TaskRecord.self, from: Data(contentsOf: dir(id).appendingPathComponent("task.json")))
    }
    init(
        paths: MicroVMPaths, arch: String, boot: @escaping (RunRequest) throws -> VMRecord, execute: @escaping Execute,
        destroy: @escaping (String) throws -> Void,
        hostTree: @escaping (String, [String], URL?, URL?) throws -> Data = { try HostTree.run($0, $1, input: $2, output: $3) }
    ) {
        self.paths = paths
        self.arch = arch
        self.boot = boot
        self.execute = execute
        self.destroy = destroy
        self.hostTree = hostTree
    }
    func recover() throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for entry in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard var record = try? load(entry.lastPathComponent) else {
                if entry.lastPathComponent.hasPrefix("task-") { try fm.removeItem(at: entry) }
                continue
            }
            if record.expiresAtUnix <= unixNow() {
                try fm.removeItem(at: entry)
                continue
            }
            if record.phase == "running" || record.phase == "finalizing" || record.phase == "starting" {
                record.phase = "interrupted"
                record.message = "daemon restarted; unexported edits were discarded"
                try save(record)
            }
            try? fm.removeItem(at: entry.appendingPathComponent("workspace.ext4"))
            try? fm.removeItem(at: entry.appendingPathComponent("baseline"))
            try? fm.removeItem(at: entry.appendingPathComponent("final"))
            for name in ["result.partial", "export.tar", "import.tar", "preview", "preview.partial", "preview-export.tar", "preview-tree"] {
                try? fm.removeItem(at: entry.appendingPathComponent(name))
            }
        }
        try? fm.removeItem(at: paths.home.appendingPathComponent("runtime-candidate"))
        let seeds = paths.home.appendingPathComponent("npm-cache")
        if let entries = try? fm.contentsOfDirectory(at: seeds, includingPropertiesForKeys: nil) {
            for entry in entries where entry.pathExtension == "partial" { try? fm.removeItem(at: entry) }
        }
        // Abandoned build candidates are never reused as verified runtime artifacts.
        let cache = paths.cache
        if let entries = try? fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil) {
            for entry in entries where entry.lastPathComponent.hasPrefix("runtime-build-") { try? fm.removeItem(at: entry) }
        }
    }
    func sweepExpired() {
        condition.lock()
        defer { condition.unlock() }
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            if let record = try? load(entry.lastPathComponent), record.expiresAtUnix <= unixNow(), record.id != current?.id {
                try? fm.removeItem(at: entry)
            }
        }
    }
    func admit() throws {
        condition.lock()
        defer { condition.unlock() }
        guard !busy, !reviewing else { throw MicroVMError("one task or runtime preparation may run at a time") }
        var used: Int64 = 0
        for entry in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            if let record = try? load(entry.lastPathComponent), record.expiresAtUnix <= unixNow() {
                try fm.removeItem(at: entry)
            } else {
                used += try treeSize(entry)
            }
        }
        guard used <= (1 << 30) - (256 << 20) else {
            throw MicroVMError("result capacity unavailable; copy/remove results or wait for expiry")
        }
        busy = true
    }
    func release() {
        condition.lock()
        busy = false
        active = 0
        current = nil
        condition.broadcast()
        condition.unlock()
    }
    func start(_ command: TaskCommand, progress: (CreationStage) -> Void = { _ in }) throws -> TaskRecord {
        let started = ProcessInfo.processInfo.systemUptime
        var timings: [String: Double] = [:]
        var mark = started
        func measured(_ name: String) {
            let now = ProcessInfo.processInfo.systemUptime
            timings[name] = (now - mark) * 1000
            mark = now
        }
        let resolved = try TaskSourceResolver.resolve(command)
        progress(.checkingRuntime)
        // Resolution precedes allocation and runtime requests are never silently substituted.
        let runtime = try RuntimeArtifact.directory(command.runtimes, home: paths.home, arch: arch)
        let artifact = try RuntimeArtifact.resolve(command.runtimes, directory: runtime, arch: arch)
        try RuntimeArtifact.verifyFiles(artifact, directory: runtime)
        try reserveName(command.name)
        defer { releaseNameReservation(command.name) }
        try admit()
        let id = "task-" + UUID().uuidString.lowercased()
        let directory = dir(id)
        var completed = false
        defer {
            if !completed {
                cleanupFailedStart(id)
            }
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = directory.appendingPathComponent("import.tar")
        let baseline = directory.appendingPathComponent("baseline")
        var gitTar: URL?
        var sourceURL: String?
        var sourceRevision: String?
        var credentialEnv: [String] = []
        progress(.importingSource)
        switch resolved {
        case .directory(let source):
            _ = try hostTree("microvm-workspace", ["pack", source, "project"], nil, input)
            let history = directory.appendingPathComponent("history")
            let imported = String(
                data: try hostTree("microvm-workspace", ["import-git", source, history.path], nil, nil), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if imported == "git" {
                gitTar = directory.appendingPathComponent("git.tar")
                _ = try hostTree("microvm-workspace", ["pack-git", history.path], nil, gitTar)
                try fm.removeItem(at: history)
            }
            _ = try hostTree("microvm-workspace", ["unpack", baseline.path], input, nil)
        case .guestClone(let repo):
            sourceURL = repo.url
            if repo.token != nil || repo.sshKeyPath != nil {
                credentialEnv = try GuestGit.secretEnv(repo)
            }
        }
        measured("snapshot")
        progress(.creatingWorkspace)
        let disk = directory.appendingPathComponent("workspace.ext4")
        _ = try hostTree("microvm-mkruntime", ["workspace", disk.path], nil, nil)
        measured("workspaceDisk")
        var record = TaskRecord(
            id: id, name: command.name, runtimes: artifact.runtimes, phase: "starting", runtimeDigest: artifact.artifactDigest,
            createdAtUnix: unixNow(),
            expiresAtUnix: unixNow() + 7 * 86400, network: command.network ?? NetworkMode.none)
        if case .directory(let path) = resolved { record.sourcePath = path }
        record.sourceUrl = sourceURL
        do {
            namespace.lock()
            defer { namespace.unlock() }
            try save(record)
            condition.lock()
            current = record
            condition.unlock()
        }
        var request = RunRequest(
            name: id, cpus: command.cpus ?? 2, memoryMB: command.memoryMB ?? 2048, ttlSeconds: command.ttlSeconds, bootTimeoutSeconds: 60,
            network: command.network ?? NetworkMode.none)
        request.runtimeDirectory = runtime.path
        request.workspaceDisk = disk.path
        if request.network == .filtered, case .guestClone(let repo) = resolved {
            request.filteredRepositoryHost = FilteredEgress.repositoryHost(repo.url)
        }
        progress(.booting)
        _ = try boot(request)
        measured("boot")
        if record.network == .nat || record.network == .filtered {
            progress(.waitingForNetwork)
            _ = try execute(
                id,
                [
                    "sh", "-c",
                    "i=0; until ip route | grep -q '^default' && grep -q '^nameserver' /etc/resolv.conf; do i=$((i+1)); [ $i -lt 20 ] || exit 1; sleep 1; done",
                ], [], nil, nil, 1 << 20)
        }
        measured("networkReady")
        progress(.populatingWorkspace)
        switch resolved {
        case .directory:
            _ = try execute(id, ["/usr/local/bin/microvm-agent", "unpack", "/workspace"], [], input, nil, 256 << 20)
            if let gitTar {
                _ = try execute(id, ["/usr/local/bin/microvm-agent", "unpack", "/workspace"], [], gitTar, nil, 256 << 20)
                try fm.removeItem(at: gitTar)
            }
        case .guestClone(let repo):
            let pinned = repo.ref.flatMap { CommitID.isValid($0) ? $0 : nil }
            let data = try execute(id, GuestGit.fetch(url: repo.url, ref: repo.ref), credentialEnv, nil, nil, 4 << 20)
            credentialEnv = []
            let revision = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard CommitID.isValid(revision) else { throw MicroVMError("git did not return a commit") }
            if let pinned {
                guard revision == pinned else { throw MicroVMError("git did not return a commit") }
            }
            sourceRevision = revision
            _ = try execute(id, ["/usr/local/bin/microvm-agent", "pack", "/workspace"], [], nil, input, 256 << 20)
            _ = try hostTree("microvm-workspace", ["unpack", baseline.path], input, nil)
        }
        _ = try execute(id, ["/usr/local/bin/microvm-agent", "freeze", "/workspace"], [], nil, nil, 1 << 20)
        if fm.fileExists(atPath: input.path) { try fm.removeItem(at: input) }
        measured("upload")
        record.sourceUrl = sourceURL
        record.sourceRevision = sourceRevision
        record.phase = "running"
        progress(.restoringCache)
        record.dependencyCacheKey = try DependencyCache.key(baseline: baseline, runtime: artifact)
        if let key = record.dependencyCacheKey { try DependencyCache.restore(key: key, home: paths.home, id: id, execute: execute) }
        measured("cacheRestore")
        timings["startTotal"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
        record.timingsMS = timings
        condition.lock()
        current = record
        do { try save(record) } catch {
            condition.unlock()
            throw error
        }
        condition.unlock()
        completed = true
        return record
    }
    func begin(_ name: String, argv: [String], env: [String] = []) throws -> Int? {
        condition.lock()
        defer { condition.unlock() }
        guard var record = current, record.id == name else { return nil }
        guard !reviewing, record.phase == "running", record.logBytes < 32 << 20 else {
            throw MicroVMError("task is finalizing or its log quota is exhausted")
        }
        if !DependencyCache.compatibleCommand(argv: argv, env: env) { record.dependencyCacheKey = nil }
        let index = record.commands.count
        record.commands.append(
            TaskCommandRecord(
                argv: argv, startedAtUnix: unixNow(), stdout: "\(index).stdout", stderr: "\(index).stderr",
                stdoutBytes: 0, stderrBytes: 0, logsTruncated: false, outputFormat: "separate"))
        guard record.commands.count <= 1000, try JSONEncoder().encode(record).count <= 4 << 20 else {
            throw MicroVMError("task command journal limit exceeded")
        }
        try ensureCommandLogs(directory: dir(name), index: index)
        current = record
        try save(record)
        active += 1
        return index
    }
    func append(_ name: String, index: Int?, data: Data, stderr: Bool) throws {
        guard let index else { return }
        condition.lock()
        defer { condition.unlock() }
        guard var record = current, record.id == name else { return }
        guard record.logBytes + data.count <= 32 << 20 else {
            record.commands[index].logsTruncated = true
            current = record
            try? save(record)
            throw MicroVMError("task log limit exceeded")
        }
        let path = dir(name).appendingPathComponent(stderr ? record.commands[index].stderr : record.commands[index].stdout)
        if !fm.fileExists(atPath: path.path) { fm.createFile(atPath: path.path, contents: nil) }
        do {
            let file = try FileHandle(forWritingTo: path)
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: data)
        } catch {
            record.commands[index].logsTruncated = true
            current = record
            try? save(record)
            throw error
        }
        if stderr {
            record.commands[index].stderrBytes = (record.commands[index].stderrBytes ?? 0) + Int64(data.count)
        } else {
            record.commands[index].stdoutBytes = (record.commands[index].stdoutBytes ?? 0) + Int64(data.count)
        }
        record.logBytes += data.count
        current = record
    }
    func end(_ name: String, index: Int?, code: Int32?, error: String?) {
        guard let index else { return }
        condition.lock()
        defer { condition.unlock() }
        guard var record = current, record.id == name else { return }
        record.commands[index].endedAtUnix = unixNow()
        record.commands[index].exitCode = code
        record.commands[index].error = error
        current = record
        try? save(record)
        active -= 1
        condition.broadcast()
    }
    func stopped(_ name: String, reason: String) {
        condition.lock()
        defer { condition.unlock() }
        guard var record = current, record.id == name else { return }
        let wasStarting = record.phase == "starting"
        if record.resultDirectory == nil {
            record.phase = "interrupted"
            record.message = reason
            for index in record.commands.indices where record.commands[index].endedAtUnix == nil {
                record.commands[index].endedAtUnix = unixNow()
                record.commands[index].error = reason
            }
            try? save(record)
        }
        try? fm.removeItem(at: dir(name).appendingPathComponent("workspace.ext4"))
        try? fm.removeItem(at: dir(name).appendingPathComponent("baseline"))
        try? fm.removeItem(at: dir(name).appendingPathComponent("final"))
        for path in ["preview", "preview.partial", "preview-export.tar", "preview-tree"] {
            try? fm.removeItem(at: dir(name).appendingPathComponent(path))
        }
        current = nil
        active = 0
        // Startup owns admission until its deferred cleanup has finished.
        busy = wasStarting
        condition.broadcast()
    }
    func recordedNetwork(_ id: String) -> NetworkMode? {
        try? load(id).network
    }

    func finish(_ id: String, requireOffline: Bool, permitFiltered: Bool? = nil) throws -> TaskRecord {
        var mark = ProcessInfo.processInfo.systemUptime
        let saved = try load(id)
        if saved.resultDirectory != nil {
            try destroy(id)
            return saved
        }
        condition.lock()
        guard !reviewing, var record = current, record.id == id, record.phase == "running" else {
            condition.unlock()
            throw MicroVMError("task is interrupted or already finalizing; unexported edits are unavailable")
        }
        if let message = NetworkAdmission.rejection(
            network: record.network, requireOffline: requireOffline, permitFiltered: permitFiltered,
            offlineMessage: "task requires offline networking"
        ) {
            condition.unlock()
            throw MicroVMError(message)
        }
        try? fm.removeItem(at: dir(id).appendingPathComponent("preview"))
        record.phase = "finalizing"
        current = record
        while active > 0 && current?.id == id { condition.wait() }
        guard let live = current, live.id == id else {
            condition.unlock()
            throw MicroVMError("task stopped during finalization")
        }
        record = live
        condition.unlock()
        let directory = dir(id)
        let stage = directory.appendingPathComponent("result.partial")
        do {
            try? fm.removeItem(at: stage)
            try fm.createDirectory(at: stage, withIntermediateDirectories: true)
            let archive = directory.appendingPathComponent("export.tar")
            _ = try execute(id, ["/usr/local/bin/microvm-agent", "task-pack", "/workspace"], [], nil, archive, 256 << 20)
            let final = directory.appendingPathComponent("final")
            _ = try HostTree.run("microvm-workspace", ["unpack", final.path], input: archive)
            try fm.removeItem(at: archive)
            record.timingsMS["export"] = (ProcessInfo.processInfo.systemUptime - mark) * 1000
            mark = ProcessInfo.processInfo.systemUptime
            _ = try HostTree.run(
                "microvm-workspace", ["result", directory.appendingPathComponent("baseline").path, final.path, stage.path])
            for cmd in record.commands {
                for name in [cmd.stdout, cmd.stderr] {
                    try publishCommandLog(from: directory.appendingPathComponent(name), to: stage.appendingPathComponent(name))
                }
            }
            try fm.copyItem(
                at: paths.home.appendingPathComponent("runtimes/\(record.runtimeDigest)/runtime.json"),
                to: stage.appendingPathComponent("runtime.json"))
            record.timingsMS["review"] = (ProcessInfo.processInfo.systemUptime - mark) * 1000
            mark = ProcessInfo.processInfo.systemUptime
            if let key = record.dependencyCacheKey {
                try? DependencyCache.publish(
                    seed: DependencyCache.Seed(key: key, runtimeDigest: record.runtimeDigest), finalTree: final, home: paths.home, id: id,
                    execute: execute)
            }
            record.timingsMS["cachePublish"] = (ProcessInfo.processInfo.systemUptime - mark) * 1000
            record.phase = record.commands.contains { $0.exitCode != 0 || $0.error != nil } ? "failed" : "completed"
            record.resultDirectory = directory.appendingPathComponent("result").path
            try JSONEncoder().encode(record).write(to: stage.appendingPathComponent("manifest.json"))
            guard try treeSize(stage) + Int64(JSONEncoder().encode(record).count) <= 256 << 20 else {
                throw MicroVMError("export exceeds 256 MiB including task metadata")
            }
            try fm.moveItem(at: stage, to: URL(fileURLWithPath: record.resultDirectory!))
            for command in record.commands {
                for name in [command.stdout, command.stderr] { try? fm.removeItem(at: directory.appendingPathComponent(name)) }
            }
            condition.lock()
            current = record
            do { try save(record) } catch {
                condition.unlock()
                throw error
            }
            condition.unlock()
            mark = ProcessInfo.processInfo.systemUptime
            try destroy(id)
            record.timingsMS["destroy"] = (ProcessInfo.processInfo.systemUptime - mark) * 1000
            try save(record)
            try JSONEncoder().encode(record).write(
                to: URL(fileURLWithPath: record.resultDirectory!).appendingPathComponent("manifest.json"), options: .atomic)
            return record
        } catch {
            try? fm.removeItem(at: stage)
            try? fm.removeItem(at: directory.appendingPathComponent("final"))
            try? fm.removeItem(at: directory.appendingPathComponent("export.tar"))
            condition.lock()
            if var live = current, live.id == id, live.resultDirectory == nil {
                live.phase = "running"
                current = live
                try? save(live)
            }
            condition.unlock()
            throw error
        }
    }
    func verifyRuntime(_ requested: [RuntimeSelection]?) throws -> RuntimeArtifact {
        try admit()
        defer { release() }
        let candidate = paths.home.appendingPathComponent("runtime-candidate")
        if !fm.fileExists(atPath: candidate.path) {
            let runtime = try RuntimeArtifact.directory(requested, home: paths.home, arch: arch)
            let cached = try RuntimeArtifact.resolve(requested, directory: runtime, arch: arch)
            try RuntimeArtifact.verifyFiles(cached, directory: runtime)
            return cached
        }
        defer { try? fm.removeItem(at: candidate) }
        let manifest = try JSONDecoder().decode(
            RuntimeArtifact.self, from: Data(contentsOf: candidate.appendingPathComponent("runtime.json")))
        guard manifest.runtimes == (requested ?? RuntimeArtifact.defaultRuntimes) else {
            throw MicroVMError("candidate does not match requested runtime")
        }
        let artifact = try RuntimeArtifact.resolve(manifest.runtimes, directory: candidate, arch: arch)
        try RuntimeArtifact.verifyFiles(artifact, directory: candidate)
        let disk = candidate.appendingPathComponent("verify.ext4")
        _ = try hostTree("microvm-mkruntime", ["workspace", disk.path], nil, nil)
        let name = "runtime-verify"
        defer {
            try? destroy(name)
            try? fm.removeItem(at: disk)
        }
        var request = RunRequest(name: name, cpus: 2, memoryMB: 2048, ttlSeconds: 120, bootTimeoutSeconds: 60, network: NetworkMode.none)
        request.runtimeDirectory = candidate.path
        request.workspaceDisk = disk.path
        _ = try boot(request)
        _ = try execute(name, artifact.verificationCommand, [], nil, nil, 1 << 20)
        _ = try execute(name, ["sh", "-c", "! touch /usr/runtime-must-stay-readonly"], [], nil, nil, 1 << 20)
        try destroy(name)
        try fm.removeItem(at: disk)
        let artifacts = paths.home.appendingPathComponent("runtimes")
        try fm.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let dest = artifacts.appendingPathComponent(artifact.artifactDigest)
        var replace = !fm.fileExists(atPath: dest.path)
        if !replace {
            do {
                let existing = try RuntimeArtifact.resolve(artifact.runtimes, directory: dest, arch: arch)
                try RuntimeArtifact.verifyFiles(existing, directory: dest)
                replace = existing.artifactDigest != artifact.artifactDigest
            } catch { replace = true }
        }
        if replace {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: candidate, to: dest)
        } else {
            try fm.removeItem(at: candidate)
        }
        let catalogFile = paths.home.appendingPathComponent("runtime-catalog.json")
        var catalog = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: catalogFile))) ?? [:]
        catalog[RuntimeArtifact.selectionKey(artifact.runtimes, arch: arch)] = artifact.artifactDigest
        try JSONEncoder().encode(catalog).write(to: catalogFile, options: .atomic)
        let referenced = Set(catalog.values)
        for existing in try fm.contentsOfDirectory(at: artifacts, includingPropertiesForKeys: nil)
        where !referenced.contains(existing.lastPathComponent) {
            try? fm.removeItem(at: existing)
        }
        return artifact
    }
}

func ensureCommandLogs(directory: URL, index: Int) throws {
    for name in ["\(index).stdout", "\(index).stderr"] {
        let path = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: path.path) { continue }
        guard FileManager.default.createFile(atPath: path.path, contents: Data()) else {
            throw MicroVMError("could not create command log \(name)")
        }
    }
}

func publishCommandLog(from source: URL, to destination: URL) throws {
    if FileManager.default.fileExists(atPath: source.path) {
        try FileManager.default.copyItem(at: source, to: destination)
        return
    }
    guard FileManager.default.createFile(atPath: destination.path, contents: Data()) else {
        throw MicroVMError("could not publish command log \(destination.lastPathComponent)")
    }
}

func treeSize(_ url: URL) throws -> Int64 {
    guard let entries = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
        return 0
    }
    var total: Int64 = 0
    for case let entry as URL in entries {
        let values = try entry.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
    }
    return total
}
