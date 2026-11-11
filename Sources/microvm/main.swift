import Foundation
import MicroVMCore
import MicroVMVZ

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main
struct Main {
    static func main() {
        do {
            let invocation = try parseCommand(CommandLine.arguments)
            do {
                try dispatch(invocation, CommandLine.arguments)
            } catch {
                fail(error, verbose: invocation.verbose)
            }
        } catch {
            fail(error, verbose: invocationRequestsVerbose(CommandLine.arguments))
        }
    }

    static func fail(_ error: Error, verbose: Bool) -> Never {
        let micro = error as? MicroVMError
        let message = micro?.message ?? String(describing: error)
        let code = micro?.exitCode ?? 1
        fputs("microvm: \(message)\n", stderr)
        if verbose {
            fputs("microvm: exit \(code)\n", stderr)
        }
        exit(code)
    }

    static func dispatch(_ invocation: CLIInvocation, _ args: [String]) throws {
        switch invocation.command {
        case .ls:
            let paths = try ready(invocation)
            let data = try DaemonClient(socketPath: paths.socket.path).task(TaskCommand(op: "entries"))
            if invocation.output == .json {
                print(String(data: data, encoding: .utf8) ?? "")
            } else {
                let entries = try JSONDecoder().decode([ManagedEntry].self, from: data)
                print("NAME\tID\tKIND\tPHASE\tRUNTIME\tNETWORK\tEXPIRES\tRESULT")
                for entry in entries {
                    print(
                        [
                            entry.name ?? "-", entry.id, entry.kind, entry.phase, entry.runtime,
                            entry.network?.rawValue ?? "unknown", entry.expiresAtUnix.map(String.init) ?? "-",
                            entry.resultDirectory ?? "-",
                        ].joined(separator: "\t"))
                }
            }
        case .managed(let command):
            let paths = try ready(invocation)
            let client = DaemonClient(socketPath: paths.socket.path)
            try client.requireTaskManagement()
            let data = try client.task(command)
            if command.op == "diff" {
                let preview = try JSONDecoder().decode(TaskPreview.self, from: data)
                let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: preview.patchPath))
                defer { try? file.close() }
                while let chunk = try file.read(upToCount: 64 << 10), !chunk.isEmpty {
                    try FileHandle.standardOutput.write(contentsOf: chunk)
                }
            } else if command.op == "remove" {
                print("removed \(command.id ?? "")")
            } else {
                print(String(data: data, encoding: .utf8) ?? "")
            }
        case .runtimePrepare(let preparation):
            let paths = try ready(invocation)
            try DaemonClient(socketPath: paths.socket.path).requireTasks()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: args[0]).standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
                .appendingPathComponent("microvm-mkruntime")
            process.arguments = [
                preparation.repo, paths.home.path, HostArch.guest,
                String(data: try JSONEncoder().encode(preparation.runtimes), encoding: .utf8) ?? "",
            ]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw MicroVMError("runtime preparation failed") }
            var verification = TaskCommand(op: "runtimeVerify")
            verification.runtimes = preparation.runtimes
            let data = try DaemonClient(socketPath: paths.socket.path).task(verification)
            print(String(data: data, encoding: .utf8) ?? "")
        case .task(let command):
            let paths = try ready(invocation)
            let client = DaemonClient(socketPath: paths.socket.path)
            if command.op == "exec", let id = command.id, let argv = command.argv {
                let result = try client.exec(
                    ExecCommand(name: id, argv: argv, env: [], cwd: "/workspace", timeoutSeconds: 300),
                    onStdout: { try? FileHandle.standardOutput.write(contentsOf: $0) },
                    onStderr: { try? FileHandle.standardError.write(contentsOf: $0) })
                exit(result.signal > 0 ? 128 + result.signal : result.code)
            }
            print(String(data: try client.task(command), encoding: .utf8) ?? "")
        case .help(let topic):
            print(commandHelp(topic))
        case .version:
            print(MicroVMInfo.describe(), terminator: "")
        case .daemon:
            if ProcessInfo.processInfo.environment["MICROVM_DETACH"] == "1" {
                _ = setsid()
            }
            let paths = resolve(invocation)
            let daemon = Daemon(home: paths.home, backend: makeBackend())
            try daemon.start()
            daemon.runForever()
        case .ps:
            let paths = try ready(invocation)
            let records = try DaemonClient(socketPath: paths.socket.path).ps()
            print(formatProcessTable(records, now: unixNow()), terminator: "")
        case .run(let request):
            let paths = try ready(invocation)
            let status = try DaemonClient(socketPath: paths.socket.path).run(request)
            print("\(status.name) \(status.phase)")
        case .exec(let command):
            let paths = try ready(invocation)
            let outcome = try DaemonClient(socketPath: paths.socket.path).exec(
                command,
                onStdout: { try? FileHandle.standardOutput.write(contentsOf: $0) },
                onStderr: { try? FileHandle.standardError.write(contentsOf: $0) }
            )
            let status: Int32 = outcome.signal > 0 ? 128 + outcome.signal : outcome.code
            exit(status)
        case .destroy(let name):
            let paths = try ready(invocation)
            try DaemonClient(socketPath: paths.socket.path).destroy(name)
            print("destroyed \(name)")
        }
    }

    static func resolve(_ invocation: CLIInvocation) -> MicroVMPaths {
        if let home = invocation.home {
            return MicroVMPaths(home: home)
        }
        return MicroVMPaths.resolve(override: nil)
    }

    static func ready(_ invocation: CLIInvocation) throws -> MicroVMPaths {
        let paths = resolve(invocation)
        try paths.ensure()
        try ensureDaemon(paths: paths, home: invocation.home)
        return paths
    }

    static func ensureDaemon(paths: MicroVMPaths, home: URL?) throws {
        let client = DaemonClient(socketPath: paths.socket.path)
        if (try? client.ping()) != nil { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        if let home {
            proc.arguments = ["--home", home.path, "daemon"]
        } else if let envHome = ProcessInfo.processInfo.environment["MICROVM_HOME"], !envHome.isEmpty {
            proc.arguments = ["--home", envHome, "daemon"]
        } else {
            proc.arguments = ["daemon"]
        }
        var env = ProcessInfo.processInfo.environment
        env["MICROVM_DETACH"] = "1"
        proc.environment = env
        if !FileManager.default.fileExists(atPath: paths.log.path) {
            _ = FileManager.default.createFile(atPath: paths.log.path, contents: nil)
        }
        if let log = FileHandle(forWritingAtPath: paths.log.path) {
            _ = try? log.seekToEnd()
            proc.standardOutput = log
            proc.standardError = log
        }
        proc.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        try proc.run()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if (try? client.ping()) != nil { return }
            usleep(50_000)
        }
        throw MicroVMError("daemon did not become ready; see \(paths.log.path)")
    }

    static func makeBackend() -> VMBackend {
        #if os(macOS)
        return VirtualizationBackend()
        #else
        return UnsupportedBackend()
        #endif
    }
}
