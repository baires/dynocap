import Foundation

public struct DynoCapPaths {
    public var home: URL

    public init(home: URL) {
        self.home = home
    }

    public static func resolve(override: String?) -> DynoCapPaths {
        if let override, !override.isEmpty {
            return DynoCapPaths(home: URL(fileURLWithPath: override))
        }
        if let env = ProcessInfo.processInfo.environment["DYNOCAP_HOME"], !env.isEmpty {
            return DynoCapPaths(home: URL(fileURLWithPath: env))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return DynoCapPaths(home: home.appendingPathComponent(".dynocap", isDirectory: true))
    }

    public var socket: URL { home.appendingPathComponent("daemon.sock") }
    public var lock: URL { home.appendingPathComponent("daemon.lock") }
    public var identity: URL { home.appendingPathComponent("daemon.json") }
    public var log: URL { home.appendingPathComponent("daemon.log") }
    public var vms: URL { home.appendingPathComponent("vms", isDirectory: true) }
    public var cache: URL { home.appendingPathComponent("cache", isDirectory: true) }

    public func imageDir(_ arch: String) -> URL {
        home.appendingPathComponent("images", isDirectory: true).appendingPathComponent(arch, isDirectory: true)
    }

    public func kernel(_ arch: String) -> URL { imageDir(arch).appendingPathComponent("kernel") }
    public func initrd(_ arch: String) -> URL { imageDir(arch).appendingPathComponent("initrd") }

    public func vmDir(_ name: String) -> URL { vms.appendingPathComponent(name, isDirectory: true) }
    public func stateFile(_ name: String) -> URL { vmDir(name).appendingPathComponent("state.json") }
    public func consoleLog(_ name: String) -> URL { vmDir(name).appendingPathComponent("console.log") }

    public func ensure() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: vms, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
    }
}
