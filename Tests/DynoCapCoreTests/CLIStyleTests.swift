import Foundation
import XCTest

@testable import DynoCapCore

final class CLIStyleTests: XCTestCase {
    func testColorFollowsTheDestinationAndOutputFormat() {
        let terminal = CLIStyle(isTerminal: true, environment: ["TERM": "xterm"])
        let plain = commandHelp(["clone"])
        let highlighted = commandHelp(["clone"], style: terminal)
        XCTAssertTrue(highlighted.contains("\u{1B}[36m--runtime"))
        XCTAssertEqual(highlighted.replacingOccurrences(of: "\u{1B}\\[[0-9]+m", with: "", options: .regularExpression), plain)
        for style in [
            CLIStyle(isTerminal: false, environment: ["TERM": "xterm"]),
            CLIStyle(isTerminal: true, environment: ["NO_COLOR": ""]),
            CLIStyle(isTerminal: true, environment: ["TERM": "dumb"]),
            CLIStyle(isTerminal: true, environment: ["TERM": "xterm"], output: .json),
        ] {
            XCTAssertEqual(commandHelp(["clone"], style: style), plain)
        }
    }

    func testDoctorLeadsWithFindingsAndCanExpandPassingChecks() throws {
        let report = DoctorReport(home: "/tmp/doctor", arch: "aarch64", runtimes: [], checks: [
            DoctorCheck("platform", "ok", "Platform is supported."),
            DoctorCheck("runtime", "ok", "Prepared runtimes: shell:1."),
            DoctorCheck("daemon", "error", "Daemon needs a restart.", recovery: "Run dynocap doctor --fix."),
        ])
        let style = CLIStyle(isTerminal: true, environment: [:], noColor: true)
        let compact = try formatDoctorReport(report, output: .human, style: style)
        XCTAssertTrue(compact.hasPrefix("Host needs attention\n  2 passed · 0 warnings · 1 failed\n"))
        XCTAssertTrue(compact.contains("    Next: Run dynocap doctor --fix."))
        XCTAssertTrue(compact.contains("Prepared runtimes: shell:1."))
        XCTAssertFalse(compact.contains("Platform is supported."))
        XCTAssertTrue(try formatDoctorReport(report, output: .human, style: style, verbose: true).contains("Platform is supported."))
        XCTAssertEqual(try formatDoctorReport(report, output: .json, style: style), try formatDoctorReport(report, output: .json))
    }

    func testUsageErrorLinksToTheKnownCommandHelp() {
        let style = CLIStyle(isTerminal: true, environment: [:], noColor: true)
        let result = formatCLIFailure(
            usageError("unknown flag --typo"), arguments: ["dynocap", "task", "exec", "demo", "--typo"], style: style)
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertEqual(result.text, "Error · task exec\n  unknown flag --typo\n  Next: Run dynocap task exec --help.\n")
    }

    func testDiffHighlightPreservesSplitCharactersAndSanitizesBeforeColor() {
        let patch = Data("@@ -1 +1 @@\n-café\n+🦊\u{1B}[31m".utf8)
        let expected = Data("\u{1B}[36m@@ -1 +1 @@\u{1B}[0m\n\u{1B}[31m-café\u{1B}[0m\n\u{1B}[32m+🦊^[[31m\u{1B}[0m".utf8)
        for split in 0...patch.count {
            var sanitizer = TerminalSanitizer(mode: .review)
            var highlighter = DiffHighlight()
            var output = highlighter.filter(sanitizer.filter(patch.prefix(split)))
            output.append(highlighter.filter(sanitizer.filter(patch.dropFirst(split))))
            output.append(highlighter.filter(sanitizer.finish()))
            output.append(highlighter.finish())
            XCTAssertEqual(output, expected, "byte offset \(split)")
            XCTAssertTrue(highlighter.finish().isEmpty)
        }
    }
}
