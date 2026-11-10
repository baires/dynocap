import Foundation

/// IPv4 address in host byte order.
public struct IPv4Address: Equatable, Hashable {
    public var value: UInt32

    public init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) {
        value = (UInt32(a) << 24) | (UInt32(b) << 16) | (UInt32(c) << 8) | UInt32(d)
    }

    public init(hostOrder value: UInt32) {
        self.value = value
    }

    public var octets: [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
    }

    public func contained(in base: UInt32, prefix: Int) -> Bool {
        let bits = UInt32(prefix)
        let mask: UInt32 = bits >= 32 ? .max : ~UInt32(0) << (32 - bits)
        return (value & mask) == (base & mask)
    }
}

/// Host policy for filtered egress. The guest does not choose these names or ranges.
public enum FilteredEgress {
    public static let guest = IPv4Address(10, 0, 2, 15)
    public static let gateway = IPv4Address(10, 0, 2, 2)
    public static let dns = IPv4Address(10, 0, 2, 3)
    public static let registryHost = "registry.npmjs.org"
    public static let answerTTL: UInt32 = 60

    public static func denies(_ address: UInt32, hostAddresses: Set<UInt32> = []) -> Bool {
        if hostAddresses.contains(address) { return true }
        let ip = IPv4Address(hostOrder: address)
        let ranges: [(UInt32, Int)] = [
            (IPv4Address(0, 0, 0, 0).value, 8),
            (IPv4Address(10, 0, 0, 0).value, 8),
            (IPv4Address(100, 64, 0, 0).value, 10),
            (IPv4Address(127, 0, 0, 0).value, 8),
            (IPv4Address(169, 254, 0, 0).value, 16),
            (IPv4Address(172, 16, 0, 0).value, 12),
            (IPv4Address(192, 168, 0, 0).value, 16),
            (IPv4Address(224, 0, 0, 0).value, 4),
            (IPv4Address(240, 0, 0, 0).value, 4),
        ]
        return ranges.contains { ip.contained(in: $0.0, prefix: $0.1) }
    }

    public static func normalize(_ name: String) -> String {
        var value = name.lowercased()
        if value.hasSuffix(".") { value.removeLast() }
        return value
    }

    /// The whole DNS allowlist: the npm registry, plus the task URL hostname when there is one.
    public static func allows(name: String, repositoryHost: String?) -> Bool {
        let normalized = normalize(name)
        if normalized == registryHost { return true }
        guard let repositoryHost else { return false }
        return normalized == normalize(repositoryHost)
    }

    public static func repositoryHost(_ url: String) -> String? {
        guard url.hasPrefix("https://") else { return nil }
        let rest = url.dropFirst("https://".count)
        let hostPort = rest.prefix { $0 != "/" && $0 != "?" }
        let host = hostPort.prefix { $0 != ":" }
        guard !host.isEmpty, !host.contains("@"), !host.contains(" ") else { return nil }
        return normalize(String(host))
    }

    public static func usable(_ addresses: [UInt32], hostAddresses: Set<UInt32>) -> [UInt32] {
        var kept: [UInt32] = []
        for address in addresses where !denies(address, hostAddresses: hostAddresses) && !kept.contains(address) {
            kept.append(address)
        }
        return kept
    }

    public static func permitsTCP(destination: UInt32, port: Int, resolved: Set<UInt32>, hostAddresses: Set<UInt32>) -> Bool {
        port == 443 && resolved.contains(destination) && !denies(destination, hostAddresses: hostAddresses)
    }
}

public enum NetworkModeLock {
    public static func rejectChange(from recorded: NetworkMode, to requested: NetworkMode) throws {
        guard recorded == requested else {
            throw MicroVMError("network mode is fixed at start")
        }
    }
}

public enum NetworkAdmission {
    public static func rejection(
        network: NetworkMode?,
        requireOffline: Bool,
        permitFiltered: Bool?,
        offlineMessage: String
    ) -> String? {
        if network == .filtered {
            if permitFiltered == true { return nil }
            if permitFiltered == false || requireOffline { return "filtered networking is disabled" }
            return nil
        }
        if requireOffline && network != NetworkMode.none { return offlineMessage }
        return nil
    }
}

public enum FilteredDNS {
    public static func reply(
        query: [UInt8],
        repositoryHost: String?,
        hostAddresses: Set<UInt32>,
        resolve: (String) -> [UInt32]
    ) -> [UInt8]? {
        guard query.count >= 12 else { return nil }
        let flags = read16(query, 2)
        if flags & 0x8000 != 0 || ((flags >> 11) & 0xF) != 0 { return nil }
        guard read16(query, 4) == 1 else { return nil }
        var offset = 12
        guard let name = readName(query, &offset), offset + 4 <= query.count else { return nil }
        let qtype = read16(query, offset)
        let qclass = read16(query, offset + 2)
        guard qclass == 1 || qclass == 255 else { return nil }
        let question = Array(query[12..<(offset + 4)])
        let allowed = FilteredEgress.allows(name: name, repositoryHost: repositoryHost)
        var rcode: UInt16 = 0
        var answers: [UInt8] = []
        if !allowed {
            rcode = 3
        } else if qtype == 1 || qtype == 255 {
            let usable = FilteredEgress.usable(resolve(name), hostAddresses: hostAddresses)
            for address in usable.prefix(8) {
                answers += [0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01]
                answers += put32(FilteredEgress.answerTTL)
                answers += [0x00, 0x04]
                answers += IPv4Address(hostOrder: address).octets
            }
        }
        var header = [query[0], query[1]]
        let responseFlags = 0x8480 | (flags & 0x0100) | rcode
        header += put16(responseFlags)
        header += put16(1)
        header += put16(UInt16(answers.count / 16))
        header += put16(0)
        header += put16(0)
        return header + question + answers
    }

    private static func read16(_ data: [UInt8], _ offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func put16(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    private static func put32(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static func readName(_ data: [UInt8], _ offset: inout Int) -> String? {
        var labels: [String] = []
        var cursor = offset
        var end = offset
        var jumped = false
        var jumps = 0
        while cursor < data.count && jumps < 8 {
            let length = Int(data[cursor])
            if length == 0 {
                if !jumped { end = cursor + 1 }
                offset = end
                return labels.joined(separator: ".")
            }
            if length & 0xC0 == 0xC0 {
                guard cursor + 1 < data.count else { return nil }
                if !jumped { end = cursor + 2 }
                cursor = ((length & 0x3F) << 8) | Int(data[cursor + 1])
                jumped = true
                jumps += 1
                continue
            }
            guard length < 64, cursor + 1 + length <= data.count else { return nil }
            guard let label = String(bytes: data[(cursor + 1)..<(cursor + 1 + length)], encoding: .ascii) else { return nil }
            labels.append(label)
            cursor += 1 + length
            if !jumped { end = cursor }
        }
        return nil
    }
}

public enum FilteredDHCP {
    static let discover: UInt8 = 1
    static let offer: UInt8 = 2
    static let request: UInt8 = 3
    static let ack: UInt8 = 5

    public static func reply(to payload: [UInt8]) -> [UInt8]? {
        guard payload.count >= 240, payload[0] == 1, payload[1] == 1, payload[2] == 6 else { return nil }
        guard Array(payload[236..<240]) == [0x63, 0x82, 0x53, 0x63] else { return nil }
        guard let kind = messageType(payload) else { return nil }
        let responseKind: UInt8
        switch kind {
        case discover: responseKind = offer
        case request: responseKind = ack
        default: return nil
        }
        var reply = [UInt8](repeating: 0, count: 300)
        reply[0] = 2
        reply[1] = 1
        reply[2] = 6
        reply.replaceSubrange(4..<8, with: payload[4..<8])
        reply[10] = 0x80
        reply.replaceSubrange(16..<20, with: FilteredEgress.guest.octets)
        let gateway = FilteredEgress.gateway.octets
        reply.replaceSubrange(20..<24, with: gateway)
        reply.replaceSubrange(28..<44, with: payload[28..<44])
        reply.replaceSubrange(236..<240, with: [0x63, 0x82, 0x53, 0x63])
        var options: [UInt8] = [53, 1, responseKind, 54, 4] + gateway
        options += [51, 4, 0x00, 0x01, 0x51, 0x80]
        options += [1, 4, 255, 255, 255, 0]
        options += [3, 4] + gateway
        options += [6, 4] + FilteredEgress.dns.octets + [255]
        let room = reply.count - 240
        guard options.count <= room else { return nil }
        reply.replaceSubrange(240..<(240 + options.count), with: options)
        return reply
    }

    private static func messageType(_ payload: [UInt8]) -> UInt8? {
        var index = 240
        while index < payload.count {
            let kind = payload[index]
            if kind == 255 { return nil }
            if kind == 0 {
                index += 1
                continue
            }
            guard index + 1 < payload.count else { return nil }
            let length = Int(payload[index + 1])
            guard length >= 1, index + 2 + length <= payload.count else { return nil }
            if kind == 53 { return payload[index + 2] }
            index += 2 + length
        }
        return nil
    }
}
