import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public final class Daemon {
    public let paths: MicroVMPaths
    public let backend: VMBackend
    public let guestArch: String
    private let store: StateStore
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var lockFD: Int32 = -1
    private var token = ""
    private var stopped = false
    private var nextExecID: UInt32 = 0
    private var ttlTimer: DispatchSourceTimer?

    public init(home: URL, backend: VMBackend, guestArch: String = HostArch.guest) {
        self.paths = MicroVMPaths(home: home)
        self.backend = backend
        self.guestArch = guestArch
        self.store = StateStore(paths: self.paths)
    }

    public func start() throws {
        try paths.ensure()
        lockFD = try POSIX.openLock(paths.lock.path)
        token = UUID().uuidString
        try store.writeIdentity(DaemonIdentity(token: token, pid: POSIX.pid, startedAtUnix: unixNow()))
        let reaped = try store.reap(currentToken: token)
        if reaped > 0 {
            log("reaped \(reaped) leftover VM\(reaped == 1 ? "" : "s")")
        }
        listenFD = try POSIX.listenUnix(paths.socket.path)
        signal(SIGPIPE, SIG_IGN)
        backend.onGuestExit = { [weak self] name, message in
            self?.noteGuestExit(name, message: message)
        }
        stopped = false
        let thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread.name = "microvm.accept"
        thread.start()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.reapExpired() }
        timer.resume()
        ttlTimer = timer
        log("daemon listening on \(paths.socket.path)")
    }

    public func stop() {
        lock.lock()
        stopped = true
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        ttlTimer?.cancel()
        ttlTimer = nil
        if fd >= 0 { _ = closeFD(fd) }
        unlink(paths.socket.path)
        if lockFD >= 0 {
            POSIX.unlock(lockFD)
            _ = closeFD(lockFD)
            lockFD = -1
        }
    }

    /// Blocks until SIGINT or SIGTERM, then stops every VM.
    public func runForever() -> Never {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        let queue = DispatchQueue(label: "microvm.signals")
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        let intr = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
        let stop: () -> Void = { [weak self] in
            self?.shutdownAll()
            exit(0)
        }
        term.setEventHandler(handler: stop)
        intr.setEventHandler(handler: stop)
        term.resume()
        intr.resume()
        dispatchMain()
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let fd = listenFD
            let shouldStop = stopped
            lock.unlock()
            if shouldStop || fd < 0 { return }
            let client = POSIX.accept(fd)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            Thread.detachNewThread { [weak self] in
                self?.handle(client)
            }
        }
    }

    private func handle(_ fd: Int32) {
        defer { _ = closeFD(fd) }
        do {
            let message = try ControlCodec.read(fd)
            switch message {
            case .ping:
                try ControlCodec.write(fd, .result(try JSONEncoder().encode(OKResult(ok: true))))
            case .ps:
                let records = try store.list()
                try ControlCodec.write(fd, .result(try JSONEncoder().encode(PSResult(vms: records))))
            case .run(let request):
                let record = try boot(request)
                try ControlCodec.write(fd, .result(try JSONEncoder().encode(StatusResult(name: record.name, phase: record.phase.rawValue))))
            case .exec(let command):
                try performExec(fd, command)
            case .destroy(let name):
                try destroyVM(name)
                try ControlCodec.write(fd, .result(try JSONEncoder().encode(OKResult(ok: true))))
            case .shutdown:
                try ControlCodec.write(fd, .result(try JSONEncoder().encode(OKResult(ok: true))))
                DispatchQueue.global().async { [weak self] in self?.stop() }
            case .result, .stdout, .stderr, .exit, .error:
                try ControlCodec.write(fd, .error("clients cannot send response frames"))
            }
        } catch {
            try? ControlCodec.write(fd, .error(String(describing: error)))
        }
    }

    private func boot(_ request: RunRequest) throws -> VMRecord {
        try validateVMName(request.name)
        guard request.cpus >= 1 else { throw MicroVMError("cpus must be >= 1") }
        guard request.memoryMB >= 128 else { throw MicroVMError("memory must be >= 128 MB") }
        if let existing = try store.load(request.name) {
            switch existing.phase {
            case .stopped, .failed:
                try store.remove(request.name)
            case .booting, .running, .stopping:
                throw MicroVMError("VM \(request.name) is \(existing.phase.rawValue). Run microvm destroy \(request.name) first.")
            }
        }
        let kernel = paths.kernel(guestArch)
        let initrd = paths.initrd(guestArch)
        guard FileManager.default.fileExists(atPath: kernel.path),
              FileManager.default.fileExists(atPath: initrd.path) else {
            throw MicroVMError("""
            Linux image not found for \(guestArch).
            From the microvm repo on this Mac, run ./scripts/fetch-image.sh
            Expected:
              \(kernel.path)
              \(initrd.path)
            """)
        }
        try FileManager.default.createDirectory(at: paths.vmDir(request.name), withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: paths.consoleLog(request.name).path, contents: nil)
        var record = VMRecord(
            name: request.name,
            phase: .booting,
            cpus: request.cpus,
            memoryMB: request.memoryMB,
            daemonToken: token,
            createdAtUnix: unixNow(),
            ttlSeconds: request.ttlSeconds,
            message: nil
        )
        try store.save(record)
        let boot = BootRequest(
            name: request.name,
            cpus: request.cpus,
            memoryMB: request.memoryMB,
            kernelURL: kernel,
            initrdURL: initrd,
            consoleLogURL: paths.consoleLog(request.name),
            bootTimeoutSeconds: request.bootTimeoutSeconds
        )
        let sem = DispatchSemaphore(value: 0)
        var result: Result<Void, Error>?
        backend.boot(boot) { value in
            result = value
            sem.signal()
        }
        let wait = sem.wait(timeout: .now() + .seconds(request.bootTimeoutSeconds + 5))
        if wait == .timedOut {
            backend.destroy(name: request.name) { _ in }
            record.phase = .failed
            record.message = "boot timed out"
            try store.save(record)
            throw MicroVMError("boot timed out waiting for \(request.name)")
        }
        switch result {
        case .success:
            guard let next = transition(record.phase, .agentReady) else {
                throw MicroVMError("internal phase error")
            }
            record.phase = next
            record.message = nil
            try store.save(record)
            log("\(request.name) running")
            return record
        case .failure(let error):
            record.phase = .failed
            record.message = String(describing: error)
            try store.save(record)
            throw MicroVMError(String(describing: error))
        case .none:
            throw MicroVMError("boot returned no result")
        }
    }

    private func performExec(_ fd: Int32, _ command: ExecCommand) throws {
        guard let record = try store.load(command.name) else {
            throw MicroVMError("no VM named \(command.name)")
        }
        guard record.phase == .running else {
            throw MicroVMError("VM \(command.name) is \(record.phase.rawValue)")
        }
        lock.lock()
        nextExecID &+= 1
        if nextExecID == 0 { nextExecID = 1 }
        let id = nextExecID
        lock.unlock()
        let request = ExecRequest(
            name: command.name,
            id: id,
            argv: command.argv,
            env: command.env,
            cwd: command.cwd,
            timeoutSeconds: command.timeoutSeconds
        )
        let writeLock = NSLock()
        let state = ExecWait()
        let sem = DispatchSemaphore(value: 0)
        func send(_ message: ControlMessage) {
            writeLock.lock()
            defer { writeLock.unlock() }
            try? ControlCodec.write(fd, message)
        }
        backend.exec(request) { event in
            switch event {
            case .stdout(let data):
                if !state.isFinished { send(.stdout(data)) }
            case .stderr(let data):
                if !state.isFinished { send(.stderr(data)) }
            case .finished(let code, let signal):
                if state.markFinished() {
                    send(.exit(code: code, signal: signal))
                    sem.signal()
                }
            case .failed(let message):
                if state.markFinished() {
                    send(.error(message))
                    sem.signal()
                }
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + .seconds(command.timeoutSeconds))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if state.markFinished() {
                self.backend.cancelExec(name: command.name, id: id)
                send(.error("timed out after \(command.timeoutSeconds)s"))
                sem.signal()
            }
        }
        timer.resume()
        sem.wait()
        timer.cancel()
    }

    private func destroyVM(_ name: String) throws {
        try validateVMName(name)
        guard let record = try store.load(name) else {
            throw MicroVMError("no VM named \(name)")
        }
        if record.phase == .running || record.phase == .booting || record.phase == .stopping {
            if let next = transition(record.phase, .stopRequested) {
                var stopping = record
                stopping.phase = next
                try store.save(stopping)
            }
            let sem = DispatchSemaphore(value: 0)
            var failure: Error?
            backend.destroy(name: name) { result in
                if case .failure(let error) = result { failure = error }
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 8)
            if let failure {
                throw MicroVMError("destroy \(name): \(failure)")
            }
        }
        try store.remove(name)
        log("destroyed \(name)")
    }

    private func noteGuestExit(_ name: String, message: String?) {
        guard var record = try? store.load(name) else { return }
        guard let next = transition(record.phase, message == nil ? .guestExited : .fault) else { return }
        if next == record.phase { return }
        record.phase = next
        record.message = message ?? record.message
        try? store.save(record)
        log("\(name) \(next.rawValue)")
    }

    private func reapExpired() {
        guard let records = try? store.list() else { return }
        let now = unixNow()
        for record in records where vmIsExpired(record, now: now) {
            log("ttl expired for \(record.name)")
            try? destroyVM(record.name)
        }
    }

    private func shutdownAll() {
        if let records = try? store.list() {
            for record in records where record.phase == .running || record.phase == .booting {
                try? destroyVM(record.name)
            }
        }
        stop()
    }

    private func log(_ message: String) {
        let line = "\(unixNow()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: paths.log.path),
           let handle = try? FileHandle(forWritingTo: paths.log) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: paths.log)
        }
        FileHandle.standardError.write(data)
    }
}

private final class ExecWait {
    private let lock = NSLock()
    private var finished = false

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func markFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        finished = true
        return true
    }
}

public struct DaemonClient {
    public var socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func ping() throws {
        let fd = try POSIX.connectUnix(socketPath)
        defer { _ = closeFD(fd) }
        try ControlCodec.write(fd, .ping)
        let reply = try ControlCodec.read(fd)
        guard case .result = reply else { throw messageError(reply) }
    }

    public func ps() throws -> [VMRecord] {
        let reply = try roundTrip(.ps)
        guard case .result(let data) = reply else { throw messageError(reply) }
        return try JSONDecoder().decode(PSResult.self, from: data).vms
    }

    public func run(_ request: RunRequest) throws -> StatusResult {
        let reply = try roundTrip(.run(request))
        guard case .result(let data) = reply else { throw messageError(reply) }
        return try JSONDecoder().decode(StatusResult.self, from: data)
    }

    public func destroy(_ name: String) throws {
        let reply = try roundTrip(.destroy(name))
        guard case .result = reply else { throw messageError(reply) }
    }

    public func exec(
        _ command: ExecCommand,
        onStdout: (Data) -> Void = { _ in },
        onStderr: (Data) -> Void = { _ in }
    ) throws -> ExecOutcome {
        let fd = try POSIX.connectUnix(socketPath)
        defer { _ = closeFD(fd) }
        try ControlCodec.write(fd, .exec(command))
        var stdout = Data()
        var stderr = Data()
        while true {
            let message = try ControlCodec.read(fd)
            switch message {
            case .stdout(let data):
                stdout.append(data)
                onStdout(data)
            case .stderr(let data):
                stderr.append(data)
                onStderr(data)
            case .exit(let code, let signal):
                return ExecOutcome(code: code, signal: signal, stdout: stdout, stderr: stderr)
            case .error(let text):
                let code: Int32 = text.contains("timed out") ? 124 : 1
                throw MicroVMError(text, exitCode: code)
            default:
                throw MicroVMError("unexpected exec reply")
            }
        }
    }

    private func roundTrip(_ message: ControlMessage) throws -> ControlMessage {
        let fd = try POSIX.connectUnix(socketPath)
        defer { _ = closeFD(fd) }
        try ControlCodec.write(fd, message)
        return try ControlCodec.read(fd)
    }

    private func messageError(_ message: ControlMessage) -> Error {
        if case .error(let text) = message {
            return MicroVMError(text)
        }
        return MicroVMError("unexpected daemon reply")
    }
}

func closeFD(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    return Darwin.close(fd)
    #else
    return Glibc.close(fd)
    #endif
}
