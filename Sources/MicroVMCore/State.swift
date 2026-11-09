import Foundation

public enum VMPhase: String, Codable, Equatable {
    case booting
    case running
    case stopping
    case stopped
    case failed
}

public enum VMEvent: Equatable {
    case agentReady
    case stopRequested
    case guestExited
    case fault
    case reap
}

public func transition(_ phase: VMPhase, _ event: VMEvent) -> VMPhase? {
    switch (phase, event) {
    case (.booting, .agentReady):
        return .running
    case (.booting, .stopRequested), (.running, .stopRequested):
        return .stopping
    case (.booting, .guestExited), (.running, .guestExited), (.stopping, .guestExited):
        return .stopped
    case (.booting, .fault), (.running, .fault), (.stopping, .fault):
        return .failed
    case (.booting, .reap), (.running, .reap), (.stopping, .reap):
        return .stopped
    case (.stopped, .guestExited), (.stopped, .reap), (.failed, .guestExited), (.failed, .reap),
         (.stopped, .stopRequested), (.failed, .stopRequested):
        return phase
    default:
        return nil
    }
}

public struct VMRecord: Codable, Equatable {
    public var name: String
    public var phase: VMPhase
    public var cpus: Int
    public var memoryMB: Int
    public var daemonToken: String
    public var createdAtUnix: Int64
    public var ttlSeconds: Int?
    public var message: String?

    public init(
        name: String,
        phase: VMPhase,
        cpus: Int,
        memoryMB: Int,
        daemonToken: String,
        createdAtUnix: Int64,
        ttlSeconds: Int?,
        message: String?
    ) {
        self.name = name
        self.phase = phase
        self.cpus = cpus
        self.memoryMB = memoryMB
        self.daemonToken = daemonToken
        self.createdAtUnix = createdAtUnix
        self.ttlSeconds = ttlSeconds
        self.message = message
    }
}

public struct DaemonIdentity: Codable, Equatable {
    public var token: String
    public var pid: Int32
    public var startedAtUnix: Int64

    public init(token: String, pid: Int32, startedAtUnix: Int64) {
        self.token = token
        self.pid = pid
        self.startedAtUnix = startedAtUnix
    }
}

public func vmIsExpired(_ record: VMRecord, now: Int64) -> Bool {
    guard let ttl = record.ttlSeconds, ttl > 0 else { return false }
    switch record.phase {
    case .booting, .running:
        return now >= record.createdAtUnix + Int64(ttl)
    case .stopping, .stopped, .failed:
        return false
    }
}

public func formatProcessTable(_ records: [VMRecord], now: Int64) -> String {
    let rows: [[String]] = [["NAME", "PHASE", "CPUS", "MEMORY_MB", "AGE", "MESSAGE"]] +
        records.sorted { $0.name < $1.name }.map { record in
            [
                record.name,
                record.phase.rawValue,
                String(record.cpus),
                String(record.memoryMB),
                formatAge(max(0, now - record.createdAtUnix)),
                record.message ?? "",
            ]
        }
    let widths = (0..<6).map { col in
        rows.map { $0[col].count }.max() ?? 0
    }
    return rows.map { row in
        row.enumerated().map { idx, cell in
            idx == row.count - 1 ? cell : cell.padding(toLength: widths[idx], withPad: " ", startingAt: 0)
        }.joined(separator: "  ")
    }.joined(separator: "\n") + "\n"
}

public final class StateStore {
    public let paths: MicroVMPaths
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(paths: MicroVMPaths) {
        self.paths = paths
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public func writeIdentity(_ identity: DaemonIdentity) throws {
        let data = try encoder.encode(identity)
        try data.write(to: paths.identity, options: .atomic)
    }

    public func save(_ record: VMRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: paths.vmDir(record.name), withIntermediateDirectories: true)
        let data = try encoder.encode(record)
        try data.write(to: paths.stateFile(record.name), options: .atomic)
    }

    public func load(_ name: String) throws -> VMRecord? {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked(name)
    }

    public func list() throws -> [VMRecord] {
        lock.lock()
        defer { lock.unlock() }
        let dir = paths.vms
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        var records: [VMRecord] = []
        for name in names {
            if let record = try loadUnlocked(name) {
                records.append(record)
            }
        }
        return records.sorted { $0.name < $1.name }
    }

    /// Marks VMs owned by a previous daemon as stopped. Returns how many changed.
    @discardableResult
    public func reap(currentToken: String) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let dir = paths.vms
        guard FileManager.default.fileExists(atPath: dir.path) else { return 0 }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        var changed = 0
        for name in names {
            guard var record = try loadUnlocked(name) else { continue }
            guard record.daemonToken != currentToken else { continue }
            guard let next = transition(record.phase, .reap), next != record.phase else { continue }
            record.phase = next
            record.message = "reaped leftover VM after daemon exit"
            let data = try encoder.encode(record)
            try data.write(to: paths.stateFile(name), options: .atomic)
            changed += 1
        }
        return changed
    }

    public func remove(_ name: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let dir = paths.vmDir(name)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    private func loadUnlocked(_ name: String) throws -> VMRecord? {
        let url = paths.stateFile(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(VMRecord.self, from: data)
    }
}
