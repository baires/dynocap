import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

public struct RuntimePreparation: Equatable {
    public var repo: String
    public var runtimes: [RuntimeSelection]
}

public struct RuntimeSelection: Codable, Equatable {
    public var name: String
    public var version: String
    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

/// Resolves supported selections; task execution treats the result as an opaque disk artifact.
public struct RuntimeArtifact: Codable {
    public var runtimes: [RuntimeSelection]
    public var arch: String
    public var baseImageDigest: String
    public var artifactDigest: String
    public var tools: [String: String]
    public var environment: [String: String]
    public var formatVersion: Int
    public var verificationCommand: [String]

    public static func selectionKey(_ requested: [RuntimeSelection], arch: String) -> String {
        arch + "/" + requested.map { $0.name + "@" + $0.version }.sorted().joined(separator: "+")
    }
    public static func directory(_ requested: [RuntimeSelection]?, home: URL, arch: String) throws -> URL {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("runtime-catalog.json")),
            let catalog = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            throw MicroVMError("no prepared runtime; run microvm runtime prepare REPO --runtime node:22")
        }
        let key = selectionKey(requested ?? defaultRuntimes, arch: arch)
        guard let digest = catalog[key], digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else {
            throw MicroVMError("unsupported or unprepared runtimes: \(key); prepare matching artifacts; no version substitution")
        }
        return home.appendingPathComponent("runtimes").appendingPathComponent(digest)
    }

    public static func resolve(_ requested: [RuntimeSelection]?, directory: URL, arch: String) throws -> RuntimeArtifact {
        let artifact = try JSONDecoder().decode(
            RuntimeArtifact.self, from: Data(contentsOf: directory.appendingPathComponent("runtime.json")))
        guard artifact.formatVersion == 1, artifact.arch == arch,
            artifact.runtimes == (requested ?? defaultRuntimes)
        else {
            throw MicroVMError("unsupported runtimes or architecture; prepare a matching artifact; no version substitution is performed")
        }
        return artifact
    }

    public static let defaultRuntimes = [RuntimeSelection(name: "node", version: "22")]
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
    else { throw MicroVMError("SHA-256 computation failed") }
    return String(digest)
}
#endif

/// Small host companion operations. Project trees are always treated as data.
enum HostTree {
    static func run(_ name: String, _ args: [String], input: URL? = nil, output: URL? = nil) throws -> Data {
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent(name)
        let process = Process()
        process.executableURL = binary
        process.arguments = args
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
        try process.run()
        let data = output == nil ? result.fileHandleForReading.readDataToEndOfFile() : Data()
        let error = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MicroVMError("\(name): \((String(data: error, encoding: .utf8) ?? "<non-UTF8 error>"))")
        }
        return data
    }
}
