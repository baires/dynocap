import Foundation

public struct ManagedEntry: Codable {
    public var id: String
    public var name: String?
    public var kind: String
    public var phase: String
    public var runtime: String
    public var network: NetworkMode?
    public var expiresAtUnix: Int64?
    public var resultDirectory: String?
}

extension TaskManager {
    func records() throws -> [TaskRecord] {
        condition.lock()
        defer { condition.unlock() }
        return try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).compactMap { entry in
            guard let record = try? load(entry.lastPathComponent), record.expiresAtUnix > unixNow() else { return nil }
            return current?.id == record.id ? current : record
        }.sorted { $0.id < $1.id }
    }

    func resolve(_ target: String) throws -> TaskRecord {
        try validateVMName(target)
        if let record = try records().first(where: { $0.id == target || $0.name == target }) { return record }
        throw MicroVMError("project task not found: \(target); diff and finish require a project task")
    }

    func reserveName(_ name: String?) throws {
        guard let name else { return }
        try validateTaskName(name)
        namespace.lock()
        defer { namespace.unlock() }
        guard !reservedNames.contains(name), !(try records()).contains(where: { $0.name == name }),
            !(try StateStore(paths: paths).list()).contains(where: { $0.name == name })
        else {
            throw MicroVMError("name already exists: \(name); remove it before reuse")
        }
        reservedNames.insert(name)
    }

    func releaseNameReservation(_ name: String?) {
        guard let name else { return }
        namespace.lock()
        reservedNames.remove(name)
        namespace.unlock()
    }

    func checkRawName(_ name: String) throws {
        try validateTaskName(name)
        guard !reservedNames.contains(name), !(try records()).contains(where: { $0.name == name }) else {
            throw MicroVMError("name belongs to a project task: \(name)")
        }
    }

    func cleanupFailedStart(_ id: String) {
        do {
            try destroy(id)
            try? fm.removeItem(at: dir(id))
            release()
        } catch {
            condition.lock()
            defer { condition.unlock() }
            if var record = current, record.id == id {
                record.phase = "interrupted"
                record.message = "startup failed; teardown must be retried: \(error)"
                current = record
                try? save(record)
                // Keep admission occupied until explicit removal or TTL teardown succeeds.
            } else {
                busy = false
                condition.broadcast()
            }
        }
    }

    func ensureStarting(_ id: String) throws {
        condition.lock()
        defer { condition.unlock() }
        guard current?.id == id, current?.phase == "starting" else {
            throw MicroVMError("task was removed during startup")
        }
    }

    func remove(_ id: String, purge: Bool) throws {
        var duringStartup = false
        do {
            // Serialize cancellation with boot's record registration.
            namespace.lock()
            defer { namespace.unlock() }
            duringStartup = (try? load(id))?.phase == "starting"
            try destroy(id)  // Failed teardown must keep the alias, disk and record.
            stopped(id, reason: "sandbox removed")
        }
        condition.lock()
        while reviewing || (duringStartup && busy && current == nil) { condition.wait() }
        condition.unlock()
        namespace.lock()
        defer { namespace.unlock() }
        condition.lock()
        defer { condition.unlock() }
        // Cancelled startup may already have removed its unpublished record.
        guard fm.fileExists(atPath: dir(id).path) else { return }
        var record = try load(id)
        if purge {
            try fm.removeItem(at: dir(id))
        } else {
            record.name = nil
            try save(record)
        }
    }
}

func validateTaskName(_ name: String) throws {
    try validateVMName(name)
    guard !name.hasPrefix("task-"), !name.hasPrefix("runtime-") else {
        throw MicroVMError("name is reserved: \(name)")
    }
}

public struct TaskPreview: Codable {
    public var directory: String
    public var patchPath: String
    public var reviewPath: String
    public var changesPath: String
    init(_ directory: URL) {
        self.directory = directory.path
        patchPath = directory.appendingPathComponent("changes.patch").path
        reviewPath = directory.appendingPathComponent("review.txt").path
        changesPath = directory.appendingPathComponent("changes.json").path
    }
}

extension TaskManager {
    func preview(_ id: String, requireOffline: Bool, permitFiltered: Bool?) throws -> TaskPreview {
        let record = try load(id)
        if let result = record.resultDirectory { return TaskPreview(URL(fileURLWithPath: result)) }
        condition.lock()
        guard !reviewing, current?.id == id, current?.phase == "running", active == 0 else {
            condition.unlock()
            throw MicroVMError("diff requires an idle running task; commands or another review may be active")
        }
        if let rejection = NetworkAdmission.rejection(
            network: record.network, requireOffline: requireOffline,
            permitFiltered: permitFiltered, offlineMessage: "task requires offline networking") {
            condition.unlock()
            throw MicroVMError(rejection)
        }
        reviewing = true
        condition.unlock()
        let directory = dir(id)
        let preview = directory.appendingPathComponent("preview")
        let stage = directory.appendingPathComponent("preview.partial")
        let archive = directory.appendingPathComponent("preview-export.tar")
        let final = directory.appendingPathComponent("preview-tree")
        defer {
            for path in [stage, archive, final] { try? fm.removeItem(at: path) }
            condition.lock()
            reviewing = false
            condition.broadcast()
            condition.unlock()
        }
        try? fm.removeItem(at: preview)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        _ = try execute(id, ["/usr/local/bin/microvm-agent", "task-pack", "/workspace"], [], nil, archive, 256 << 20)
        _ = try hostTree("microvm-workspace", ["unpack", final.path], archive, nil)
        _ = try hostTree(
            "microvm-workspace", ["result", directory.appendingPathComponent("baseline").path, final.path, stage.path], nil, nil)
        guard try treeSize(stage) <= 256 << 20 else { throw MicroVMError("diff exceeds 256 MiB export limit") }
        condition.lock()
        defer { condition.unlock() }
        guard current?.id == id, current?.phase == "running" else { throw MicroVMError("task stopped during diff") }
        try fm.moveItem(at: stage, to: preview)
        return TaskPreview(preview)
    }
}
