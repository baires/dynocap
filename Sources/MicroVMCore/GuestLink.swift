import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One vsock connection, owned as a blocking file descriptor.
public final class GuestLink {
    private let fd: Int32
    private let writeLock = NSLock()
    private var closed = false
    private let stateLock = NSLock()

    public init(fd: Int32) {
        self.fd = fd
    }

    deinit { close() }

    public func write(_ message: GuestMessage) throws {
        let bytes = try GuestProtocol.encodeFrame(message)
        writeLock.lock()
        defer { writeLock.unlock() }
        stateLock.lock()
        let isClosed = closed
        stateLock.unlock()
        if isClosed { throw MicroVMError("guest connection is closed") }
        try POSIX.writeAll(fd, bytes)
    }

    public func read() throws -> GuestMessage {
        let lenBytes = try POSIX.readFull(fd, 4)
        var cursor = Cursor(lenBytes)
        let n = Int(try cursor.u32())
        guard n > 0, n <= GuestProtocol.maxFrame else { throw MicroVMError("guest frame exceeds limit") }
        let payload = try POSIX.readFull(fd, n)
        return try GuestProtocol.decode(payload)
    }

    public func readLoop(_ handler: @escaping (Result<GuestMessage, Error>) -> Void) {
        Thread.detachNewThread { [weak self] in
            guard let self = self else { return }
            while true {
                do {
                    let message = try self.read()
                    handler(.success(message))
                } catch {
                    handler(.failure(error))
                    return
                }
            }
        }
    }

    public func close() {
        stateLock.lock()
        let shouldClose = !closed
        closed = true
        stateLock.unlock()
        if shouldClose {
            _ = shutdown(fd, Int32(SHUT_RDWR))
            _ = DarwinClose(fd)
        }
    }
}

/// Orders writes on one guest connection. The exec frame is queued and the caller
/// returns immediately; later stdin, signals, and resize wait behind it.
public final class GuestWriteOrder: @unchecked Sendable {
    private let queue: DispatchQueue

    public init(label: String) {
        queue = DispatchQueue(label: label)
    }

    public func async(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }

    public func sync(_ work: () throws -> Void) rethrows {
        try queue.sync(execute: work)
    }
}

private func DarwinClose(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    return Darwin.close(fd)
    #else
    return Glibc.close(fd)
    #endif
}
