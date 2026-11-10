#if os(macOS)
import Darwin
import Foundation
import MicroVMCore
import Virtualization

/// Boots a Linux guest with VZLinuxBootLoader and talks to the in-guest agent
/// over VZVirtioSocketDevice. Compiled only on macOS; this file is not
/// type-checked on Linux.
public final class VirtualizationBackend: VMBackend {
    public var onGuestExit: ((String, UUID, String?) -> Void)?
    private let lock = NSLock()
    private var machines: [String: LinuxVM] = [:]

    public init() {}

    public func boot(_ request: BootRequest, completion: @escaping (Result<Void, Error>) -> Void) {
        let vm = LinuxVM(request: request)
        lock.lock()
        machines[request.name] = vm
        lock.unlock()
        vm.onExit = { [weak self, weak vm] message in
            guard let self = self else { return }
            self.lock.lock()
            if self.machines[request.name] === vm { self.machines[request.name] = nil }
            self.lock.unlock()
            self.onGuestExit?(request.name, request.generation, message)
        }
        vm.boot(completion: completion)
    }

    public func exec(_ request: ExecRequest, emit: @escaping (ExecEvent) -> Void) {
        lock.lock()
        let vm = machines[request.name]
        lock.unlock()
        guard let vm = vm else {
            emit(.failed("VM \(request.name) is not running"))
            return
        }
        // Guest I/O must not hold the daemon's lifecycle lock or the VM control queue.
        DispatchQueue.global().async { vm.exec(request, emit: emit) }
    }

    public func cancelExec(name: String, id: UInt32) {
        lock.lock()
        let vm = machines[name]
        lock.unlock()
        DispatchQueue.global().async { vm?.cancelExec(id) }
    }

    public func destroy(name: String, completion: @escaping (Result<Void, Error>) -> Void) {
        lock.lock()
        let vm = machines[name]
        lock.unlock()
        guard let vm = vm else {
            completion(.success(()))
            return
        }
        vm.destroy(completion: completion)
    }
}

final class LinuxVM: NSObject, VZVirtualMachineDelegate {
    let request: BootRequest
    let queue: DispatchQueue
    var virtualMachine: VZVirtualMachine?
    var socketConnection: VZVirtioSocketConnection?
    private var link: GuestLink?
    private let linkLock = NSLock()

    private var connectedLink: GuestLink? {
        linkLock.lock()
        defer { linkLock.unlock() }
        return link
    }
    var keptPipes: [Pipe] = []
    var consoleHandle: FileHandle?
    var onExit: ((String?) -> Void)?
    private var bootCompletion: ((Result<Void, Error>) -> Void)?
    private var bootFinished = false
    private var exited = false
    private var stopping = false
    private let bootLock = NSLock()
    private let handlerLock = NSLock()
    private var handlers: [UInt32: (GuestMessage) -> Void] = [:]

    init(request: BootRequest) {
        self.request = request
        self.queue = DispatchQueue(label: "microvm.vm.\(request.name)")
        super.init()
    }

    func boot(completion: @escaping (Result<Void, Error>) -> Void) {
        bootCompletion = completion
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.makeAndStart()
            } catch {
                self.finishBoot(.failure(error))
            }
        }
    }

    func exec(_ request: ExecRequest, emit: @escaping (ExecEvent) -> Void) {
        guard let link = connectedLink else {
            emit(.failed("guest agent is not connected"))
            return
        }
        let bounded = max(0, min(request.timeoutSeconds, 24 * 60 * 60))
        let timeoutMS = UInt32(bounded * 1000)
        let start = ExecStart(
            id: request.id,
            timeoutMS: timeoutMS,
            argv: request.argv,
            env: request.env,
            cwd: request.cwd
        )
        let started = DispatchSemaphore(value: 0)
        handlerLock.lock()
        handlers[request.id] = { [weak self] message in
            switch message {
            case .stdout(_, let data):
                emit(.stdout(data))
            case .stderr(_, let data):
                emit(.stderr(data))
            case .exit(_, let code, let signal):
                self?.clearHandler(request.id)
                emit(.finished(code: code, signal: signal))
            case .error(_, let text):
                self?.clearHandler(request.id)
                emit(.failed(text))
            case .started:
                started.signal()
            default:
                break
            }
        }
        handlerLock.unlock()
        do {
            try link.write(.exec(start))
            if let file = request.stdinFile {
                guard started.wait(timeout: .now() + .seconds(max(1, bounded))) == .success else {
                    throw MicroVMError("guest did not acknowledge stdin command")
                }
                let input = try FileHandle(forReadingFrom: file)
                defer { try? input.close() }
                while let data = try input.read(upToCount: 256 << 10), !data.isEmpty {
                    try link.write(.stdin(id: request.id, data: data))
                }
            }
            try link.write(.stdinEOF(id: request.id))
        } catch {
            clearHandler(request.id)
            emit(.failed(String(describing: error)))
        }
    }

    func cancelExec(_ id: UInt32) {
        try? connectedLink?.write(.kill(id: id))
    }

    func destroy(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self = self else {
                completion(.success(()))
                return
            }
            self.stopping = true
            self.disconnectGuest()
            guard let vm = self.virtualMachine else {
                self.teardown(message: nil)
                completion(.success(()))
                return
            }
            if vm.state == .stopped {
                self.teardown(message: nil)
                completion(.success(()))
            } else {
                vm.stop { error in
                    if let error, vm.state != .stopped {
                        completion(.failure(error))
                    } else {
                        self.teardown(message: nil)
                        completion(.success(()))
                    }
                }
            }
        }
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        teardown(message: nil)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        teardown(message: error.localizedDescription)
    }

    private func makeAndStart() throws {
        let config = VZVirtualMachineConfiguration()
        let minCPU = VZVirtualMachineConfiguration.minimumAllowedCPUCount
        let maxCPU = VZVirtualMachineConfiguration.maximumAllowedCPUCount
        guard request.cpus >= minCPU, request.cpus <= maxCPU else {
            throw MicroVMError("cpus \(request.cpus) is outside \(minCPU)-\(maxCPU) on this Mac")
        }
        let bytes = UInt64(request.memoryMB) * 1024 * 1024
        let minMem = VZVirtualMachineConfiguration.minimumAllowedMemorySize
        let maxMem = VZVirtualMachineConfiguration.maximumAllowedMemorySize
        guard bytes >= minMem, bytes <= maxMem else {
            throw MicroVMError(
                "memory \(request.memoryMB) MB is outside \(minMem / 1024 / 1024)-\(maxMem / 1024 / 1024) MB on this Mac"
            )
        }
        config.cpuCount = request.cpus
        config.memorySize = bytes

        let boot = VZLinuxBootLoader(kernelURL: request.kernelURL)
        boot.initialRamdiskURL = request.initrdURL
        // hvc0 is the virtio console. rdinit skips Alpine's /sbin/init.
        boot.commandLine = "console=hvc0 rdinit=/init panic=1"
        if let runtime = request.runtimeDirectory, let workspace = request.workspaceDisk {
            boot.commandLine += " microvm.task=1"
            config.storageDevices = try [
                VZVirtioBlockDeviceConfiguration(
                    attachment: VZDiskImageStorageDeviceAttachment(url: runtime.appendingPathComponent("runtime.ext4"), readOnly: true)),
                VZVirtioBlockDeviceConfiguration(attachment: VZDiskImageStorageDeviceAttachment(url: workspace, readOnly: false)),
            ]
        }
        config.bootLoader = boot
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        config.networkDevices = networkDevices(for: request.network)

        let guestToHost = Pipe()
        let hostToGuest = Pipe()
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: hostToGuest.fileHandleForReading,
            fileHandleForWriting: guestToHost.fileHandleForWriting
        )
        config.serialPorts = [serial]
        keptPipes = [guestToHost, hostToGuest]
        startConsoleDrain(guestToHost)

        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        try config.validate()

        let vm = VZVirtualMachine(configuration: config, queue: queue)
        vm.delegate = self
        virtualMachine = vm
        vm.start { [weak self] result in
            guard let self = self else { return }
            self.queue.async {
                if case .failure(let error) = result {
                    self.finishBoot(.failure(error))
                    return
                }
                let deadline = Date().addingTimeInterval(TimeInterval(self.request.bootTimeoutSeconds))
                self.connectAgent(deadline: deadline)
            }
        }
    }

    private func startConsoleDrain(_ pipe: Pipe) {
        let fd = dup(pipe.fileHandleForReading.fileDescriptor)
        guard fd >= 0 else { return }
        let path = request.consoleLogURL.path
        Thread.detachNewThread {
            let logFD = open(path, O_WRONLY | O_CREAT | O_APPEND, mode_t(0o644))
            defer {
                if logFD >= 0 { close(logFD) }
                close(fd)
            }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = buffer.withUnsafeMutableBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return 0 }
                    return read(fd, base, raw.count)
                }
                if n <= 0 { break }
                if logFD >= 0 {
                    _ = buffer.withUnsafeBytes { raw in
                        write(logFD, raw.baseAddress, n)
                    }
                }
            }
        }
    }

    private func connectAgent(deadline: Date) {
        guard !exited, !stopping, let vm = virtualMachine else {
            finishBoot(.failure(MicroVMError("virtual machine disappeared")))
            return
        }
        guard let device = vm.socketDevices.first as? VZVirtioSocketDevice else {
            finishBoot(.failure(MicroVMError("VM has no virtio-vsock device")))
            return
        }
        device.connect(toPort: GuestProtocol.port) { [weak self] result in
            guard let self = self else { return }
            self.queue.async {
                guard !self.exited, !self.stopping else { return }
                if case .success(let connection) = result {
                    self.accept(connection)
                    return
                }
                if Date() < deadline {
                    self.queue.asyncAfter(deadline: .now() + .milliseconds(10)) {
                        self.connectAgent(deadline: deadline)
                    }
                } else {
                    let tail = tailFile(self.request.consoleLogURL, lines: 40)
                    var message = "guest agent did not accept vsock port \(GuestProtocol.port) before the boot timeout"
                    if !tail.isEmpty {
                        message += "\n--- console.log ---\n\(tail)"
                    }
                    self.finishBoot(.failure(MicroVMError(message)))
                }
            }
        }
    }

    private func accept(_ connection: VZVirtioSocketConnection) {
        guard !exited, !stopping else {
            connection.close()
            return
        }
        let raw = connection.fileDescriptor
        guard raw >= 0 else {
            finishBoot(.failure(MicroVMError("vsock connection has no file descriptor")))
            return
        }
        let fd = dup(raw)
        guard fd >= 0 else {
            finishBoot(.failure(MicroVMError("dup vsock fd: \(String(cString: strerror(errno)))")))
            return
        }
        // Keep the Virtualization object alive; it owns the underlying socket.
        socketConnection = connection
        let link = GuestLink(fd: fd)
        linkLock.lock()
        self.link = link
        linkLock.unlock()
        link.readLoop { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                self.onGuest(message)
            case .failure(let error):
                let text = String(describing: error)
                self.finishBoot(.failure(error))
                self.failExecs(text)
                self.queue.async {
                    if !self.stopping { self.destroy { _ in } }
                }
            }
        }
    }

    private func onGuest(_ message: GuestMessage) {
        switch message {
        case .hello(let version, _):
            if version != GuestProtocol.version {
                finishBoot(.failure(MicroVMError("guest protocol version \(version), host wants \(GuestProtocol.version)")))
                return
            }
            finishBoot(.success(()))
        default:
            guard let id = message.id else { return }
            handlerLock.lock()
            let handler = handlers[id]
            handlerLock.unlock()
            handler?(message)
        }
    }

    private func clearHandler(_ id: UInt32) {
        handlerLock.lock()
        handlers[id] = nil
        handlerLock.unlock()
    }

    private func failExecs(_ text: String) {
        handlerLock.lock()
        let pending = handlers
        handlers.removeAll()
        handlerLock.unlock()
        for (_, handler) in pending {
            DispatchQueue.global().async { handler(.error(id: 0, message: text)) }
        }
    }

    private func finishBoot(_ result: Result<Void, Error>) {
        bootLock.lock()
        let already = bootFinished
        bootFinished = true
        let completion = bootCompletion
        bootCompletion = nil
        bootLock.unlock()
        if already { return }
        completion?(result)
    }

    private func disconnectGuest() {
        linkLock.lock()
        let connection = link
        link = nil
        linkLock.unlock()
        connection?.close()
        socketConnection?.close()
        socketConnection = nil
    }

    private func teardown(message: String?) {
        bootLock.lock()
        let already = exited
        exited = true
        bootLock.unlock()
        if already { return }
        finishBoot(.failure(MicroVMError(message ?? "guest exited")))
        disconnectGuest()
        failExecs(message ?? "guest exited")
        virtualMachine = nil
        onExit?(message)
    }
}
// Kept separate so the actual Virtualization configuration can be checked without booting a guest.
func networkDevices(for mode: NetworkMode) -> [VZNetworkDeviceConfiguration] {
    guard mode == .nat else { return [] }
    let network = VZVirtioNetworkDeviceConfiguration()
    network.attachment = VZNATNetworkDeviceAttachment()
    return [network]
}
#endif
