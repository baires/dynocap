#if os(macOS)
import Darwin
import XCTest
import DynoCapCore
import Virtualization
@testable import DynoCapVZ

final class NetworkConfigurationTests: XCTestCase {
    func testOfflineHasNoNICAndNATHasExactlyOneNATAttachment() {
        XCTAssertTrue(networkDevices(for: .none).isEmpty)
        let devices = networkDevices(for: .nat)
        XCTAssertEqual(devices.count, 1)
        XCTAssertTrue(devices.first?.attachment is VZNATNetworkDeviceAttachment)
    }

    func testFilteredAttachmentAnswersDHCPAndDropsMetadata() throws {
        let forwarder = try FilteredForwarder.testing(allowedHosts: ["registry.npmjs.org", "github.com"])
        defer { forwarder.stop() }
        XCTAssertTrue(forwarder.device.attachment is VZFileHandleNetworkDeviceAttachment)
        let guest = [UInt8](repeating: 0x02, count: 5) + [0x15]
        let offer = forwarder.handleGuestFrame(dhcpDiscover(from: guest)).first
        let frame = try XCTUnwrap(offer)
        XCTAssertEqual(Array(frame[0..<6]), [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertEqual(Array(frame[58..<62]), [10, 0, 2, 15])
        XCTAssertEqual(Array(frame[309..<315]), [6, 4, 10, 0, 2, 3])
        let nx = try XCTUnwrap(forwarder.handleGuestFrame(dnsQueryFrame(name: "example.com", from: guest)).first)
        XCTAssertEqual(nx[14 + 20 + 8 + 3] & 0x0F, 3)
        XCTAssertTrue(forwarder.handleGuestFrame(tcpSyn(from: guest, destination: [169, 254, 169, 254], port: 80)).isEmpty)
        XCTAssertTrue(forwarder.handleGuestFrame(tcpSyn(from: guest, destination: [10, 1, 2, 3], port: 443)).isEmpty)
        XCTAssertTrue(forwarder.handleGuestFrame(tcpSyn(from: guest, destination: [192, 168, 1, 1], port: 443)).isEmpty)
    }

    func testLookupQueriesTheAbsoluteNameAndGrantsOnlyPublishedAddresses() throws {
        let forwarder = try FilteredForwarder.testing(allowedHosts: ["registry.npmjs.org", "github.com"])
        defer { forwarder.stop() }
        var queried: [String] = []
        let addresses = (1...9).map { IPv4Address(1, 2, 3, UInt8($0)).value }
        forwarder.resolver = { name in
            queried.append(name)
            return addresses
        }
        let guest = [UInt8](repeating: 0x02, count: 5) + [0x15]
        let reply = try XCTUnwrap(forwarder.handleGuestFrame(dnsQueryFrame(name: "Registry.NPMJS.org", from: guest)).first)
        XCTAssertEqual(queried, ["registry.npmjs.org."])
        XCTAssertEqual(reply[14 + 20 + 8 + 7], 8)
        let first = IPv4Address(1, 2, 3, 1).value
        let ninth = IPv4Address(1, 2, 3, 9).value
        XCTAssertEqual(forwarder.names(for: first), ["registry.npmjs.org"])
        XCTAssertTrue(forwarder.names(for: ninth).isEmpty)
        queried.removeAll()
        _ = forwarder.handleGuestFrame(dnsQueryFrame(name: "github.com", from: guest))
        XCTAssertEqual(queried, ["github.com."])
        XCTAssertEqual(forwarder.names(for: first), ["registry.npmjs.org", "github.com"])
    }
    func testFilteredDownloadBackpressureAndWindowRecovery() throws {
        let forwarder = try FilteredForwarder.testing(allowedHosts: ["registry.npmjs.org"])
        defer { forwarder.stop() }
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let relay = Relay(fd: pair[0], guestMAC: [0, 1, 2, 3, 4, 5], guestPort: 4000, destination: 0x01010101)
        defer { relay.close(); Darwin.close(pair[1]) }
        for fd in pair {
            let flags = fcntl(fd, F_GETFL)
            XCTAssertEqual(fcntl(fd, F_SETFL, flags | O_NONBLOCK), 0)
            var size: Int32 = 1 << 20
            XCTAssertEqual(setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size)), 0)
        }
        relay.phase = .open
        relay.sniAccepted = true
        relay.window = 0
        relay.sndUna = 100
        relay.sndNxt = 100
        let chunk = [UInt8](repeating: 42, count: 16_384)
        for _ in 0..<32 {
            let count = chunk.withUnsafeBytes { Darwin.write(pair[1], $0.baseAddress, $0.count) }
            XCTAssertEqual(count, chunk.count)
            _ = forwarder.readHost(relay)
            XCTAssertTrue(forwarder.pumpGuest(relay).isEmpty)
        }
        XCTAssertEqual(relay.outbound.count + relay.unacked.count, 262_144)
        XCTAssertEqual(relay.pollEvents & Int16(POLLIN), 0)
        _ = forwarder.readHost(relay) // A stale readiness event must not bypass the bound.
        XCTAssertEqual(relay.outbound.count, 262_144)
        var received: [UInt8] = []
        func drain() {
            for frame in forwarder.pumpGuest(relay) { received += frame.dropFirst(54) }
        }
        relay.window = 1
        drain()
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(relay.outbound.count + relay.unacked.count, 262_144)
        forwarder.acceptAck(relay, relay.sndNxt)
        XCTAssertNotEqual(relay.pollEvents & Int16(POLLIN), 0)
        _ = forwarder.readHost(relay)
        XCTAssertEqual(relay.outbound.count + relay.unacked.count, 262_144)
        Darwin.shutdown(pair[1], SHUT_WR)
        relay.window = 65_535
        for _ in 0..<128 {
            _ = forwarder.readHost(relay)
            drain()
            forwarder.acceptAck(relay, relay.sndNxt)
            XCTAssertLessThanOrEqual(relay.outbound.count + relay.unacked.count, 262_144)
            if relay.hostClosed && relay.outbound.isEmpty && relay.unacked.isEmpty { break }
        }
        XCTAssertEqual(received, [UInt8](repeating: 42, count: 32 * chunk.count))
        XCTAssertTrue(relay.hostClosed)
        XCTAssertEqual(relay.pollEvents & Int16(POLLIN), 0)
    }

}

private func ethernet(from source: [UInt8], type: UInt16, payload: [UInt8]) -> [UInt8] {
    var frame = [UInt8](repeating: 0xFF, count: 6) + source
    frame += [UInt8(type >> 8), UInt8(type & 0xFF)]
    frame += payload
    return frame
}

private func ipv4(source: [UInt8], destination: [UInt8], proto: UInt8, segment: [UInt8]) -> [UInt8] {
    var packet = [UInt8](repeating: 0, count: 20 + segment.count)
    packet[0] = 0x45
    let length = UInt16(packet.count)
    packet[2] = UInt8(length >> 8)
    packet[3] = UInt8(length & 0xFF)
    packet[8] = 64
    packet[9] = proto
    packet.replaceSubrange(12..<16, with: source)
    packet.replaceSubrange(16..<20, with: destination)
    packet.replaceSubrange(20..<packet.count, with: segment)
    return packet
}

private func dhcpDiscover(from source: [UInt8]) -> [UInt8] {
    var bootp = [UInt8](repeating: 0, count: 244)
    bootp[0] = 1
    bootp[1] = 1
    bootp[2] = 6
    bootp.replaceSubrange(4..<8, with: [1, 2, 3, 4])
    bootp.replaceSubrange(28..<34, with: source)
    bootp.replaceSubrange(236..<240, with: [0x63, 0x82, 0x53, 0x63])
    bootp.replaceSubrange(240..<244, with: [53, 1, 1, 255])
    var udp = [UInt8](repeating: 0, count: 8 + bootp.count)
    udp[1] = 68
    udp[3] = 67
    let length = UInt16(udp.count)
    udp[4] = UInt8(length >> 8)
    udp[5] = UInt8(length & 0xFF)
    udp.replaceSubrange(8..<udp.count, with: bootp)
    return ethernet(from: source, type: 0x0800, payload: ipv4(source: [0, 0, 0, 0], destination: [255, 255, 255, 255], proto: 17, segment: udp))
}

private func dnsQueryFrame(name: String, from source: [UInt8]) -> [UInt8] {
    var query: [UInt8] = [0xAB, 0xCD, 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
    for label in name.split(separator: ".") {
        query.append(UInt8(label.count))
        query.append(contentsOf: label.utf8)
    }
    query += [0, 0, 1, 0, 1]
    var udp = [UInt8](repeating: 0, count: 8 + query.count)
    udp[0] = 0x12
    udp[1] = 0x34
    udp[3] = 53
    let length = UInt16(udp.count)
    udp[4] = UInt8(length >> 8)
    udp[5] = UInt8(length & 0xFF)
    udp.replaceSubrange(8..<udp.count, with: query)
    return ethernet(
        from: source, type: 0x0800,
        payload: ipv4(source: [10, 0, 2, 15], destination: [10, 0, 2, 3], proto: 17, segment: udp)
    )
}

private func tcpSyn(from source: [UInt8], destination: [UInt8], port: UInt16) -> [UInt8] {
    var tcp = [UInt8](repeating: 0, count: 20)
    tcp[0] = 0x04
    tcp[1] = 0xD2
    tcp[2] = UInt8(port >> 8)
    tcp[3] = UInt8(port & 0xFF)
    tcp[12] = 5 << 4
    tcp[13] = 0x02
    tcp[14] = 0xFF
    tcp[15] = 0xFF
    return ethernet(
        from: source, type: 0x0800,
        payload: ipv4(source: [10, 0, 2, 15], destination: destination, proto: 6, segment: tcp)
    )
}
#endif
