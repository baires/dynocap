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
    private var lifecycles: [String: SandboxLifecycle] = [:]
    private var ttlTimer: DispatchSourceTimer?
    private lazy var tasks = TaskManager(
        paths: paths, arch: guestArch, boot: { try self.boot($0) },
        execute: { try self.executeInternal($0, $1, env: $2, input: $3, output: $4, limit: $5) }, destroy: { try self.destroyVM($0) })

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
        try tasks.recover()
        listenFD = try POSIX.listenUnix(paths.socket.path)
        signal(SIGPIPE, SIG_IGN)
        backend.onGuestExit = { [weak self] name, generation, message in
            DispatchQueue.global().async { self?.noteGuestExit(name, generation: generation, message: message) }
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
        let creationWatch = CreationClientWatch()
        defer { creationWatch.stop() }
        do {
            let message = try ControlCodec.read(fd)
            switch message {
            case .task(let command):
                if command.op != "start", let requested = command.network, let id = command.id,
                    let recorded = tasks.recordedNetwork(id) {
                    try NetworkModeLock.rejectChange(from: recorded, to: requested)
                }
                let data: Data
                switch command.op {
                case "start":
                    if let message = NetworkAdmission.rejection(
                        network: command.network ?? NetworkMode.none, requireOffline: command.requireOffline == true,
                        permitFiltered: command.permitFiltered, offlineMessage: "task requires offline networking"
                    ) {
                        throw MicroVMError(message)
                    }
                    creationWatch.start(fd)
                    let record = try tasks.start(command, cancellation: creationWatch.cancellation) { stage in
                        if command.reportProgress == true {
                            try? ControlCodec.write(fd, .stderr(Data((stage.rawValue + "\n").utf8)))
                        }
                    }
                    if creationWatch.cancellation.isCancelled {
                        try discardCancelledCreation(tasks, record)
                    }
                    creationWatch.created = record
                    data = try JSONEncoder().encode(TaskDescriptor(record, sandbox: store.load(record.id)))
                case "finish":
                    guard let id = command.id else { throw MicroVMError("task id required") }
                    if let requested = command.network, let recorded = tasks.recordedNetwork(id) {
                        try NetworkModeLock.rejectChange(from: recorded, to: requested)
                    }
                    data = try JSONEncoder().encode(
                        TaskDescriptor(
                            tasks.finish(
                                tasks.resolve(id).id, requireOffline: command.requireOffline == true, permitFiltered: command.permitFiltered
                            )))
                case "diff":
                    guard let target = command.id else { throw MicroVMError("task name or id required") }
                    data = try JSONEncoder().encode(tasks.preview(tasks.resolve(target).id,
                        requireOffline: command.requireOffline == true, permitFiltered: command.permitFiltered))
                case "list": data = try JSONEncoder().encode(tasks.records().map { TaskDescriptor($0) })
                case "resolve":
                    guard let target = command.id else { throw MicroVMError("task name or id required") }
                    data = try JSONEncoder().encode(TaskDescriptor(tasks.resolve(target)))
                case "entries": data = try JSONEncoder().encode(managedEntries())
                case "logs":
                    guard let target = command.id else { throw MicroVMError("sandbox name or id required") }
                    data = try JSONEncoder().encode(tasks.executionLogs(target))
                case "inspect":
                    guard let target = command.id else { throw MicroVMError("sandbox name or id required") }
                    data = try JSONEncoder().encode(tasks.inspect(target, sandboxes: store.list()))
                case "remove":
                    guard let target = command.id else { throw MicroVMError("name or id required") }
                    try removeManaged(target, purge: command.purge == true, force: command.force == true)
                    data = Data("{}".utf8)
                case "runtimeVerify": data = try JSONEncoder().encode(tasks.verifyRuntime(command.runtimes))
                default: throw MicroVMError("unknown task operation")
                }
                if let record = creationWatch.created, creationWatch.cancellation.isCancelled {
                    creationWatch.created = nil
                    try discardCancelledCreation(tasks, record)
                }
                do {
                    try ControlCodec.write(fd, .result(data))
                } catch {
                    if let record = creationWatch.created {
                        creationWatch.created = nil
                        let target = record.name ?? record.id
                        if !tasks.cleanupFailedStart(record.id) {
                            throw MicroVMError(
                                "creation result was not delivered and sandbox \(target) (\(record.id)) remains",
                                recovery: "Run `microvm rm \(target) --force` to discard it. "
                                    + "Other sandboxes and retained results were not removed.")
                        }
                        throw MicroVMError(
                            "creation result was not delivered",
                            recovery: "The partial sandbox was removed. Other sandboxes and retained results were left in place.")
                    }
                    throw error
                }
                creationWatch.created = nil
            case .transfer(let command):
                try transfer(command)
                try ControlCodec.write(fd, .result(try JSONEncoder().encode(OKResult(ok: true))))
            case .ping:
                try ControlCodec.write(fd, .result(try JSONEncoder().encode(PolicyCapabilities())))
            case .ps:
                let records = try store.list()
                try ControlCodec.write(fd, .result(try JSONEncoder().encode(PSResult(vms: records))))
            case .run(let request):
                let record = try boot(request)
                let status = StatusResult(
                    name: record.name, phase: record.phase.rawValue,
                    network: record.network, ttlSeconds: record.ttlSeconds)
                try ControlCodec.write(fd, .result(try JSONEncoder().encode(status)))
            case .exec(let command):
                try performExec(fd, command)
            case .destroy(let name):
                if let record = try tasks.records().first(where: { $0.id == name || $0.name == name }),
                    TaskManager.discardsUnexportedWork(record.phase) {
                    let target = record.name ?? name
                    throw MicroVMError(
                        "refusing to destroy live sandbox \(target)",
                        code: .invalidPhase,
                        recovery: "Run `microvm finish \(target)` to export work, or `microvm rm \(target) --force` to discard it.")
                }
                try destroyVM(name)
                try ControlCodec.write(fd, .result(try JSONEncoder().encode(OKResult(ok: true))))
            case .shutdown:
                try ControlCodec.write(fd, .result(try JSONEncoder().encode(OKResult(ok: true))))
                DispatchQueue.global().async { [weak self] in self?.stop() }
            case .result, .stdout, .stderr, .exit, .error, .stdin, .stdinEOF:
                try ControlCodec.write(fd, .error(daemonErrorText(MicroVMError("clients cannot send response frames"))))
            }
        } catch {
            try? ControlCodec.write(fd, .error(daemonErrorText(error)))
        }
    }

    private func lifecycle(_ name: String) -> SandboxLifecycle {
        lock.lock()
        defer { lock.unlock() }
        if let existing = lifecycles[name] { return existing }
        let lifecycle = SandboxLifecycle()
        lifecycles[name] = lifecycle
        return lifecycle
    }

    private func managedEntries() throws -> [ManagedEntry] {
        let records = try tasks.records()
        let sandboxes = try store.list()
        let byID = Dictionary(uniqueKeysWithValues: sandboxes.map { ($0.name, $0) })
        let ids = Set(records.map(\.id))
        let projects = records.map { record in
            ManagedEntry(
                id: record.id, name: record.name, kind: "task", phase: record.phase,
                runtime: record.runtimes?.map { $0.name + ":" + $0.version }.joined(separator: "+") ?? record.runtimeDigest,
                network: record.network,
                expiresAtUnix: byID[record.id].flatMap { vm in
                    guard vm.phase == .booting || vm.phase == .running || vm.phase == .stopping else { return nil as Int64? }
                    return vm.ttlSeconds.map { vm.createdAtUnix + Int64($0) }
                } ?? record.expiresAtUnix,
                resultDirectory: record.resultDirectory,
                sandboxExpiresAtUnix: byID[record.id].flatMap { vm in
                    guard vm.phase == .booting || vm.phase == .running || vm.phase == .stopping else { return nil as Int64? }
                    return vm.ttlSeconds.map { vm.createdAtUnix + Int64($0) }
                },
                resultExpiresAtUnix: record.expiresAtUnix)
        }
        let raw = sandboxes.filter { !ids.contains($0.name) }.map { record in
            ManagedEntry(
                id: record.name, name: record.name, kind: "sandbox", phase: record.phase.rawValue,
                runtime: "minimal", network: record.network,
                expiresAtUnix: record.ttlSeconds.map { record.createdAtUnix + Int64($0) },
                sandboxExpiresAtUnix: [.booting, .running, .stopping].contains(record.phase)
                    ? record.ttlSeconds.map { record.createdAtUnix + Int64($0) } : nil)
        }
        return (projects + raw).sorted { ($0.name ?? $0.id) < ($1.name ?? $1.id) }
    }

    private func removeManaged(_ target: String, purge: Bool, force: Bool) throws {
        if let record = try tasks.records().first(where: { $0.id == target || $0.name == target }) {
            try tasks.remove(record.id, purge: purge, force: force)
            try store.remove(record.id)
        } else {
            try validateVMName(target)
            guard let sandbox = try store.load(target) else { throw MicroVMError("sandbox or task not found: \(target)", code: .notFound) }
            if [VMPhase.booting, .running, .stopping].contains(sandbox.phase), !force {
                throw MicroVMError(
                    "refusing to remove live sandbox \(target)",
                    code: .invalidPhase,
                    recovery: "This raw sandbox has no project result to finish. Run `microvm rm \(target) --force` to discard it.")
            }
            tasks.namespace.lock()
            defer { tasks.namespace.unlock() }
            let lifecycle = lifecycle(target)
            lifecycle.lock.lock()
            defer { lifecycle.lock.unlock() }
            try destroyLocked(target, lifecycle: lifecycle, reason: "sandbox removed")
            try store.remove(target)
        }
    }

    private func boot(_ request: RunRequest) throws -> VMRecord {
        let ttl = try IsolationPolicy.ttl(request.ttlSeconds)
        guard (1...86400).contains(request.bootTimeoutSeconds) else {
            throw MicroVMError("bootTimeoutSeconds must be between 1 and 86400")
        }
        tasks.namespace.lock()
        var namespaceLocked = true
        defer { if namespaceLocked { tasks.namespace.unlock() } }
        if request.runtimeDirectory == nil { try tasks.checkRawName(request.name) }
        if request.name.hasPrefix("task-") { try tasks.ensureStarting(request.name) }
        let lifecycle = lifecycle(request.name)
        lifecycle.lock.lock()
        // Release while waiting for the guest, allowing expiry and explicit destroy during boot.
        var locked = true
        defer { if locked { lifecycle.lock.unlock() } }
        try validateVMName(request.name)
        guard request.cpus >= 1 else { throw MicroVMError("cpus must be >= 1") }
        guard request.memoryMB >= 128 else { throw MicroVMError("memory must be >= 128 MB") }
        if let existing = try store.load(request.name) {
            let requested = request.network ?? NetworkMode.none
            if let recorded = existing.network, recorded != requested,
                existing.phase == .booting || existing.phase == .running || existing.phase == .stopping {
                throw MicroVMError("network mode is fixed at start")
            }
            switch existing.phase {
            case .stopped, .failed:
                try store.remove(request.name)
            case .booting, .running, .stopping:
                throw MicroVMError("VM \(request.name) is \(existing.phase.rawValue). Run microvm destroy \(request.name) first.")
            }
        }
        let kernel = request.runtimeDirectory.map { URL(fileURLWithPath: $0).appendingPathComponent("kernel") } ?? paths.kernel(guestArch)
        let initrd = request.runtimeDirectory.map { URL(fileURLWithPath: $0).appendingPathComponent("initrd") } ?? paths.initrd(guestArch)
        guard FileManager.default.fileExists(atPath: kernel.path),
            FileManager.default.fileExists(atPath: initrd.path)
        else {
            throw MicroVMError(
                """
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
            ttlSeconds: ttl,
            message: nil,
            network: request.network ?? NetworkMode.none
        )
        try store.save(record)
        tasks.namespace.unlock()
        namespaceLocked = false
        let live = LiveSandbox()
        lifecycle.live = live
        let boot = BootRequest(
            name: request.name,
            cpus: request.cpus,
            memoryMB: request.memoryMB,
            kernelURL: kernel,
            initrdURL: initrd,
            consoleLogURL: paths.consoleLog(request.name),
            bootTimeoutSeconds: request.bootTimeoutSeconds,
            network: request.network ?? NetworkMode.none,
            generation: live.generation,
            runtimeDirectory: request.runtimeDirectory.map { URL(fileURLWithPath: $0) },
            workspaceDisk: request.workspaceDisk.map { URL(fileURLWithPath: $0) },
            filteredRepositoryHost: request.filteredRepositoryHost
        )
        backend.boot(boot) { live.boot.complete($0) }
        lifecycle.lock.unlock()
        locked = false
        let result = live.boot.wait(seconds: request.bootTimeoutSeconds + 5)
        lifecycle.lock.lock()
        locked = true
        guard lifecycle.live === live, let current = try store.load(request.name), current.phase == .booting else {
            throw MicroVMError("sandbox \(request.name) stopped or expired during boot")
        }
        if vmIsExpired(current, now: unixNow()) {
            try destroyLocked(request.name, lifecycle: lifecycle, reason: "sandbox lifetime expired")
            throw MicroVMError("sandbox lifetime expired during boot")
        }
        switch result {
        case .success:
            record.phase = .running
            record.message = nil
            try store.save(record)
            log("\(request.name) running")
            return record
        case .failure(let error):
            try destroyLocked(request.name, lifecycle: lifecycle, reason: String(describing: error), keepFailure: true)
            throw error
        }
    }

    private func performExec(_ fd: Int32, _ command: ExecCommand) throws {
        var command = command
        if let input = command.input, !["none", "pipe", "interactive"].contains(input) {
            throw MicroVMError("unsupported exec input \(input)")
        }
        if let task = try tasks.records().first(where: { $0.id == command.name || $0.name == command.name }) {
            command.name = task.id
            if command.cwd.isEmpty { command.cwd = "/workspace" }
        } else if command.cwd.isEmpty {
            command.cwd = "/"
        }
        try POSIX.setWriteTimeout(fd, seconds: 5)
        let taskIndex: Int?
        do { taskIndex = try tasks.begin(command.name, argv: command.argv, env: command.env) } catch {
            if String(describing: error).contains("limit") { DispatchQueue.global().async { try? self.destroyVM(command.name) } }
            throw error
        }
        var taskCode: Int32?
        var taskError: String?
        defer { tasks.end(command.name, index: taskIndex, code: taskCode, error: taskError) }
        let lifecycle = lifecycle(command.name)
        lifecycle.lock.lock()
        var locked = true
        defer { if locked { lifecycle.lock.unlock() } }
        guard let record = try store.load(command.name) else {
            throw MicroVMError("sandbox not found: \(command.name)", code: .notFound)
        }
        guard record.phase == .running else {
            throw MicroVMError("sandbox \(command.name) is \(record.phase.rawValue)", code: .invalidPhase)
        }
        if vmIsExpired(record, now: unixNow()) {
            try destroyLocked(command.name, lifecycle: lifecycle, reason: "sandbox lifetime expired")
            throw MicroVMError("sandbox \(command.name) lifetime expired", code: .invalidPhase)
        }
        if let message = NetworkAdmission.rejection(
            network: record.network, requireOffline: command.requireOffline == true,
            permitFiltered: command.permitFiltered,
            offlineMessage: "exec requires an offline sandbox; networking is NAT or unknown"
        ) {
            throw MicroVMError(message)
        }
        guard let live = lifecycle.live else { throw MicroVMError("sandbox \(command.name) is not owned by this daemon", code: .invalidPhase) }
        lock.lock()
        nextExecID &+= 1
        if nextExecID == 0 { nextExecID = 1 }
        let id = nextExecID
        lock.unlock()
        var request = ExecRequest(
            name: command.name,
            id: id,
            argv: command.argv,
            env: command.env,
            cwd: command.cwd,
            timeoutSeconds: command.timeoutSeconds
        )
        request.streamStdin = command.input == "pipe" || command.input == "interactive"
        let writeLock = NSLock()
        let state = ExecWait()
        let sem = DispatchSemaphore(value: 0)
        var transportFailed = false  // Protected by writeLock, including terminal writes.
        func send(_ message: ControlMessage, terminal: Bool = false) {
            writeLock.lock()
            defer { writeLock.unlock() }
            guard !transportFailed, terminal || !state.isFinished else { return }
            do {
                try ControlCodec.write(fd, message)
            } catch {
                // A partial frame cannot be followed by another frame. Disconnect and
                // release guest I/O so an unread client cannot obstruct VM shutdown.
                transportFailed = true
                _ = shutdown(fd, Int32(SHUT_RDWR))
                if state.markFinished() {
                    DispatchQueue.global().async {
                        lifecycle.lock.lock()
                        if lifecycle.live === live { self.backend.cancelExec(name: command.name, id: id) }
                        lifecycle.lock.unlock()
                    }
                    sem.signal()
                }
            }
        }
        live.execs[id] = { reason in
            if state.markFinished() {
                // A caller that stops reading output must not prevent host teardown.
                DispatchQueue.global().async {
                    send(.error(daemonErrorText(MicroVMError(reason))), terminal: true)
                    _ = shutdown(fd, Int32(SHUT_RD))
                    sem.signal()
                }
            }
        }
        backend.exec(request) { event in
            switch event {
            case .stdout(let data):
                if !state.isFinished {
                    do {
                        try self.tasks.append(command.name, index: taskIndex, data: data, stderr: false)
                        send(.stdout(data))
                    } catch {
                        taskError = String(describing: error)
                        self.backend.cancelExec(name: command.name, id: id)
                        if state.markFinished() {
                            send(.error(daemonErrorText(MicroVMError(taskError!))), terminal: true)
                            _ = shutdown(fd, Int32(SHUT_RD))
                            sem.signal()
                        }
                        DispatchQueue.global().async { try? self.destroyVM(command.name) }
                    }
                }
            case .stderr(let data):
                if !state.isFinished {
                    do {
                        try self.tasks.append(command.name, index: taskIndex, data: data, stderr: true)
                        send(.stderr(data))
                    } catch {
                        taskError = String(describing: error)
                        self.backend.cancelExec(name: command.name, id: id)
                        if state.markFinished() {
                            send(.error(daemonErrorText(MicroVMError(taskError!))), terminal: true)
                            _ = shutdown(fd, Int32(SHUT_RD))
                            sem.signal()
                        }
                        DispatchQueue.global().async { try? self.destroyVM(command.name) }
                    }
                }
            case .finished(let code, let signal):
                if state.markFinished() {
                    taskCode = signal > 0 ? 128 + signal : code
                    send(.exit(code: code, signal: signal), terminal: true)
                    _ = shutdown(fd, Int32(SHUT_RD))
                    sem.signal()
                }
            case .failed(let message):
                if state.markFinished() {
                    taskError = message
                    send(.error(daemonErrorText(MicroVMError(message))), terminal: true)
                    _ = shutdown(fd, Int32(SHUT_RD))
                    sem.signal()
                }
            }
        }
        lifecycle.lock.unlock()
        locked = false
        if request.streamStdin && !state.isFinished {
            Thread.detachNewThread { [weak self] in
                self?.pumpExecInput(fd: fd, name: command.name, id: id, state: state, sem: sem)
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + .seconds(command.timeoutSeconds))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if state.markFinished() {
                lifecycle.lock.lock()
                if lifecycle.live === live { self.backend.cancelExec(name: command.name, id: id) }
                lifecycle.lock.unlock()
                taskCode = 124
                taskError = "exec in \(command.name) timed out after \(command.timeoutSeconds)s"
                send(.error(daemonErrorText(MicroVMError(taskError!, exitCode: 124, code: .commandTimeout))), terminal: true)
                _ = shutdown(fd, Int32(SHUT_RD))
                sem.signal()
            }
        }
        timer.resume()
        sem.wait()
        timer.cancel()
        lifecycle.lock.lock()
        live.execs[id] = nil
        lifecycle.lock.unlock()
    }


    /// Reads client stdin until EOF, disconnect, or the exec finishing.
    /// The command deadline waits on another thread, so this read cannot block TTL or timeout.
    private func pumpExecInput(fd: Int32, name: String, id: UInt32, state: ExecWait, sem: DispatchSemaphore) {
        while !state.isFinished {
            let message: ControlMessage
            do {
                message = try ControlCodec.read(fd)
            } catch {
                stopExecInput(name: name, id: id, state: state, sem: sem)
                return
            }
            if state.isFinished { return }
            do {
                switch message {
                case .stdin(let data):
                    var offset = 0
                    while offset < data.count {
                        let end = min(offset + GuestProtocol.maxChunk, data.count)
                        try backend.writeStdin(name: name, id: id, data: data.subdata(in: offset..<end))
                        offset = end
                    }
                case .stdinEOF:
                    try backend.closeStdin(name: name, id: id)
                    return
                default:
                    stopExecInput(name: name, id: id, state: state, sem: sem)
                    return
                }
            } catch {
                stopExecInput(name: name, id: id, state: state, sem: sem)
                return
            }
        }
    }

    private func stopExecInput(name: String, id: UInt32, state: ExecWait, sem: DispatchSemaphore) {
        if state.markFinished() {
            backend.cancelExec(name: name, id: id)
            sem.signal()
        }
    }

    private func destroyVM(_ name: String) throws {
        try validateVMName(name)
        let lifecycle = lifecycle(name)
        lifecycle.lock.lock()
        defer { lifecycle.lock.unlock() }
        try destroyLocked(name, lifecycle: lifecycle, reason: "sandbox destroyed")
    }

    // Caller owns the per-name lock. Backend callbacks must not synchronously acquire it.
    private func destroyLocked(
        _ name: String, lifecycle: SandboxLifecycle, reason: String, keepFailure: Bool = false
    ) throws {
        guard var record = try store.load(name) else { return }
        if let live = lifecycle.live {
            let reason = live.stopReason ?? reason
            live.stopReason = reason
            record.phase = .stopping
            record.message = reason
            try store.save(record)
            live.boot.complete(.failure(MicroVMError(reason)))
            for cancel in live.execs.values { cancel(reason) }
            live.execs.removeAll()
            let completion = CompletionWait()
            backend.destroy(name: name) { completion.complete($0) }
            do {
                try completion.wait(seconds: 8).get()
            } catch {
                record.message = "\(reason); teardown failed: \(error)"
                try store.save(record)
                log("\(name) \(record.message ?? reason)")
                throw MicroVMError(record.message ?? reason)
            }
            lifecycle.live = nil
        }
        if keepFailure {
            record.phase = .failed
            record.message = reason
            try store.save(record)
        } else {
            try store.remove(name)
        }
        tasks.stopped(name, reason: reason)
        log("destroyed \(name): \(reason)")
    }

    func noteGuestExit(_ name: String, generation: UUID, message: String?) {
        let lifecycle = lifecycle(name)
        lifecycle.lock.lock()
        defer { lifecycle.lock.unlock() }
        guard let live = lifecycle.live, live.generation == generation,
            var record = try? store.load(name)
        else { return }
        // Explicit teardown owns this transition and retries until confirmed.
        guard record.phase != .stopping else { return }
        live.boot.complete(.failure(MicroVMError(message ?? "guest exited")))
        for cancel in live.execs.values { cancel(message ?? "guest exited") }
        lifecycle.live = nil
        record.phase = message == nil ? .stopped : .failed
        record.message = message
        tasks.stopped(name, reason: message ?? "guest exited")
        try? store.save(record)
        log("\(name) \(record.phase.rawValue)")
    }

    private func reapExpired() {
        tasks.sweepExpired()
        guard let records = try? store.list() else { return }
        for record in records {
            let lifecycle = lifecycle(record.name)
            lifecycle.lock.lock()
            defer { lifecycle.lock.unlock() }
            guard let current = try? store.load(record.name),
                current.phase == .stopping || vmIsExpired(current, now: unixNow())
            else { continue }
            do {
                try destroyLocked(record.name, lifecycle: lifecycle, reason: current.message ?? "sandbox lifetime expired")
            } catch {
                log("teardown will retry for \(record.name): \(error)")
            }
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

    private func executeInternal(
        _ name: String, _ argv: [String], env: [String] = [], input: URL? = nil, output: URL? = nil, limit: Int64,
        requireOffline: Bool = false
    ) throws -> Data {
        let lifecycle = lifecycle(name)
        lifecycle.lock.lock()
        var locked = true
        defer { if locked { lifecycle.lock.unlock() } }
        guard let record = try store.load(name), record.phase == .running, !vmIsExpired(record, now: unixNow()), let live = lifecycle.live
        else {
            throw MicroVMError("sandbox is stopped or expired")
        }
        if requireOffline && record.network != NetworkMode.none { throw MicroVMError("transfer requires an offline sandbox") }
        lock.lock()
        nextExecID &+= 1
        let id = nextExecID
        lock.unlock()
        let timeout = Int(min(300, max(1, (record.createdAtUnix + Int64(record.ttlSeconds ?? 1800)) - unixNow())))
        var request = ExecRequest(name: name, id: id, argv: argv, env: env, cwd: "/", timeoutSeconds: timeout)
        request.stdinFile = input
        let state = NSLock()
        let sem = DispatchSemaphore(value: 0)
        var data = Data()
        var problem: String?
        var done = false
        var bytes: Int64 = 0
        var file: FileHandle?
        if let output {
            FileManager.default.createFile(atPath: output.path, contents: nil)
            file = try FileHandle(forWritingTo: output)
        }
        defer { try? file?.close() }
        func fail(_ message: String) {
            state.lock()
            if !done {
                done = true
                problem = message
                sem.signal()
            }
            state.unlock()
        }
        live.execs[id] = { fail($0) }
        backend.exec(request) { event in
            state.lock()
            defer { state.unlock() }
            guard !done else { return }
            switch event {
            case .stdout(let chunk):
                bytes += Int64(chunk.count)
                if bytes > limit {
                    problem = "transfer/output exceeds byte limit"
                    done = true
                    sem.signal()
                    self.backend.cancelExec(name: name, id: id)
                } else {
                    do { if let file { try file.write(contentsOf: chunk) } else { data.append(chunk) } } catch {
                        problem = String(describing: error)
                        done = true
                        sem.signal()
                    }
                }
            case .stderr(let chunk):
                if (problem?.utf8.count ?? 0) < 8192 {
                    problem = (problem ?? "") + (String(data: chunk, encoding: .utf8) ?? "<non-UTF8 error>")
                }
            case .finished(let code, let signal):
                if code == 0 && signal == 0 {
                    problem = nil
                } else {
                    problem = "command failed (\(code), signal \(signal)): " + (problem ?? "")
                }
                done = true
                sem.signal()
            case .failed(let message):
                problem = message
                done = true
                sem.signal()
            }
        }
        lifecycle.lock.unlock()
        locked = false
        if sem.wait(timeout: .now() + .seconds(timeout + 2)) == .timedOut {
            fail("internal command timed out")
            backend.cancelExec(name: name, id: id)
        }
        lifecycle.lock.lock()
        live.execs[id] = nil
        lifecycle.lock.unlock()
        state.lock()
        defer { state.unlock() }
        let secrets = env.compactMap { entry -> String? in
            guard let eq = entry.firstIndex(of: "="), eq != entry.startIndex else { return nil }
            let value = String(entry[entry.index(after: eq)...])
            return value.count >= 4 ? value : nil
        }
        if let problem { throw MicroVMError(redactSecrets(problem, secrets: secrets)) }
        guard !secrets.isEmpty, var text = String(data: data, encoding: .utf8) else { return data }
        text = redactSecrets(text, secrets: secrets)
        return Data(text.utf8)
    }

    private func transfer(_ command: TransferCommand) throws {
        if command.requireOffline == true {
            guard let record = try store.load(command.name), record.network == NetworkMode.none else {
                throw MicroVMError("transfer requires an offline sandbox")
            }
        }
        let index = try tasks.begin(command.name, argv: ["transfer", command.direction, command.guestPath])
        defer { tasks.end(command.name, index: index, code: 0, error: nil) }
        let temp = paths.cache.appendingPathComponent("transfer-" + UUID().uuidString + ".tar")
        try FileManager.default.createDirectory(at: paths.cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        if command.direction == "upload" {
            _ = try HostTree.run("microvm-workspace", ["pack", command.localPath, "project"], output: temp)
            _ = try executeInternal(
                command.name, ["/usr/local/bin/microvm-agent", "unpack", command.guestPath], input: temp, output: nil, limit: 256 << 20,
                requireOffline: command.requireOffline == true)
        } else if command.direction == "download" {
            _ = try executeInternal(
                command.name, ["/usr/local/bin/microvm-agent", "pack", command.guestPath], input: nil, output: temp, limit: 256 << 20,
                requireOffline: command.requireOffline == true)
            _ = try HostTree.run("microvm-workspace", ["unpack", command.localPath], input: temp)
        } else {
            throw MicroVMError("transfer direction must be upload or download")
        }
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

    public func requireTasks() throws {
        let reply = try roundTrip(.ping)
        guard case .result(let data) = reply,
            let capability = try? JSONDecoder().decode(PolicyCapabilities.self, from: data), capability.taskVersion == 1
        else {
            throw MicroVMError("daemon lacks task v1; rebuild and manually restart the daemon before creating tasks", code: .incompatibleDaemon)
        }
    }
    public func requireTaskManagement() throws {
        let reply = try roundTrip(.ping)
        guard case .result(let data) = reply,
              let capabilities = try? JSONDecoder().decode(PolicyCapabilities.self, from: data),
              capabilities.taskManagementVersion == 1 else {
            throw MicroVMError("daemon lacks task management v1; rebuild and restart it", code: .incompatibleDaemon)
        }
    }
    public func task(_ command: TaskCommand, onProgress: ((String) -> Void)? = nil) throws -> Data {
        try requireTasks()
        if command.name != nil || ["list", "resolve", "entries", "remove", "diff", "inspect", "logs"].contains(command.op) {
            try requireTaskManagement()
        }
        if command.op == "inspect" {
            let reply = try roundTrip(.ping)
            guard case .result(let data) = reply,
                  let capabilities = try? JSONDecoder().decode(PolicyCapabilities.self, from: data), capabilities.inspectionVersion == 1 else {
                throw MicroVMError("daemon lacks inspection v1", code: .incompatibleDaemon)
            }
        }
        if command.op == "logs" {
            let reply = try roundTrip(.ping)
            guard case .result(let data) = reply,
                  let capabilities = try? JSONDecoder().decode(PolicyCapabilities.self, from: data), capabilities.executionLogsVersion == 1 else {
                throw MicroVMError("daemon lacks execution logs v1", code: .incompatibleDaemon)
            }
        }
        var request = command
        request.reportProgress = onProgress != nil
        let fd = try connect()
        defer { _ = closeFD(fd) }
        try ControlCodec.write(fd, .task(request))
        while true {
            let reply = try ControlCodec.read(fd)
            switch reply {
            case .result(let data): return data
            case .stderr(let data) where onProgress != nil:
                if let text = String(data: data, encoding: .utf8),
                   let stage = CreationStage(rawValue: text.trimmingCharacters(in: .newlines)) {
                    onProgress?(stage.rawValue)
                }
            default: throw messageError(reply)
            }
        }
    }

    public func ping() throws {
        let fd = try connect()
        defer { _ = closeFD(fd) }
        try ControlCodec.write(fd, .ping)
        let reply = try ControlCodec.read(fd)
        guard case .result = reply else { throw messageError(reply) }
    }

    public func requirePolicy() throws {
        let reply = try roundTrip(.ping)
        guard case .result(let data) = reply,
            let capability = try? JSONDecoder().decode(PolicyCapabilities.self, from: data),
            capability.ok, capability.isolationPolicyVersion == IsolationPolicy.version
        else {
            throw MicroVMError(
                "daemon lacks isolation policy v1; rebuild microvm and manually restart the daemon before creating sandboxes", code: .incompatibleDaemon)
        }
    }

    public func ps() throws -> [VMRecord] {
        let reply = try roundTrip(.ps)
        guard case .result(let data) = reply else { throw messageError(reply) }
        return try JSONDecoder().decode(PSResult.self, from: data).vms
    }

    public func run(_ request: RunRequest) throws -> StatusResult {
        _ = try IsolationPolicy.ttl(request.ttlSeconds)
        try requirePolicy()
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
        readStdin: ((ExecStdinControl) -> Data?)? = nil,
        onStdout: (Data) -> Void = { _ in },
        onStderr: (Data) -> Void = { _ in }
    ) throws -> ExecOutcome {
        if command.requireOffline == true { try requirePolicy() }
        let streaming = command.input == "pipe" || command.input == "interactive"
        if streaming { try requireExecStream() }
        let fd = try connect()
        let writerDone = DispatchSemaphore(value: 0)
        var control: ExecStdinControl?
        var writerStarted = false
        defer {
            control?.stop()
            if writerStarted { writerDone.wait() }
            _ = closeFD(fd)
        }
        try ControlCodec.write(fd, .exec(command))
        if streaming, let readStdin {
            let gate = ExecStdinControl()
            control = gate
            writerStarted = true
            Thread.detachNewThread {
                defer { writerDone.signal() }
                writeExecStdin(fd: fd, control: gate, read: readStdin)
            }
        } else {
            writerStarted = true
            writerDone.signal()
        }
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
                throw daemonError(text)
            default:
                throw MicroVMError("unexpected exec reply")
            }
        }
    }

    private func requireExecStream() throws {
        let reply = try roundTrip(.ping)
        guard case .result(let data) = reply else { throw messageError(reply) }
        try validateExecStreamCapability(data)
    }

    private func connect() throws -> Int32 {
        do { return try POSIX.connectUnix(socketPath) } catch {
            throw MicroVMError("cannot connect to daemon at \(socketPath)", code: .daemonUnavailable)
        }
    }

    private func roundTrip(_ message: ControlMessage) throws -> ControlMessage {
        let fd = try connect()
        defer { _ = closeFD(fd) }
        try ControlCodec.write(fd, message)
        return try ControlCodec.read(fd)
    }

    private func messageError(_ message: ControlMessage) -> Error {
        if case .error(let text) = message {
            return daemonError(text)
        }
        return MicroVMError("unexpected daemon reply")
    }
}


private func writeExecStdin(fd: Int32, control: ExecStdinControl, read: (ExecStdinControl) -> Data?) {
    let chunkSize = 32 * 1024
    do {
        while !control.isStopped {
            guard let chunk = read(control), !chunk.isEmpty else {
                if !control.isStopped {
                    try ControlCodec.write(fd, .stdinEOF)
                }
                return
            }
            var offset = 0
            while offset < chunk.count {
                if control.isStopped { return }
                let end = min(offset + chunkSize, chunk.count)
                try ControlCodec.write(fd, .stdin(chunk.subdata(in: offset..<end)))
                offset = end
            }
        }
    } catch {
        return
    }
}

func closeFD(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    return Darwin.close(fd)
    #else
    return Glibc.close(fd)
    #endif
}

private final class SandboxLifecycle {
    let lock = NSRecursiveLock()
    var live: LiveSandbox?
}

private final class LiveSandbox {
    let generation = UUID()
    let boot = CompletionWait()
    var stopReason: String?
    var execs: [UInt32: (String) -> Void] = [:]
}

private final class CompletionWait {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<Void, Error>?

    func complete(_ result: Result<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard self.result == nil else { return }
        self.result = result
        semaphore.signal()
    }

    func wait(seconds: Int) -> Result<Void, Error> {
        if semaphore.wait(timeout: .now() + .seconds(seconds)) == .timedOut {
            return .failure(MicroVMError("timed out waiting for backend operation"))
        }
        lock.lock()
        defer { lock.unlock() }
        return result ?? .failure(MicroVMError("backend returned no result"))
    }
}
