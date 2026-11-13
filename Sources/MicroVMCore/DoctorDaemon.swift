import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public func probeDoctorDaemon(_ paths: MicroVMPaths) -> DoctorCheck {
    let recovery = "Check --home and \(paths.log.path); resolve the existing daemon owner or stale socket, "
        + "then run microvm daemon --home \(shellQuote(paths.home.path))."
    do {
        if !FileManager.default.fileExists(atPath: paths.socket.path) {
            if try doctorLockHeld(paths.lock.path) {
                return DoctorCheck("daemon", "error", "Daemon lock is held but no listener socket exists.", recovery: recovery)
            }
            return DoctorCheck("daemon", "ok", "Daemon is stopped; commands start it when they need it.")
        }
        let fd = try POSIX.connectUnix(paths.socket.path, timeoutSeconds: 1)
        defer { _ = closeFD(fd) }
        try POSIX.setWriteTimeout(fd, seconds: 1)
        try ControlCodec.write(fd, .ping)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        let header = try doctorRead(fd, count: 4, deadline: deadline)
        var cursor = Cursor(header)
        let size = Int(try cursor.u32())
        guard size > 0, size <= GuestProtocol.maxFrame else { throw MicroVMError("invalid daemon probe frame") }
        var frame = header
        frame.append(try doctorRead(fd, count: size, deadline: deadline))
        guard case .result(let data) = try ControlCodec.decode(frame),
              let capabilities = try? JSONDecoder().decode(PolicyCapabilities.self, from: data), capabilities.ok,
              capabilities.isolationPolicyVersion == IsolationPolicy.version, capabilities.taskVersion == 1,
              capabilities.taskManagementVersion == 1, capabilities.inspectionVersion == 1 else {
            return DoctorCheck("daemon", "error", "The running daemon is from an older microvm build and lacks required capabilities.",
                               recovery: "Rebuild microvm and manually restart the daemon with the matching binary.")
        }
        return DoctorCheck("daemon", "ok", "Daemon ping succeeded with the required capabilities.")
    } catch {
        return DoctorCheck("daemon", "error", "Daemon is unreachable, unresponsive, or has an invalid listener/lock.", recovery: recovery)
    }
}

/// Stops the daemon that holds this home's lock and clears its socket, so a matching daemon can start.
/// SIGTERM makes the daemon stop its sandboxes and exit; callers check for live sandboxes first.
public func stopDaemon(_ paths: MicroVMPaths, timeoutSeconds: Double = 15) throws {
    if try doctorLockHeld(paths.lock.path) {
        guard let data = try? Data(contentsOf: paths.identity),
              let identity = try? JSONDecoder().decode(DaemonIdentity.self, from: data), identity.pid > 1 else {
            throw MicroVMError(
                "a daemon holds \(paths.lock.path) but its process ID is unknown",
                recovery: "Stop it with `pkill -f 'microvm.*daemon'`, then run microvm doctor --fix again.")
        }
        if kill(identity.pid, SIGTERM) != 0 && errno != ESRCH {
            throw MicroVMError(
                "cannot stop daemon process \(identity.pid)", recovery: "Stop it with `kill \(identity.pid)`, then run microvm doctor --fix again.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        while try doctorLockHeld(paths.lock.path) {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw MicroVMError(
                    "daemon process \(identity.pid) did not exit within \(Int(timeoutSeconds))s",
                    recovery: "Stop it with `kill -9 \(identity.pid)`, then run microvm doctor --fix again.")
            }
            usleep(100_000)
        }
    }
    // No process holds the lock, so any socket left behind is stale.
    if unlink(paths.socket.path) != 0 && errno != ENOENT {
        throw MicroVMError("cannot remove stale socket \(paths.socket.path)", recovery: "Remove it, then run microvm doctor --fix again.")
    }
}

private func doctorLockHeld(_ path: String) throws -> Bool {
    guard FileManager.default.fileExists(atPath: path) else { return false }
    guard (try FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeRegular else {
        throw MicroVMError("daemon lock is not a regular file")
    }
    let fd = open(path, O_RDONLY | O_NONBLOCK)
    guard fd >= 0 else { throw MicroVMError("cannot inspect daemon lock") }
    defer { _ = closeFD(fd) }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 {
        POSIX.unlock(fd)
        return false
    }
    guard errno == EWOULDBLOCK || errno == EAGAIN else { throw MicroVMError("cannot check daemon owner") }
    return true
}

private func doctorRead(_ fd: Int32, count: Int, deadline: TimeInterval) throws -> Data {
    var data = Data()
    while data.count < count {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw MicroVMError("daemon reply deadline elapsed") }
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let result = poll(&descriptor, 1, Int32(max(1, remaining * 1000)))
        if result < 0 && errno == EINTR { continue }
        guard result > 0 else { throw MicroVMError("daemon reply deadline elapsed") }
        var buffer = [UInt8](repeating: 0, count: min(65536, count - data.count))
        let size = recv(fd, &buffer, buffer.count, 0)
        if size < 0 && errno == EINTR { continue }
        guard size > 0 else { throw MicroVMError("daemon closed the probe connection") }
        data.append(contentsOf: buffer.prefix(size))
    }
    return data
}
