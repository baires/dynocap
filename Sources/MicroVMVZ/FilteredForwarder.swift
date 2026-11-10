#if os(macOS)
import Darwin
import Foundation
import MicroVMCore
import Virtualization

/// Userspace policy in front of `VZFileHandleNetworkDeviceAttachment`.
/// The guest has no firewall and cannot select NAT.

private struct ParsedFrame {
    var source: [UInt8]
    var type: UInt16
    var payload: ArraySlice<UInt8>
}

private struct UDPPacket {
    var sourceMAC: [UInt8]
    var destinationMAC: [UInt8]
    var sourceIP: UInt32
    var destinationIP: UInt32
    var sourcePort: UInt16
    var destinationPort: UInt16
    var payload: [UInt8]
}

public final class FilteredForwarder {
    public let device: VZVirtioNetworkDeviceConfiguration
    let guestFD: Int32
    private let hostFD: Int32
    private let repositoryHost: String?
    private let condition = NSCondition()
    private var stopped = false
    private var loopStarted = false
    private var loopDone = false
    private var linkHeader: Int?
    private var loggedFirst = false
    private var guestMAC = [UInt8](repeating: 0, count: 6)
    private var ipIdentity: UInt16 = 1
    private var allowedUntil: [UInt32: TimeInterval] = [:]
    private var dnsCache: [String: (TimeInterval, [UInt32])] = [:]
    private var flows: [Flow: Relay] = [:]
    private var loggedDrops: Set<UInt32> = []
    private let ourMAC: [UInt8] = [0x02, 0x00, 0x00, 0x00, 0x00, 0x02]

    public static func start(repositoryHost: String?) throws -> FilteredForwarder {
        let forwarder = try FilteredForwarder(repositoryHost: repositoryHost)
        forwarder.begin()
        return forwarder
    }

    static func testing(repositoryHost: String?) throws -> FilteredForwarder {
        try FilteredForwarder(repositoryHost: repositoryHost)
    }

    private init(repositoryHost: String?) throws {
        var fds = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
            throw MicroVMError("filtered network socket failed: \(String(cString: strerror(errno)))")
        }
        guestFD = fds[0]
        hostFD = fds[1]
        self.repositoryHost = repositoryHost
        for fd in fds {
            var snd: Int32 = 1 << 20
            var rcv: Int32 = 4 << 20
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &snd, socklen_t(MemoryLayout<Int32>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        let flags = fcntl(hostFD, F_GETFL)
        _ = fcntl(hostFD, F_SETFL, flags | O_NONBLOCK)
        let handle = FileHandle(fileDescriptor: guestFD, closeOnDealloc: true)
        let attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: handle)
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = attachment
        if let mac = VZMACAddress(string: "02:00:00:00:00:15") {
            network.macAddress = mac
        }
        device = network
    }

    public func stop() {
        condition.lock()
        let started = loopStarted
        stopped = true
        condition.unlock()
        _ = Darwin.shutdown(hostFD, SHUT_RDWR)
        _ = Darwin.close(hostFD)
        condition.lock()
        if started {
            while !loopDone { condition.wait() }
        }
        condition.unlock()
        for relay in flows.values { relay.close() }
        flows.removeAll()
    }

    private func begin() {
        condition.lock()
        loopStarted = true
        condition.unlock()
        Thread.detachNewThread { [weak self] in
            self?.loop()
        }
    }

    private func loop() {
        defer {
            condition.lock()
            loopDone = true
            condition.broadcast()
            condition.unlock()
        }
        while !isStopped {
            var polls = [pollfd(fd: hostFD, events: Int16(POLLIN), revents: 0)]
            var keys: [Flow?] = [nil]
            for (key, relay) in flows where relay.fd >= 0 {
                var events = Int16(0)
                if relay.phase == .dialing {
                    events = Int16(POLLOUT)
                } else {
                    if relay.inbound.count < 262_144 { events |= Int16(POLLIN) }
                    if !relay.inbound.isEmpty { events |= Int16(POLLOUT) }
                }
                polls.append(pollfd(fd: relay.fd, events: events, revents: 0))
                keys.append(key)
            }
            let ready = polls.withUnsafeMutableBufferPointer { buffer -> Int32 in
                guard let base = buffer.baseAddress else { return -1 }
                return poll(base, nfds_t(buffer.count), 50)
            }
            if isStopped { break }
            if ready < 0 { continue }
            if polls[0].revents & Int16(POLLIN) != 0 {
                while let frame = receive() {
                    for reply in handleGuestFrame(frame) { send(reply) }
                }
            }
            if polls.count > 1 {
                for index in 1..<polls.count {
                    guard let key = keys[index], let relay = flows[key] else { continue }
                    let events = polls[index].revents
                    if events & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 && relay.phase == .dialing {
                        fail(key, "connect failed")
                        continue
                    }
                    for reply in progress(key, events: events) { send(reply) }
                }
            }
            for reply in retransmit() { send(reply) }
        }
    }

    private var isStopped: Bool {
        condition.lock()
        defer { condition.unlock() }
        return stopped
    }

    func handleGuestFrame(_ frame: [UInt8]) -> [[UInt8]] {
        if !loggedFirst {
            loggedFirst = true
            let hex = frame.prefix(24).map { String(format: "%02x", $0) }.joined(separator: " ")
            note("first frame \(frame.count) bytes \(hex)")
        }
        guard let parsed = split(frame) else { return [] }
        guestMAC = parsed.source
        if parsed.type == 0x0806 { return arp(parsed.payload, destination: parsed.source) }
        guard parsed.type == 0x0800 else { return [] }
        return ipv4(Array(parsed.payload), guestMAC: parsed.source)
    }

    private func split(_ frame: [UInt8]) -> ParsedFrame? {
        let choices = linkHeader.map { [$0] } ?? [0, 10, 12]
        for header in choices {
            guard frame.count >= header + 14 else { continue }
            let type = (UInt16(frame[header + 12]) << 8) | UInt16(frame[header + 13])
            if type == 0x0800 || type == 0x0806 {
                linkHeader = header
                let source = Array(frame[(header + 6)..<(header + 12)])
                return ParsedFrame(source: source, type: type, payload: frame[(header + 14)...])
            }
        }
        return nil
    }

    private func arp(_ payload: ArraySlice<UInt8>, destination: [UInt8]) -> [[UInt8]] {
        let bytes = Array(payload)
        guard bytes.count >= 28 else { return [] }
        let operation = (UInt16(bytes[6]) << 8) | UInt16(bytes[7])
        guard operation == 1 else { return [] }
        let requested = read32(bytes, 24)
        guard requested == FilteredEgress.gateway.value || requested == FilteredEgress.dns.value else { return [] }
        var reply = [UInt8](repeating: 0, count: 28)
        reply[0] = 0
        reply[1] = 1
        reply[2] = 0x08
        reply[3] = 0
        reply[4] = 6
        reply[5] = 4
        reply[6] = 0
        reply[7] = 2
        reply.replaceSubrange(8..<14, with: ourMAC)
        reply.replaceSubrange(14..<18, with: put32(requested))
        reply.replaceSubrange(18..<24, with: destination)
        reply.replaceSubrange(24..<28, with: put32(read32(bytes, 14)))
        return [ether(destination: destination, type: 0x0806, payload: reply)]
    }

    private func ipv4(_ packet: [UInt8], guestMAC: [UInt8]) -> [[UInt8]] {
        guard packet.count >= 20 else { return [] }
        let version = packet[0] >> 4
        let headerLength = Int(packet[0] & 0x0F) * 4
        guard version == 4, headerLength >= 20, packet.count >= headerLength else { return [] }
        let total = Int(read16(packet, 2))
        guard total >= headerLength, packet.count >= total else { return [] }
        let flags = read16(packet, 6)
        if flags & 0x3FFF != 0 { return [] }
        let source = read32(packet, 12)
        let destination = read32(packet, 16)
        let body = Array(packet[headerLength..<total])
        switch packet[9] {
        case 17:
            return udp(body, source: source, destination: destination, guestMAC: guestMAC)
        case 6:
            return tcp(body, source: source, destination: destination, guestMAC: guestMAC)
        default:
            return []
        }
    }

    private func udp(_ packet: [UInt8], source: UInt32, destination: UInt32, guestMAC: [UInt8]) -> [[UInt8]] {
        guard packet.count >= 8 else { return [] }
        let srcPort = read16(packet, 0)
        let dstPort = read16(packet, 2)
        let length = Int(read16(packet, 4))
        guard length >= 8, packet.count >= length else { return [] }
        let payload = Array(packet[8..<length])
        if dstPort == 67 {
            guard let reply = FilteredDHCP.reply(to: payload) else { return [] }
            note("dhcp \(payload.count) bytes")
            return [udpFrame(UDPPacket(
                sourceMAC: ourMAC, destinationMAC: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
                sourceIP: FilteredEgress.gateway.value, destinationIP: 0xFFFFFFFF,
                sourcePort: 67, destinationPort: 68, payload: reply
            ))]
        }
        guard destination == FilteredEgress.dns.value, dstPort == 53 else { return [] }
        let hosts = hostAddresses()
        guard let reply = FilteredDNS.reply(
            query: payload, repositoryHost: repositoryHost, hostAddresses: hosts,
            resolve: { [self] name in
                let found = lookup(name)
                remember(FilteredEgress.usable(found, hostAddresses: hosts))
                return found
            }
        ) else { return [] }
        return [udpFrame(UDPPacket(
            sourceMAC: ourMAC, destinationMAC: guestMAC,
            sourceIP: FilteredEgress.dns.value, destinationIP: source,
            sourcePort: 53, destinationPort: srcPort, payload: reply
        ))]
    }

    private func tcp(_ packet: [UInt8], source: UInt32, destination: UInt32, guestMAC: [UInt8]) -> [[UInt8]] {
        guard packet.count >= 20, source == FilteredEgress.guest.value else { return [] }
        let srcPort = read16(packet, 0)
        let dstPort = read16(packet, 2)
        let seq = read32(packet, 4)
        let ack = read32(packet, 8)
        let dataOffset = Int(packet[12] >> 4) * 4
        guard dataOffset >= 20, packet.count >= dataOffset else { return [] }
        let flags = packet[13]
        let window = UInt32(read16(packet, 14))
        let payload = Array(packet[dataOffset...])
        let flow = Flow(guestPort: srcPort, destination: destination)
        if flags & 0x02 != 0 && flags & 0x10 == 0 {
            guard FilteredEgress.permitsTCP(
                destination: destination, port: Int(dstPort), resolved: resolvedNow(), hostAddresses: hostAddresses()
            ) else {
                if loggedDrops.insert(destination).inserted {
                    note("drop tcp \(format(destination)):\(dstPort)")
                }
                return []
            }
            guard flows[flow] == nil, flows.count < 128, let fd = dial(destination) else { return [] }
            let relay = Relay(fd: fd, guestMAC: guestMAC, guestPort: srcPort, destination: destination)
            relay.rcvNxt = seq &+ 1
            relay.window = max(window, 1)
            relay.iss = UInt32.random(in: 1...UInt32.max - 1024)
            relay.sndUna = relay.iss
            relay.sndNxt = relay.iss
            flows[flow] = relay
            note("dial \(format(destination)):443")
            return []
        }
        guard let relay = flows[flow] else { return [] }
        relay.window = max(window, 1)
        relay.guestMAC = guestMAC
        var replies: [[UInt8]] = []
        if flags & 0x04 != 0 {
            relay.close()
            flows[flow] = nil
            return []
        }
        if relay.phase == .handshake && ack == relay.iss &+ 1 {
            relay.phase = .open
            relay.sndUna = ack
        }
        if ack != 0 { acceptAck(relay, ack) }
        if relay.phase == .open && !payload.isEmpty && seq == relay.rcvNxt
            && relay.inbound.count + payload.count <= 262_144 {
            relay.inbound.append(contentsOf: payload)
            relay.rcvNxt &+= UInt32(payload.count)
            replies += flushHost(relay)
            replies.append(segment(relay, payload: [], flags: 0x10))
        } else if !payload.isEmpty && seqBefore(seq, relay.rcvNxt) {
            replies.append(segment(relay, payload: [], flags: 0x10))
        }
        if flags & 0x01 != 0 && seq == relay.rcvNxt && !relay.guestClosed {
            relay.guestClosed = true
            relay.rcvNxt &+= 1
            replies.append(segment(relay, payload: [], flags: 0x10))
            _ = Darwin.shutdown(relay.fd, SHUT_WR)
        }
        replies += pumpGuest(relay)
        if relay.done {
            relay.close()
            flows[flow] = nil
        }
        return replies
    }

    private func progress(_ key: Flow, events: Int16) -> [[UInt8]] {
        guard let relay = flows[key] else { return [] }
        var replies: [[UInt8]] = []
        if relay.phase == .dialing && events & Int16(POLLOUT) != 0 {
            let err = socketError(relay.fd)
            if err != 0 {
                fail(key, "connect \(err)")
                return []
            }
            relay.phase = .handshake
            relay.sndNxt = relay.iss &+ 1
            relay.lastSend = ProcessInfo.processInfo.systemUptime
            replies.append(segment(relay, payload: [], flags: 0x12, sequence: relay.iss))
        }
        if events & Int16(POLLOUT) != 0 { replies += flushHost(relay) }
        if events & Int16(POLLIN) != 0 { replies += readHost(relay) }
        replies += pumpGuest(relay)
        if relay.done {
            relay.close()
            flows[key] = nil
        }
        return replies
    }

    private func flushHost(_ relay: Relay) -> [[UInt8]] {
        while !relay.inbound.isEmpty {
            let wrote = relay.inbound.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.send(relay.fd, base, raw.count, 0)
            }
            if wrote > 0 {
                relay.inbound.removeFirst(wrote)
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK { break }
            relay.hostClosed = true
            break
        }
        return []
    }

    private func readHost(_ relay: Relay) -> [[UInt8]] {
        guard relay.phase == .open || relay.phase == .handshake else { return [] }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.recv(relay.fd, base, raw.count, 0)
        }
        if count > 0 {
            relay.outbound.append(contentsOf: buffer.prefix(count))
            return []
        }
        if count == 0 {
            relay.hostClosed = true
            return []
        }
        if errno == EAGAIN || errno == EWOULDBLOCK { return [] }
        relay.hostClosed = true
        return []
    }

    private func pumpGuest(_ relay: Relay) -> [[UInt8]] {
        guard relay.phase == .open else { return [] }
        var replies: [[UInt8]] = []
        let inFlight = relay.sndNxt &- relay.sndUna
        var room = relay.window > inFlight ? Int(relay.window &- inFlight) : 0
        while room > 0 && !relay.outbound.isEmpty {
            let size = min(1200, room, relay.outbound.count)
            let chunk = Array(relay.outbound.prefix(size))
            relay.outbound.removeFirst(size)
            relay.unacked.append(contentsOf: chunk)
            replies.append(segment(relay, payload: chunk, flags: 0x18))
            relay.sndNxt &+= UInt32(size)
            room -= size
            relay.lastSend = ProcessInfo.processInfo.systemUptime
        }
        if relay.hostClosed && relay.outbound.isEmpty && relay.unacked.isEmpty && relay.finSeq == nil {
            relay.finSeq = relay.sndNxt
            replies.append(segment(relay, payload: [], flags: 0x11))
            relay.sndNxt &+= 1
            relay.lastSend = ProcessInfo.processInfo.systemUptime
        }
        return replies
    }

    private func retransmit() -> [[UInt8]] {
        let now = ProcessInfo.processInfo.systemUptime
        var replies: [[UInt8]] = []
        var dead: [Flow] = []
        for (key, relay) in flows {
            if relay.phase == .dialing && now - relay.started > 10 {
                dead.append(key)
                continue
            }
            guard now - relay.lastSend > 0.2, relay.sndUna != relay.sndNxt, relay.retries < 8 else { continue }
            relay.retries += 1
            relay.lastSend = now
            if relay.phase == .handshake {
                replies.append(segment(relay, payload: [], flags: 0x12, sequence: relay.iss))
                continue
            }
            if !relay.unacked.isEmpty {
                var offset = 0
                var sequence = relay.sndUna
                while offset < relay.unacked.count {
                    let size = min(1200, relay.unacked.count - offset)
                    let chunk = Array(relay.unacked[offset..<(offset + size)])
                    replies.append(segment(relay, payload: chunk, flags: 0x18, sequence: sequence))
                    sequence &+= UInt32(size)
                    offset += size
                }
            }
            if let fin = relay.finSeq, fin == relay.sndNxt &- 1, relay.sndUna != relay.sndNxt {
                replies.append(segment(relay, payload: [], flags: 0x11, sequence: fin))
            }
        }
        for key in dead { fail(key, "connect timeout") }
        return replies
    }

    private func acceptAck(_ relay: Relay, _ ack: UInt32) {
        if seqBefore(relay.sndNxt &+ 1, ack) { return }
        if seqBefore(ack, relay.sndUna) { return }
        let advance = Int(ack &- relay.sndUna)
        if advance > 0 {
            relay.retries = 0
            if advance <= relay.unacked.count {
                relay.unacked.removeFirst(advance)
            } else {
                relay.unacked.removeAll()
            }
            relay.sndUna = ack
        }
    }

    private func fail(_ key: Flow, _ message: String) {
        note(message)
        flows[key]?.close()
        flows[key] = nil
    }

    private func segment(_ relay: Relay, payload: [UInt8], flags: UInt8, sequence: UInt32? = nil) -> [UInt8] {
        var tcp = [UInt8](repeating: 0, count: 20 + payload.count)
        if flags & 0x02 != 0 {
            tcp = [UInt8](repeating: 0, count: 24 + payload.count)
            tcp[12] = 6 << 4
            tcp[20] = 2
            tcp[21] = 4
            tcp[22] = 0x05
            tcp[23] = 0xB4
        } else {
            tcp[12] = 5 << 4
        }
        put16(&tcp, 0, UInt16(443))
        put16(&tcp, 2, relay.guestPort)
        put32(&tcp, 4, sequence ?? relay.sndNxt)
        put32(&tcp, 8, relay.rcvNxt)
        tcp[13] = flags
        put16(&tcp, 14, 65535)
        tcp.replaceSubrange((Int(tcp[12] >> 4) * 4)..<tcp.count, with: payload)
        let src = relay.destination
        let dst = FilteredEgress.guest.value
        let sum = transportChecksum(source: src, destination: dst, protocol: 6, segment: tcp)
        put16(&tcp, 16, sum)
        return udpLikeIP(source: src, destination: dst, protocol: 6, segment: tcp, destinationMAC: relay.guestMAC)
    }

    private func udpFrame(_ packet: UDPPacket) -> [UInt8] {
        var udp = [UInt8](repeating: 0, count: 8 + packet.payload.count)
        put16(&udp, 0, packet.sourcePort)
        put16(&udp, 2, packet.destinationPort)
        put16(&udp, 4, UInt16(udp.count))
        udp.replaceSubrange(8..<udp.count, with: packet.payload)
        let sum = transportChecksum(source: packet.sourceIP, destination: packet.destinationIP, protocol: 17, segment: udp)
        put16(&udp, 6, sum == 0 ? 0xFFFF : sum)
        return udpLikeIP(
            source: packet.sourceIP, destination: packet.destinationIP, protocol: 17, segment: udp,
            destinationMAC: packet.destinationMAC, sourceMAC: packet.sourceMAC
        )
    }

    private func udpLikeIP(
        source: UInt32, destination: UInt32, protocol proto: UInt8, segment: [UInt8], destinationMAC: [UInt8],
        sourceMAC: [UInt8]? = nil
    ) -> [UInt8] {
        var ip = [UInt8](repeating: 0, count: 20 + segment.count)
        ip[0] = 0x45
        put16(&ip, 2, UInt16(ip.count))
        ipIdentity &+= 1
        put16(&ip, 4, ipIdentity)
        ip[8] = 64
        ip[9] = proto
        put32(&ip, 12, source)
        put32(&ip, 16, destination)
        ip.replaceSubrange(20..<ip.count, with: segment)
        put16(&ip, 10, internetChecksum(Array(ip[0..<20])))
        return ether(destination: destinationMAC, source: sourceMAC ?? ourMAC, type: 0x0800, payload: ip)
    }

    private func ether(destination: [UInt8], source: [UInt8]? = nil, type: UInt16, payload: [UInt8]) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: (linkHeader ?? 0))
        frame += destination
        frame += source ?? ourMAC
        frame += put16(type)
        frame += payload
        return frame
    }

    private func dial(_ address: UInt32) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var remote = sockaddr_in()
        remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = in_port_t(443).bigEndian
        remote.sin_addr.s_addr = address.bigEndian
        let connected = withUnsafePointer(to: &remote) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                Darwin.connect(fd, sock, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected == 0 || errno == EINPROGRESS { return fd }
        note("dial \(format(address)) failed: \(String(cString: strerror(errno)))")
        _ = Darwin.close(fd)
        return nil
    }

    private func socketError(_ fd: Int32) -> Int32 {
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        let rc = withUnsafeMutablePointer(to: &err) { errPtr in
            withUnsafeMutablePointer(to: &len) { lenPtr in
                getsockopt(fd, SOL_SOCKET, SO_ERROR, errPtr, lenPtr)
            }
        }
        return rc == 0 ? err : errno
    }

    private func lookup(_ name: String) -> [UInt32] {
        let key = FilteredEgress.normalize(name)
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = dnsCache[key], cached.0 > now { return cached.1 }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        var found: [UInt32] = []
        if getaddrinfo(key, nil, &hints, &result) == 0, let result {
            defer { freeaddrinfo(result) }
            var cursor: UnsafeMutablePointer<addrinfo>? = result
            while let item = cursor {
                if item.pointee.ai_family == AF_INET, let addr = item.pointee.ai_addr {
                    let value = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                    found.append(UInt32(bigEndian: value))
                }
                cursor = item.pointee.ai_next
            }
        }
        dnsCache[key] = (now + TimeInterval(FilteredEgress.answerTTL), found)
        return found
    }

    private func remember(_ addresses: [UInt32]) {
        let expiry = ProcessInfo.processInfo.systemUptime + 120
        for address in addresses { allowedUntil[address] = expiry }
    }

    private func resolvedNow() -> Set<UInt32> {
        let now = ProcessInfo.processInfo.systemUptime
        allowedUntil = allowedUntil.filter { $0.value > now }
        return Set(allowedUntil.keys)
    }

    private func hostAddresses() -> Set<UInt32> {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let list else { return [] }
        defer { freeifaddrs(list) }
        var addresses: Set<UInt32> = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = list
        while let item = cursor {
            if let addr = item.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) {
                let value = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                addresses.insert(UInt32(bigEndian: value))
            }
            cursor = item.pointee.ifa_next
        }
        return addresses
    }

    private func receive() -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.recv(hostFD, base, raw.count, 0)
        }
        if count > 0 { return Array(buffer.prefix(count)) }
        return nil
    }

    private func send(_ frame: [UInt8]) {
        _ = frame.withUnsafeBytes { raw in
            Darwin.send(hostFD, raw.baseAddress, raw.count, 0)
        }
    }

    private func note(_ message: String) {
        let line = Data("microvm filtered: \(message)\n".utf8)
        line.withUnsafeBytes { raw in
            _ = Darwin.write(STDERR_FILENO, raw.baseAddress, raw.count)
        }
    }

    private func format(_ address: UInt32) -> String {
        let octets = IPv4Address(hostOrder: address).octets
        return "\(octets[0]).\(octets[1]).\(octets[2]).\(octets[3])"
    }
}

private struct Flow: Hashable {
    var guestPort: UInt16
    var destination: UInt32
}

private final class Relay {
    let fd: Int32
    var guestMAC: [UInt8]
    var guestPort: UInt16
    var destination: UInt32
    var phase: Phase = .dialing
    var rcvNxt: UInt32 = 0
    var iss: UInt32 = 0
    var sndUna: UInt32 = 0
    var sndNxt: UInt32 = 0
    var window: UInt32 = 65535
    var unacked: [UInt8] = []
    var outbound: [UInt8] = []
    var inbound: [UInt8] = []
    var guestClosed = false
    var hostClosed = false
    var finSeq: UInt32?
    var retries = 0
    var lastSend: TimeInterval = 0
    var started = ProcessInfo.processInfo.systemUptime
    private var closed = false

    init(fd: Int32, guestMAC: [UInt8], guestPort: UInt16, destination: UInt32) {
        self.fd = fd
        self.guestMAC = guestMAC
        self.guestPort = guestPort
        self.destination = destination
    }

    var done: Bool {
        guestClosed && hostClosed && outbound.isEmpty && unacked.isEmpty && (finSeq == nil || sndUna == sndNxt)
    }

    func close() {
        if closed { return }
        closed = true
        _ = Darwin.close(fd)
    }
}

private enum Phase {
    case dialing
    case handshake
    case open
}

private func seqBefore(_ lhs: UInt32, _ rhs: UInt32) -> Bool {
    Int32(bitPattern: lhs &- rhs) < 0
}

private func read16(_ data: [UInt8], _ offset: Int) -> UInt16 {
    (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
}

private func read32(_ data: [UInt8], _ offset: Int) -> UInt32 {
    (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16) | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
}

private func put16(_ value: UInt16) -> [UInt8] {
    [UInt8(value >> 8), UInt8(value & 0xFF)]
}

private func put16(_ data: inout [UInt8], _ offset: Int, _ value: UInt16) {
    data[offset] = UInt8(value >> 8)
    data[offset + 1] = UInt8(value & 0xFF)
}

private func put32(_ value: UInt32) -> [UInt8] {
    [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
}

private func put32(_ data: inout [UInt8], _ offset: Int, _ value: UInt32) {
    data[offset] = UInt8((value >> 24) & 0xFF)
    data[offset + 1] = UInt8((value >> 16) & 0xFF)
    data[offset + 2] = UInt8((value >> 8) & 0xFF)
    data[offset + 3] = UInt8(value & 0xFF)
}

private func internetChecksum(_ data: [UInt8]) -> UInt16 {
    var sum = UInt32(0)
    var index = 0
    while index + 1 < data.count {
        sum += (UInt32(data[index]) << 8) | UInt32(data[index + 1])
        index += 2
    }
    if index < data.count { sum += UInt32(data[index]) << 8 }
    while sum > 0xFFFF { sum = (sum & 0xFFFF) + (sum >> 16) }
    return ~UInt16(sum & 0xFFFF)
}

private func transportChecksum(source: UInt32, destination: UInt32, protocol proto: UInt8, segment: [UInt8]) -> UInt16 {
    var pseudo = put32(source) + put32(destination)
    pseudo += [0, proto]
    pseudo += put16(UInt16(segment.count))
    var body = segment
    if proto == 6, body.count >= 18 { put16(&body, 16, 0) }
    if proto == 17, body.count >= 8 { put16(&body, 6, 0) }
    return internetChecksum(pseudo + body)
}
#endif
