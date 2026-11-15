import Foundation
import XCTest

@testable import DynoCapCore

final class TerminalOutputTests: XCTestCase {
    private func run(_ mode: TerminalSanitizer.Mode, _ chunks: [String]) -> String {
        var sanitizer = TerminalSanitizer(mode: mode)
        var out = Data()
        for chunk in chunks { out += sanitizer.filter(Data(chunk.utf8)) }
        out += sanitizer.finish()
        return String(decoding: out, as: UTF8.self)
    }

    func testStreamKeepsTextColorsAndProgressBars() {
        let text = "plain\ttab\n\u{1B}[1;31mred\u{1B}[0m\n\u{1B}[2K\r 50%\u{1B}[1G100%\u{8}\nhéllo — ok\n"
        XCTAssertEqual(run(.stream, [text]), text)
    }

    func testStreamDropsSequencesThatActOnTheHostTerminal() {
        for attack in [
            "\u{1B}]52;c;cGF5bG9hZA==\u{07}",  // clipboard write
            "\u{1B}]0;fake title\u{1B}\\",  // window title, ST-terminated
            "\u{1B}]8;;https://evil.example\u{1B}\\link\u{1B}]8;;\u{1B}\\",  // hyperlink
            "\u{1B}P+q544e\u{1B}\\",  // DCS query
            "\u{1B}_payload\u{1B}\\",  // APC
            "\u{1B}[6n", "\u{1B}[21t", "\u{1B}[?1049h", "\u{1B}[3A", "\u{1B}[>c",  // reports, alt screen, cursor up
            "\u{1B}c", "\u{1B}7",  // reset, save cursor
            "\u{9B}31m",  // C1 CSI
            "\u{07}\u{0}\u{7F}",  // bell, NUL, DEL
        ] {
            let shown = run(.stream, ["before", attack, "after"])
            XCTAssertFalse(shown.unicodeScalars.contains { $0.value == 0x1B || $0.value == 0x9B || $0.value == 0x07 }, attack.debugDescription)
            XCTAssertTrue(shown.hasPrefix("before") && shown.hasSuffix("after"), "\(attack.debugDescription) -> \(shown.debugDescription)")
            XCTAssertFalse(shown.contains("evil") || shown.contains("fake") || shown.contains("payload"), shown.debugDescription)
        }
        XCTAssertEqual(run(.stream, ["before\u{1B}]8;;https://x\u{1B}\\link\u{1B}]8;;\u{1B}\\after"]), "beforelinkafter")
    }

    func testSequencesSplitAcrossChunksAreStillRecognized() {
        XCTAssertEqual(run(.stream, ["a\u{1B}", "]52;c;", "aGk=", "\u{07}b"]), "ab")
        XCTAssertEqual(run(.stream, ["\u{1B}[3", "1mred"]), "\u{1B}[31mred")
        let c1 = Array("\u{9B}".utf8)
        var sanitizer = TerminalSanitizer(mode: .stream)
        var out = sanitizer.filter(Data([UInt8(ascii: "x"), c1[0]]))
        out += sanitizer.filter(Data([c1[1], UInt8(ascii: "y")]))
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "xy")
        let override = Array("\u{202E}".utf8)
        var review = TerminalSanitizer(mode: .review)
        var shown = review.filter(Data(override.prefix(2)))
        shown += review.filter(Data(override.suffix(1)))
        XCTAssertEqual(String(decoding: shown, as: UTF8.self), "<U+202E>")
    }

    func testAnUnfinishedSequenceIsDroppedAndASplitCharacterKept() {
        XCTAssertEqual(run(.stream, ["text\u{1B}]0;never closed"]), "text")
        var sanitizer = TerminalSanitizer(mode: .stream)
        let dash = Array("—".utf8)
        var out = sanitizer.filter(Data(dash.prefix(2)))
        out += sanitizer.finish()
        XCTAssertEqual(Array(out), Array(dash.prefix(2)), "a truncated character is passed through, not swallowed")
    }

    func testReviewShowsEverythingAndInterpretsNothing() {
        XCTAssertEqual(run(.review, ["+ok\u{1B}[31mred\r\u{07}\n"]), "+ok^[[31mred^M^G\n")
        XCTAssertEqual(
            run(.review, ["+if (admin) {\u{202E} } \u{2066}// x\u{2069}\u{200B}\u{FEFF}\n"]),
            "+if (admin) {<U+202E> } <U+2066>// x<U+2069><U+200B><U+FEFF>\n")
        XCTAssertEqual(run(.review, ["\u{9B}6n"]), "<U+009B>6n")
        let text = "diff --git a/x b/x\n+héllo — “quoted” 日本\n\tindented\n"
        XCTAssertEqual(run(.review, [text]), text)
    }

    func testLogReplayFiltersOnlyWhenAskedTo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("logs-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data("ok\u{1B}]52;c;aGk=\u{07}\n".utf8)
        try payload.write(to: directory.appendingPathComponent("0.stdout"))
        try Data().write(to: directory.appendingPathComponent("0.stderr"))
        let logs = ExecutionLogs(
            id: "task-x", name: "demo", resultExpiresAtUnix: 0, directory: directory.path,
            executions: [
                RecordedExecution(
                    id: 0, command: "echo", state: "exited", startedAtUnix: 1, endedAtUnix: 2, exitCode: 0, format: "separate",
                    stdout: RecordedLogStream(fileName: "0.stdout", bytes: Int64(payload.count), expectedBytes: nil, integrity: "complete"),
                    stderr: RecordedLogStream(fileName: "0.stderr", bytes: 0, expectedBytes: nil, integrity: "complete"))
            ])
        for filtered in [false, true] {
            let out = directory.appendingPathComponent("out-\(filtered)")
            FileManager.default.createFile(atPath: out.path, contents: nil)
            let handle = try FileHandle(forWritingTo: out)
            try replayExecutionLogs(
                logs, execution: 0, stdout: handle, stderr: handle,
                stdoutFilter: filtered ? TerminalSanitizer(mode: .stream) : nil)
            try handle.close()
            let written = try Data(contentsOf: out)
            XCTAssertEqual(written, filtered ? Data("ok\n".utf8) : payload)
        }
    }
}
