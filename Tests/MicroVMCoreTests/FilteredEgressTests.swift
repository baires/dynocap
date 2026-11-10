import XCTest
@testable import MicroVMCore

final class FilteredEgressTests: XCTestCase {
    func testDeniesPrivateLinkLocalMetadataAndHostAddresses() {
        let denied: [IPv4Address] = [
            IPv4Address(0, 0, 0, 1),
            IPv4Address(10, 1, 2, 3),
            IPv4Address(10, 0, 2, 2),
            IPv4Address(10, 0, 2, 15),
            IPv4Address(100, 64, 0, 1),
            IPv4Address(100, 127, 255, 255),
            IPv4Address(127, 0, 0, 1),
            IPv4Address(169, 254, 169, 254),
            IPv4Address(169, 254, 169, 253),
            IPv4Address(169, 254, 1, 1),
            IPv4Address(172, 16, 0, 1),
            IPv4Address(172, 31, 255, 255),
            IPv4Address(192, 168, 1, 1),
            IPv4Address(224, 0, 0, 1),
            IPv4Address(255, 255, 255, 255),
        ]
        for address in denied {
            XCTAssertTrue(FilteredEgress.denies(address.value), "\(address.octets)")
        }
        let allowed: [IPv4Address] = [
            IPv4Address(1, 1, 1, 1),
            IPv4Address(8, 8, 8, 8),
            IPv4Address(100, 63, 255, 255),
            IPv4Address(100, 128, 0, 1),
            IPv4Address(172, 15, 255, 255),
            IPv4Address(172, 32, 0, 1),
            IPv4Address(192, 167, 1, 1),
            IPv4Address(203, 0, 113, 5),
        ]
        for address in allowed {
            XCTAssertFalse(FilteredEgress.denies(address.value), "\(address.octets)")
        }
        let host = IPv4Address(203, 0, 113, 5).value
        XCTAssertTrue(FilteredEgress.denies(host, hostAddresses: [host]))
    }

    func testAllowlistIsTheRegistryAndTheRepositoryHostOnly() {
        XCTAssertTrue(FilteredEgress.allows(name: "registry.npmjs.org", repositoryHost: nil))
        XCTAssertTrue(FilteredEgress.allows(name: "Registry.NPMJS.org.", repositoryHost: nil))
        XCTAssertFalse(FilteredEgress.allows(name: "registry.npmjs.org.evil.com", repositoryHost: nil))
        XCTAssertFalse(FilteredEgress.allows(name: "github.com", repositoryHost: nil))
        XCTAssertTrue(FilteredEgress.allows(name: "GitHub.com.", repositoryHost: "github.com"))
        XCTAssertFalse(FilteredEgress.allows(name: "example.com", repositoryHost: "github.com"))
        XCTAssertEqual(
            FilteredEgress.repositoryHost("https://github.com/baires/shouldideploy.git"),
            "github.com"
        )
        XCTAssertEqual(FilteredEgress.repositoryHost("https://github.com:443/org/repo.git"), "github.com")
        XCTAssertNil(FilteredEgress.repositoryHost("git@github.com:org/repo.git"))
    }

    func testUsableAddressesDropDeniedAnswers() {
        let answers = [
            IPv4Address(1, 1, 1, 1).value,
            IPv4Address(10, 1, 2, 3).value,
            IPv4Address(169, 254, 169, 254).value,
            IPv4Address(192, 168, 1, 1).value,
            IPv4Address(1, 1, 1, 1).value,
        ]
        XCTAssertEqual(
            FilteredEgress.usable(answers, hostAddresses: []),
            [IPv4Address(1, 1, 1, 1).value]
        )
    }

    func testTCPAllowsOnlyPort443OfAJustResolvedPublicAddress() {
        let resolved: Set<UInt32> = [IPv4Address(1, 1, 1, 1).value, IPv4Address(10, 1, 2, 3).value]
        XCTAssertTrue(FilteredEgress.permitsTCP(
            destination: IPv4Address(1, 1, 1, 1).value, port: 443, resolved: resolved, hostAddresses: []
        ))
        XCTAssertFalse(FilteredEgress.permitsTCP(
            destination: IPv4Address(10, 1, 2, 3).value, port: 443, resolved: resolved, hostAddresses: []
        ))
        XCTAssertFalse(FilteredEgress.permitsTCP(
            destination: IPv4Address(1, 1, 1, 1).value, port: 80, resolved: resolved, hostAddresses: []
        ))
        XCTAssertFalse(FilteredEgress.permitsTCP(
            destination: IPv4Address(8, 8, 8, 8).value, port: 443, resolved: resolved, hostAddresses: []
        ))
        XCTAssertFalse(FilteredEgress.permitsTCP(
            destination: IPv4Address(169, 254, 169, 254).value, port: 443, resolved: [], hostAddresses: []
        ))
    }

    func testDNSAnswersOnlyAllowedNamesAndOmitsPrivateAddresses() throws {
        let registry = dnsQuery("registry.npmjs.org")
        let reply = FilteredDNS.reply(query: registry, repositoryHost: "github.com", hostAddresses: []) { _ in
            [IPv4Address(1, 2, 3, 4).value, IPv4Address(10, 1, 2, 3).value, IPv4Address(169, 254, 169, 254).value]
        }
        let answers = try XCTUnwrap(reply)
        XCTAssertEqual(answers[3] & 0x0F, 0)
        XCTAssertEqual(answers[7], 1)
        XCTAssertEqual(Array(answers.suffix(4)), [1, 2, 3, 4])
        let other = try XCTUnwrap(FilteredDNS.reply(
            query: dnsQuery("example.com"), repositoryHost: "github.com", hostAddresses: [], resolve: { _ in [IPv4Address(1, 1, 1, 1).value] }
        ))
        XCTAssertEqual(other[3] & 0x0F, 3)
        XCTAssertEqual(other[7], 0)
        let aaaa = try XCTUnwrap(FilteredDNS.reply(
            query: dnsQuery("registry.npmjs.org", type: 28), repositoryHost: nil, hostAddresses: [], resolve: { _ in [] }
        ))
        XCTAssertEqual(aaaa[3] & 0x0F, 0)
        XCTAssertEqual(aaaa[7], 0)
        let git = try XCTUnwrap(FilteredDNS.reply(
            query: dnsQuery("github.com"), repositoryHost: nil, hostAddresses: [], resolve: { _ in [IPv4Address(1, 1, 1, 1).value] }
        ))
        XCTAssertEqual(git[3] & 0x0F, 3)
    }

    func testDHCPOffersTheForwarderLink() throws {
        var discover = [UInt8](repeating: 0, count: 244)
        discover[0] = 1
        discover[1] = 1
        discover[2] = 6
        discover.replaceSubrange(4..<8, with: [9, 8, 7, 6])
        discover.replaceSubrange(236..<240, with: [0x63, 0x82, 0x53, 0x63])
        discover.replaceSubrange(240..<244, with: [53, 1, 1, 255])
        let offer = try XCTUnwrap(FilteredDHCP.reply(to: discover))
        XCTAssertEqual(Array(offer[16..<20]), [10, 0, 2, 15])
        XCTAssertEqual(Array(offer[20..<24]), [10, 0, 2, 2])
        XCTAssertTrue(offer.contains(6) && offer.contains(10))
        let options = offer[240...]
        XCTAssertTrue(options.contains([6, 4, 10, 0, 2, 3]))
        XCTAssertTrue(options.contains([3, 4, 10, 0, 2, 2]))
        XCTAssertTrue(options.contains([1, 4, 255, 255, 255, 0]))
        XCTAssertEqual(offer[242], FilteredDHCP.offer)
    }

    func testFilteredModeStaysFilteredAndPermissionsDoNotImplyEachOther() throws {
        XCTAssertThrowsError(try NetworkModeLock.rejectChange(from: .filtered, to: .nat)) { error in
            XCTAssertEqual(String(describing: error), "network mode is fixed at start")
        }
        XCTAssertNoThrow(try NetworkModeLock.rejectChange(from: .filtered, to: .filtered))
        XCTAssertEqual(
            NetworkAdmission.rejection(network: .filtered, requireOffline: true, permitFiltered: false, offlineMessage: "offline"),
            "filtered networking is disabled"
        )
        XCTAssertEqual(
            NetworkAdmission.rejection(network: .filtered, requireOffline: false, permitFiltered: false, offlineMessage: "offline"),
            "filtered networking is disabled"
        )
        XCTAssertNil(NetworkAdmission.rejection(
            network: .filtered, requireOffline: true, permitFiltered: true, offlineMessage: "offline"
        ))
        XCTAssertNil(NetworkAdmission.rejection(
            network: .filtered, requireOffline: false, permitFiltered: nil, offlineMessage: "offline"
        ))
        XCTAssertEqual(
            NetworkAdmission.rejection(network: .nat, requireOffline: true, permitFiltered: true, offlineMessage: "offline"),
            "offline"
        )
        XCTAssertNil(NetworkAdmission.rejection(network: .nat, requireOffline: false, permitFiltered: false, offlineMessage: "offline"))
        XCTAssertNil(NetworkAdmission.rejection(network: NetworkMode.none, requireOffline: true, permitFiltered: false, offlineMessage: "offline"))
        XCTAssertEqual(NetworkMode(rawValue: "filtered"), .filtered)
        XCTAssertNil(NetworkMode(rawValue: "public"))
        let encoded = try JSONEncoder().encode(NetworkMode.filtered)
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "\"filtered\"")
        let record = try JSONDecoder().decode(
            VMRecord.self,
            from: Data((
                "{\"name\":\"f\",\"phase\":\"running\",\"cpus\":1,\"memoryMB\":256,"
                + "\"daemonToken\":\"t\",\"createdAtUnix\":1,\"network\":\"filtered\"}"
            ).utf8)
        )
        XCTAssertEqual(record.network, .filtered)
    }

    func testClientHelloSNIMustMatchANameForThatAddress() {
        let registry: Set<String> = ["registry.npmjs.org"]
        let shared: Set<String> = ["registry.npmjs.org", "github.com"]
        XCTAssertEqual(FilteredTLS.firstFlight(clientHello(serverName: "registry.npmjs.org"), names: registry), .accept)
        XCTAssertEqual(FilteredTLS.firstFlight(clientHello(serverName: "Registry.NPMJS.org"), names: registry), .accept)
        XCTAssertEqual(FilteredTLS.firstFlight(clientHello(serverName: "github.com"), names: registry), .reject)
        XCTAssertEqual(FilteredTLS.firstFlight(clientHello(serverName: "github.com"), names: shared), .accept)
        XCTAssertEqual(FilteredTLS.firstFlight(clientHello(serverName: "evil.example"), names: shared), .reject)
        XCTAssertEqual(FilteredTLS.firstFlight(clientHello(serverName: nil), names: registry), .reject)
        XCTAssertEqual(
            FilteredTLS.firstFlight(clientHello(serverName: "registry.npmjs.org", ech: true), names: registry),
            .reject
        )
        let cleartext = Array("GET / HTTP/1.1\r\nHost: registry.npmjs.org\r\n\r\n".utf8)
        XCTAssertEqual(FilteredTLS.firstFlight(cleartext, names: registry), .reject)
        let hello = clientHello(serverName: "registry.npmjs.org")
        XCTAssertEqual(FilteredTLS.firstFlight(Array(hello.prefix(4)), names: registry), .needMore)
    }

    func testLookupNameIsQueriedWithATrailingDot() {
        XCTAssertEqual(FilteredEgress.absoluteLookupName("Registry.NPMJS.org"), "registry.npmjs.org.")
        XCTAssertEqual(FilteredEgress.absoluteLookupName("registry.npmjs.org."), "registry.npmjs.org.")
    }

    func testDNSReplyPublishesAtMostEightAddresses() throws {
        let addresses = (1...9).map { IPv4Address(1, 2, 3, UInt8($0)).value } + [IPv4Address(10, 1, 2, 3).value]
        let published = FilteredEgress.publishable(addresses, hostAddresses: [])
        XCTAssertEqual(published.count, 8)
        XCTAssertFalse(published.contains(IPv4Address(1, 2, 3, 9).value))
        XCTAssertFalse(published.contains(IPv4Address(10, 1, 2, 3).value))
        let reply = try XCTUnwrap(FilteredDNS.reply(
            query: dnsQuery("registry.npmjs.org"), repositoryHost: nil, hostAddresses: [], resolve: { _ in addresses }
        ))
        XCTAssertEqual(reply[7], 8)
    }
}

private func clientHello(serverName: String?, ech: Bool = false) -> [UInt8] {
    var body: [UInt8] = [0x03, 0x03] + [UInt8](repeating: 0x11, count: 32) + [0]
    body += [0x00, 0x02, 0x13, 0x01, 0x01, 0x00]
    var extensions: [UInt8] = []
    if let serverName {
        let host = Array(serverName.utf8)
        let contents = u16(UInt16(3 + host.count)) + [0] + u16(UInt16(host.count)) + host
        extensions += u16(0) + u16(UInt16(contents.count)) + contents
    }
    if ech {
        extensions += u16(0xFE0D) + u16(1) + [0]
    }
    body += u16(UInt16(extensions.count)) + extensions
    let handshake = [UInt8(1)] + u24(body.count) + body
    return [22, 0x03, 0x01] + u16(UInt16(handshake.count)) + handshake
}

private func u16(_ value: UInt16) -> [UInt8] {
    [UInt8(value >> 8), UInt8(value & 0xFF)]
}

private func u24(_ value: Int) -> [UInt8] {
    [UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
}

private func dnsQuery(_ name: String, type: UInt16 = 1) -> [UInt8] {
    var query: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    for label in name.split(separator: ".") {
        query.append(UInt8(label.count))
        query.append(contentsOf: label.utf8)
    }
    query += [0, UInt8(type >> 8), UInt8(type & 0xFF), 0x00, 0x01]
    return query
}

private extension ArraySlice where Element == UInt8 {
    func contains(_ needle: [UInt8]) -> Bool {
        guard needle.count <= count else { return false }
        for start in 0...(count - needle.count) where matches(needle, at: start) {
            return true
        }
        return false
    }

    private func matches(_ needle: [UInt8], at start: Int) -> Bool {
        let begin = index(startIndex, offsetBy: start)
        let end = index(begin, offsetBy: needle.count)
        return Array(self[begin..<end]) == needle
    }
}
