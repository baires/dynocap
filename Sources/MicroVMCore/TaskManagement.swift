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

    func remove(_ id: String, purge: Bool) throws {
        try destroy(id)  // Failed teardown must keep the alias, disk and record.
        namespace.lock()
        defer { namespace.unlock() }
        condition.lock()
        defer { condition.unlock() }
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
