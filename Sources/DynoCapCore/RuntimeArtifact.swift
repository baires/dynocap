import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct RuntimePreparation: Equatable {
    public var repo: String
    public var runtimes: [RuntimeSelection]
    public init(repo: String, runtimes: [RuntimeSelection]) {
        self.repo = repo
        self.runtimes = runtimes
    }
}

public struct RuntimeSelection: Codable, Equatable {
    public var name: String
    public var version: String
    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

/// How a runtime's package manager cache is keyed, restored, verified and published.
/// The runtime manifest declares it; the host knows no package manager by name.
public struct DependencyCacheSpec: Codable, Equatable {
    public var lockfiles: [String]
    public var configFiles: [String]?
    public var directory: String
    public var registry: String
    public var verifyCommand: [String]?
    public var incompatibleEnvPrefixes: [String]?
    public var incompatibleArgSubstrings: [String]?
    /// Argv prefixes that may publish a seed. Missing means none may: a runtime prepared before this field never seeds.
    public var seedCommands: [[String]]?
}

/// Resolves supported selections; task execution treats the result as an opaque disk artifact.
public struct RuntimeArtifact: Codable {
    public static let currentFormatVersion = 3
    public var runtimes: [RuntimeSelection]
    public var arch: String
    public var baseImageDigest: String
    public var artifactDigest: String
    public var tools: [String: String]
    public var environment: [String: String]
    public var formatVersion: Int
    public var verificationCommand: [String]
    /// Registry hosts filtered egress may reach, besides a task repository host.
    public var egressHosts: [String]?
    public var dependencyCache: DependencyCacheSpec?

    public static func selectionKey(_ requested: [RuntimeSelection], arch: String) -> String {
        arch + "/" + requested.map { $0.name + "@" + $0.version }.sorted().joined(separator: "+")
    }
    public static func preparationInstruction(_ requested: [RuntimeSelection]?) -> String {
        let flags = (requested ?? defaultRuntimes).map { " --runtime " + shellWord($0.name + ":" + $0.version) }.joined()
        return "Run dynocap doctor --fix" + flags + " with the same --home (or dynocap runtime prepare ." + flags
            + " in the dynocap checkout), then retry."
    }

    /// Every selection the runtime catalog (guest/internal/runtime/catalog.go) can prepare, as NAME:VERSION.
    public static let supportedSelections = ["node:24", "node:22", "python:3.14", "go:1.27", "shell:1"]

    static func unpreparedError(_ requested: [RuntimeSelection]?) -> DynoCapError {
        let selections = (requested ?? defaultRuntimes).map { $0.name + ":" + $0.version }
        if let unknown = selections.first(where: { !supportedSelections.contains($0) }) {
            return DynoCapError(
                "runtime \(unknown) is not supported; versions are never substituted",
                recovery: "Choose one of \(supportedSelections.joined(separator: ", ")) with --runtime.")
        }
        return DynoCapError("runtime \(selections.joined(separator: ", ")) is not prepared yet", recovery: preparationInstruction(requested))
    }

    /// Selections this home has prepared for an architecture, as NAME:VERSION, in catalog order.
    public static func preparedSelections(home: URL, arch: String) -> [String] {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("runtime-catalog.json")),
              let catalog = try? JSONDecoder().decode([String: String].self, from: data) else { return [] }
        return catalog.keys.filter { $0.hasPrefix(arch + "/") }.map { String($0.dropFirst(arch.count + 1)).replacingOccurrences(of: "@", with: ":") }
            .sorted { (supportedSelections.firstIndex(of: $0) ?? .max, $0) < (supportedSelections.firstIndex(of: $1) ?? .max, $1) }
    }

    public static func directory(_ requested: [RuntimeSelection]?, home: URL, arch: String) throws -> URL {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("runtime-catalog.json")),
            let catalog = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            throw unpreparedError(requested)
        }
        let key = selectionKey(requested ?? defaultRuntimes, arch: arch)
        guard let digest = catalog[key], digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else {
            throw unpreparedError(requested)
        }
        return home.appendingPathComponent("runtimes").appendingPathComponent(digest)
    }

    public static func resolve(_ requested: [RuntimeSelection]?, directory: URL, arch: String) throws -> RuntimeArtifact {
        let artifact: RuntimeArtifact
        do {
            artifact = try JSONDecoder().decode(
                RuntimeArtifact.self, from: Data(contentsOf: directory.appendingPathComponent("runtime.json")))
        } catch {
            throw DynoCapError("prepared runtime manifest is missing or invalid", recovery: preparationInstruction(requested))
        }
        guard artifact.formatVersion == currentFormatVersion else {
            throw DynoCapError("runtime artifact is outdated", recovery: preparationInstruction(requested))
        }
        guard artifact.arch == arch,
            artifact.runtimes == (requested ?? defaultRuntimes)
        else {
            throw DynoCapError(
                "unsupported runtimes or architecture; no version substitution is performed", recovery: preparationInstruction(requested))
        }
        return artifact
    }

    static func verifyFiles(_ artifact: RuntimeArtifact, directory: URL, recordIdentity: Bool = true) throws {
        let disk = directory.appendingPathComponent("runtime.ext4")
        // The disk is hundreds of megabytes. Hash it when its size, inode, or mtime
        // differs from the last match. The home directory owner can already replace
        // both the disk and this stamp; the stamp only skips a repeated read.
        // Doctor stays read-only, so it verifies without writing the stamp.
        let stampURL = directory.appendingPathComponent("runtime.ext4.identity")
        let identity = runtimeDiskIdentity(disk)
        let cached = try? JSONDecoder().decode(RuntimeDiskIdentity.self, from: Data(contentsOf: stampURL))
        let unchanged = identity.map { id in
            cached?.digest == artifact.artifactDigest && cached?.size == id.size
                && cached?.mtimeNanoseconds == id.mtimeNanoseconds && cached?.inode == id.inode
        } ?? false
        if !unchanged {
            guard let digest = try? fileDigest(disk), digest == artifact.artifactDigest else {
                throw DynoCapError(
                    "prepared runtime disk is missing or has a hash mismatch", recovery: preparationInstruction(artifact.runtimes))
            }
            if recordIdentity, let identity {
                let stamp = RuntimeDiskIdentity(
                    digest: digest, size: identity.size, mtimeNanoseconds: identity.mtimeNanoseconds, inode: identity.inode)
                try? JSONEncoder().encode(stamp).write(to: stampURL, options: .atomic)
            }
        }
        let bootImagesPresent = ["kernel", "initrd"].allSatisfy { name in
            let file = directory.appendingPathComponent(name)
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            return values?.isRegularFile == true && (values?.fileSize ?? 0) > 0
        }
        guard bootImagesPresent else {
            throw DynoCapError("prepared runtime boot images are missing", recovery: preparationInstruction(artifact.runtimes))
        }
    }

    /// bash, git and ssh with no language: what a sandbox gets when nothing names a runtime.
    public static let defaultRuntimes = [RuntimeSelection(name: "shell", version: "1")]
}

private struct RuntimeDiskIdentity: Codable, Equatable {
    var digest: String
    var size: Int64
    var mtimeNanoseconds: Int64
    var inode: UInt64
}

private struct DiskFileIdentity {
    var size: Int64
    var mtimeNanoseconds: Int64
    var inode: UInt64
}

private func runtimeDiskIdentity(_ url: URL) -> DiskFileIdentity? {
    var info = stat()
    guard stat(url.path, &info) == 0 else { return nil }
    #if canImport(Darwin)
    let mtime = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
    #else
    let mtime = Int64(info.st_mtim.tv_sec) * 1_000_000_000 + Int64(info.st_mtim.tv_nsec)
    #endif
    return DiskFileIdentity(size: Int64(info.st_size), mtimeNanoseconds: mtime, inode: UInt64(info.st_ino))
}

func fileDigest(_ url: URL) throws -> String {
    #if canImport(CryptoKit)
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var hash = SHA256()
    while let data = try file.read(upToCount: 1 << 20), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
    #else
    return try portableDigest(file: url, data: nil)
    #endif
}

func dataDigest(_ data: Data) throws -> String {
    #if canImport(CryptoKit)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    #else
    return try portableDigest(file: nil, data: data)
    #endif
}

#if !canImport(CryptoKit)
// Linux control-plane tests use coreutils; the macOS task path uses CryptoKit.
private func portableDigest(file: URL?, data: Data?) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sha256sum")
    process.standardError = FileHandle.nullDevice
    let output = Pipe()
    let input = Pipe()
    process.standardOutput = output
    if let file { process.arguments = [file.path] } else { process.standardInput = input }
    try process.run()
    if let data {
        try input.fileHandleForWriting.write(contentsOf: data)
        try input.fileHandleForWriting.close()
    }
    let result = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0, let text = String(data: result, encoding: .utf8), let digest = text.split(separator: " ").first,
        digest.count == 64
    else { throw DynoCapError("SHA-256 computation failed") }
    return String(digest)
}
#endif

/// Small host companion operations. Project trees are always treated as data.
enum HostTree {
    static func run(
        _ name: String, _ args: [String], input: URL? = nil, output: URL? = nil, environment: [String: String]? = nil
    ) throws -> Data {
        let binary = CLIExecutable.resolve(argument: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent(name)
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        if let environment { process.environment = environment }
        let errors = Pipe()
        process.standardError = errors
        let result = Pipe()
        var files: [FileHandle] = []
        defer { for file in files { try? file.close() } }
        if let input {
            let file = try FileHandle(forReadingFrom: input)
            files.append(file)
            process.standardInput = file
        }
        if let output {
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let file = try FileHandle(forWritingTo: output)
            files.append(file)
            process.standardOutput = file
        } else {
            process.standardOutput = result
        }
        // waitUntilExit polls this thread's run loop and slept about 65 ms after one exit in four.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let data = output == nil ? result.fileHandleForReading.readDataToEndOfFile() : Data()
        let error = errors.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        guard process.terminationStatus == 0 else {
            throw DynoCapError("\(name): \((String(data: error, encoding: .utf8) ?? "<non-UTF8 error>"))")
        }
        return data
    }
}
