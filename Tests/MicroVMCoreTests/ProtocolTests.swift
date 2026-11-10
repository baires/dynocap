import XCTest
@testable import MicroVMCore

final class ProtocolTests: XCTestCase {
    func testGoldenVectors() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("testdata/protocol-vectors.json")
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(VectorFile.self, from: data)
        let byName = Dictionary(uniqueKeysWithValues: file.frames.map { ($0.name, hexData($0.hex)) })
        let cases: [(String, GuestMessage)] = [
            ("hello", .hello(version: 1, agent: "microvm-agent")),
            ("exec-uname", .exec(ExecStart(id: 7, timeoutMS: 5000, argv: ["uname", "-a"], env: [], cwd: ""))),
            ("exec-shell", .exec(ExecStart(id: 9, timeoutMS: 0, argv: ["sh", "-c", "echo hello"], env: ["FOO=bar"], cwd: "/tmp"))),
            ("stdin-eof", .stdinEOF(id: 7)),
            ("stdin-binary", .stdin(id: 7, data: Data([0, 255, 10]))),
            ("kill", .kill(id: 7)),
            ("shutdown", .shutdown),
            ("started", .started(id: 7)),
            ("stdout-hello", .stdout(id: 7, data: Data("hello\n".utf8))),
            ("stderr-warn", .stderr(id: 7, data: Data("warn".utf8))),
            ("exit-ok", .exit(id: 7, code: 0, signal: 0)),
            ("exit-signal", .exit(id: 3, code: -1, signal: 9)),
            ("error-boom", .error(id: 7, message: "boom")),
        ]
        XCTAssertEqual(cases.count, byName.count)
        for (name, message) in cases {
            let encoded = try GuestProtocol.encodeFrame(message)
            XCTAssertEqual(encoded, byName[name], name)
            let decoded = try GuestProtocol.decodeFrame(encoded)
            XCTAssertEqual(decoded, message, name)
        }
    }

    func testRejects() {
        XCTAssertThrowsError(try GuestProtocol.encode(.exec(ExecStart(id: 1, timeoutMS: 0, argv: [], env: [], cwd: ""))))
        XCTAssertThrowsError(try GuestProtocol.decode(Data([0x99])))
        XCTAssertThrowsError(try GuestProtocol.decodeFrame(Data([0x01, 0, 0, 0])))
    }

    func testRoundTripOverSocket() throws {
        let (a, b) = try POSIX.socketpair()
        let left = GuestLink(fd: a)
        let right = GuestLink(fd: b)
        let message = GuestMessage.exec(ExecStart(id: 4, timeoutMS: 10, argv: ["uname", "-a"], env: ["PATH=/bin"], cwd: "/"))
        try left.write(message)
        try left.write(.stdout(id: 4, data: Data("Linux\n".utf8)))
        XCTAssertEqual(try right.read(), message)
        XCTAssertEqual(try right.read(), .stdout(id: 4, data: Data("Linux\n".utf8)))
    }
}

final class ControlTests: XCTestCase {
    func testRoundTrip() throws {
        let run = RunRequest(name: "demo", cpus: 2, memoryMB: 1024, ttlSeconds: nil, bootTimeoutSeconds: 30)
        let frame = try ControlCodec.encode(.run(run))
        guard case .run(let decoded) = try ControlCodec.decode(frame) else {
            return XCTFail("expected run")
        }
        XCTAssertEqual(decoded, run)

        let exitFrame = try ControlCodec.encode(.exit(code: 124, signal: 0))
        guard case .exit(let code, let signal) = try ControlCodec.decode(exitFrame) else {
            return XCTFail("expected exit")
        }
        XCTAssertEqual(code, 124)
        XCTAssertEqual(signal, 0)
        _ = exitFrame

        let err = try ControlCodec.encode(.error("timed out"))
        guard case .error(let text) = try ControlCodec.decode(err) else {
            return XCTFail("expected error")
        }
        XCTAssertEqual(text, "timed out")
    }
}

private struct VectorFile: Decodable {
    struct Frame: Decodable {
        var name: String
        var hex: String
    }
    var frames: [Frame]
}

private func hexData(_ hex: String) -> Data {
    var out = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        out.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return out
}
