import Foundation

/// Package-manager reuse driven by the runtime's declared cache spec; no package manager is named here.
enum DependencyCache {
    static let directoryName = "dependency-cache"
    struct Seed {
        var key: String
        var runtimeDigest: String
        var source: String?
    }
    /// The key covers the task's source, so a seed never crosses into another project with the same lockfile.
    static func key(baseline: URL, runtime: RuntimeArtifact, source: String?) throws -> String? {
        guard let spec = runtime.dependencyCache, !spec.lockfiles.isEmpty else { return nil }
        let fm = FileManager.default
        var inputs = ""
        for name in spec.lockfiles {
            let lock = baseline.appendingPathComponent(name)
            guard fm.fileExists(atPath: lock.path) else { return nil }
            inputs += try fileDigest(lock)
        }
        inputs += runtime.artifactDigest + runtime.arch + spec.registry
        inputs += "\u{0}source=" + (source ?? "")
        for name in spec.configFiles ?? [] {
            let config = baseline.appendingPathComponent(name)
            if fm.fileExists(atPath: config.path) { inputs += try fileDigest(config) }
        }
        return try dataDigest(Data(inputs.utf8))
    }
    static func spec(home: URL, runtimeDigest: String) -> DependencyCacheSpec? {
        let manifest = home.appendingPathComponent("runtimes/\(runtimeDigest)/runtime.json")
        return (try? JSONDecoder().decode(RuntimeArtifact.self, from: Data(contentsOf: manifest)))?.dependencyCache
    }
    static func restore(key: String, spec: DependencyCacheSpec, home: URL, id: String, execute: TaskManager.Execute) throws {
        let archive = home.appendingPathComponent("\(directoryName)/\(key).tar")
        guard FileManager.default.fileExists(atPath: archive.path) else { return }
        do {
            _ = try execute(id, ["/usr/local/bin/microvm-agent", "cache-unpack", spec.directory], [], archive, nil, 2 << 30)
            if let verify = spec.verifyCommand, !verify.isEmpty { _ = try execute(id, verify, [], nil, nil, 1 << 20) }
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: archive.path)
        } catch {
            try? FileManager.default.removeItem(at: archive)
            _ = try execute(id, ["rm", "-rf", spec.directory], [], nil, nil, 1 << 20)
        }
    }
    /// Only the runtime's install commands may publish a seed. Anything else the task runs, such as tests or a shell,
    /// is project code that could rewrite the cache, and commands that point the package manager at another registry
    /// or cache would publish the wrong one.
    static func compatibleCommand(argv: [String], env: [String], spec: DependencyCacheSpec) -> Bool {
        let argv = unwrappedShell(argv)
        guard (spec.seedCommands ?? []).contains(where: { !$0.isEmpty && argv.starts(with: $0) }) else { return false }
        let prefixes = (spec.incompatibleEnvPrefixes ?? []).map { $0.lowercased() }
        let substrings = (spec.incompatibleArgSubstrings ?? []).map { $0.lowercased() }
        return !env.contains { entry in prefixes.contains { entry.lowercased().hasPrefix($0) } }
            && !argv.contains { arg in substrings.contains { arg.lowercased().contains($0) } }
    }
    /// `sh -c "npm ci"` from the SDK's string form is the plain argv when the script is only words.
    /// Anything with shell syntax stays a shell command.
    static func unwrappedShell(_ argv: [String]) -> [String] {
        guard argv.count == 3, argv[0] == "sh" || argv[0] == "/bin/sh", argv[1] == "-c" else { return argv }
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-=/@:+,"))
        guard argv[2].unicodeScalars.allSatisfy({ $0.isASCII && plain.contains($0) }) else { return argv }
        return argv[2].split(separator: " ").map(String.init)
    }
    static func publish(seed: Seed, finalTree: URL, home: URL, id: String, execute: TaskManager.Execute) throws {
        let key = seed.key
        let runtimeDigest = seed.runtimeDigest
        let artifact = try JSONDecoder().decode(
            RuntimeArtifact.self, from: Data(contentsOf: home.appendingPathComponent("runtimes/\(runtimeDigest)/runtime.json")))
        guard let spec = artifact.dependencyCache, try self.key(baseline: finalTree, runtime: artifact, source: seed.source) == key
        else { return }
        let fm = FileManager.default
        let directory = home.appendingPathComponent(directoryName)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if let verify = spec.verifyCommand, !verify.isEmpty { _ = try execute(id, verify, [], nil, nil, 1 << 20) }
        let stage = directory.appendingPathComponent("\(key).partial")
        defer { try? fm.removeItem(at: stage) }
        _ = try execute(id, ["/usr/local/bin/microvm-agent", "cache-pack", spec.directory], [], nil, stage, 2 << 30)
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
