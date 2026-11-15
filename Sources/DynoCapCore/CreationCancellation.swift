import Darwin
import Foundation

/// Cancellation for one creation. `stop` ends the client watch without discarding the sandbox.
final class CreationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var stopped = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    var shouldWatch: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cancelled && !stopped
    }
}

/// Watches one creation client until the peer disconnects or `stop` is requested.
final class CreationClientWatch: @unchecked Sendable {
    let cancellation = CreationCancellation()
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var started = false
    var created: TaskRecord?

    func start(_ fd: Int32) {
        lock.lock()
        if started {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()
        Thread.detachNewThread { [self] in
            watchCreationClient(fd, cancellation)
            done.signal()
        }
    }

    func stop() {
        cancellation.stop()
        lock.lock()
        let active = started
        lock.unlock()
        if active { done.wait() }
    }
}

func watchCreationClient(_ fd: Int32, _ cancellation: CreationCancellation) {
    while cancellation.shouldWatch {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
        let result = poll(&descriptor, 1, 100)
        if result < 0 {
            if errno == EINTR { continue }
            cancellation.cancel()
            return
        }
        guard result > 0 else { continue }
        let events = descriptor.revents
        if events & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
            cancellation.cancel()
            return
        }
        guard events & Int16(POLLIN) != 0 else { continue }
        var buffer = [UInt8](repeating: 0, count: 1)
        let size = recv(fd, &buffer, 1, Int32(MSG_PEEK | MSG_DONTWAIT))
        if size == 0 || (size < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
            cancellation.cancel()
            return
        }
    }
}

func rejectCreationCancellation(_ cancellation: CreationCancellation, stage: String, name: String?, id: String?) throws {
    guard cancellation.isCancelled else { return }
    let recovery: String
    if let id {
        let target = name ?? id
        recovery = "If sandbox \(target) (\(id)) remains, run `dynocap rm \(target) --force`. "
            + "Other sandboxes and retained results were not changed."
    } else {
        recovery = "No sandbox was admitted. Other sandboxes and retained results were not changed."
    }
    throw DynoCapError("creation cancelled during \(stage)", recovery: recovery)
}

func discardCancelledCreation(_ tasks: TaskManager, _ record: TaskRecord) throws -> Never {
    let target = record.name ?? record.id
    if !tasks.cleanupFailedStart(record.id) {
        throw DynoCapError(
            "creation cancelled and sandbox \(target) (\(record.id)) remains",
            recovery: "Run `dynocap rm \(target) --force` to discard it. "
                + "Other sandboxes and retained results were not removed.")
    }
    throw DynoCapError(
        "creation cancelled after the sandbox was ready",
        recovery: "The partial sandbox was removed. Other sandboxes and retained results were left in place.")
}
