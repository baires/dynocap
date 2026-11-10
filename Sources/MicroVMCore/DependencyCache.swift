import Foundation

/// npm-specific reuse stays outside task execution and runtime resolution.
enum DependencyCache {
    struct Seed {
        var key: String
        var runtimeDigest: String
    }
    static func key(baseline: URL, runtime: RuntimeArtifact) throws -> String? {
        guard runtime.runtimes.contains(where: { $0.name == "node" }) else { return nil }
        let lock = baseline.appendingPathComponent("package-lock.json")
        guard FileManager.default.fileExists(atPath: lock.path) else { return nil }
        var inputs = try fileDigest(lock) + runtime.artifactDigest + runtime.arch + "https://registry.npmjs.org/"
        let config = baseline.appendingPathComponent(".npmrc")
        if FileManager.default.fileExists(atPath: config.path) { inputs += try fileDigest(config) }
        return try dataDigest(Data(inputs.utf8))
    }
    static func restore(key: String, home: URL, id: String, execute: TaskManager.Execute) throws {
        let archive = home.appendingPathComponent("npm-cache/\(key).tar")
        guard FileManager.default.fileExists(atPath: archive.path) else { return }
        do {
            _ = try execute(id, ["/usr/local/bin/microvm-agent", "cache-unpack", "/work/npm-cache/_cacache"], [], archive, nil, 2 << 30)
            _ = try execute(id, ["npm", "cache", "verify", "--cache", "/work/npm-cache"], [], nil, nil, 1 << 20)
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: archive.path)
        } catch {
            try? FileManager.default.removeItem(at: archive)
            _ = try execute(id, ["sh", "-c", "rm -rf /work/npm-cache/_cacache"], [], nil, nil, 1 << 20)
        }
    }
    static func compatibleCommand(argv: [String], env: [String]) -> Bool {
        !env.contains { $0.lowercased().hasPrefix("npm_config_") } && !argv.contains { $0.lowercased().contains("registry") }
    }
    static func publish(seed: Seed, finalTree: URL, home: URL, id: String, execute: TaskManager.Execute) throws {
        let key = seed.key
        let runtimeDigest = seed.runtimeDigest
        let artifact = try JSONDecoder().decode(
            RuntimeArtifact.self, from: Data(contentsOf: home.appendingPathComponent("runtimes/\(runtimeDigest)/runtime.json")))
        guard try self.key(baseline: finalTree, runtime: artifact) == key else { return }
        let fm = FileManager.default
        let directory = home.appendingPathComponent("npm-cache")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try execute(id, ["npm", "cache", "verify", "--cache", "/work/npm-cache"], [], nil, nil, 1 << 20)
        let stage = directory.appendingPathComponent("\(key).partial")
        defer { try? fm.removeItem(at: stage) }
        _ = try execute(id, ["/usr/local/bin/microvm-agent", "cache-pack", "/work/npm-cache/_cacache"], [], nil, stage, 2 << 30)
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]).filter {
            $0.pathExtension == "tar"
        }.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        func size(_ file: URL) -> Int64 { ((try? fm.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value ?? 0 }
        var used = files.reduce(size(stage)) { $0 + size($1) }
        for file in files where used > 2 << 30 {
            used -= size(file)
            try fm.removeItem(at: file)
        }
        let dest = directory.appendingPathComponent("\(key).tar")
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: stage, to: dest)
    }
}
