import XCTest

#if canImport(Darwin)
import Darwin
#endif

@testable import DynoCapCore

/// A daemon may close an exec connection as soon as the guest exits, while the CLI is still
/// writing stdin or EOF. That write must fail with EPIPE, not kill the CLI with SIGPIPE.
final class ClientSocketTests: XCTestCase {
    #if os(macOS)
    func testClientSocketsDoNotRaiseSIGPIPE() throws {
        let path = "/tmp/dynocap-sigpipe-\(UUID().uuidString).sock"
        let listener = try POSIX.listenUnix(path)
        defer {
            _ = closeFD(listener)
            unlink(path)
        }
        let fd = try POSIX.connectUnix(path)
        defer { _ = closeFD(fd) }
        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        XCTAssertEqual(getsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, &length), 0)
        XCTAssertEqual(value, 1)
        let peer = POSIX.accept(listener)
        XCTAssertGreaterThanOrEqual(peer, 0)
        _ = closeFD(peer)
        // The first write may be buffered; a later one reports the closed peer as an error.
        XCTAssertThrowsError(try (0..<64).forEach { _ in try ControlCodec.write(fd, .stdinEOF) })
    }

    func testCLISurvivesADaemonThatClosesRightAfterExit() throws {
        let home = URL(fileURLWithPath: "/tmp/dynocap-sigpipe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try DynoCapPaths(home: home).ensure()
        let socket = home.appendingPathComponent("daemon.sock").path
        let listener = try POSIX.listenUnix(socket)
        let stopped = DispatchSemaphore(value: 0)
        // The CLI holds its exec connection open while it pings on others, so each connection gets a thread.
        Thread.detachNewThread {
            defer { stopped.signal() }
            while true {
                let client = POSIX.accept(listener)
                if client < 0 { return }
                Thread.detachNewThread {
                    defer { _ = closeFD(client) }
                    switch try? ControlCodec.read(client) {
                    case .ping:
                        try? ControlCodec.write(client, .result(JSONEncoder().encode(PolicyCapabilities())))
                    case .exec:
                        // Answer at once and close before reading the client's stdin frames.
                        try? ControlCodec.write(client, .exit(code: 3, signal: 0))
                    case .shutdown:
                        _ = closeFD(listener)
                    default:
                        break
                    }
                }
            }
        }
        defer {
            if let fd = try? POSIX.connectUnix(socket) {
                try? ControlCodec.write(fd, .shutdown)
                _ = closeFD(fd)
            }
            _ = stopped.wait(timeout: .now() + 5)
        }
        var statuses: [Int32: Int] = [:]
        for _ in 0..<150 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DYNOCAP_BIN"] ?? ".build/debug/dynocap")
            process.arguments = ["--home", home.path, "exec", "demo", "--", "true"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(10)
            while process.isRunning && Date() < deadline { usleep(5_000) }
            if process.isRunning {
                process.terminate()
                return XCTFail("the CLI hung")
            }
            let key = process.terminationReason == .uncaughtSignal ? -process.terminationStatus : process.terminationStatus
            statuses[key, default: 0] += 1
        }
        XCTAssertEqual(statuses, [3: 150], "negative keys are signals that killed the CLI")
    }
    #endif
}
