import XCTest

@testable import MicroVMCore

final class TTLWarningTests: XCTestCase {
    /// Steps a fake clock one second at a time and records each warning.
    private func warnings(deadline: Int64, from start: Int64, through end: Int64) -> [(now: Int64, remaining: Int64)] {
        var schedule = TTLWarningSchedule(deadline: deadline)
        return (start...end).compactMap { now in schedule.due(now: now).map { (now, $0) } }
    }

    func testEachThresholdWarnsOnceAtItsTime() {
        let seen = warnings(deadline: 10_000, from: 8_000, through: 10_010)
        XCTAssertEqual(seen.map(\.now), [9_700, 9_940])
        XCTAssertEqual(seen.map(\.remaining), [300, 60])
    }

    func testSessionOpenedInsideAThresholdWarnsImmediatelyThenAtTheNext() {
        let seen = warnings(deadline: 10_000, from: 9_800, through: 10_010)
        XCTAssertEqual(seen.map(\.now), [9_800, 9_940])
        XCTAssertEqual(seen.map(\.remaining), [200, 60])
    }

    func testShortTTLCollapsesPassedThresholdsIntoOneWarning() {
        let seen = warnings(deadline: 10_000, from: 9_970, through: 10_010)
        XCTAssertEqual(seen.map(\.now), [9_970])
        XCTAssertEqual(seen.map(\.remaining), [30])
    }

    func testNoWarningAtOrAfterExpiry() {
        XCTAssertTrue(warnings(deadline: 10_000, from: 10_000, through: 10_100).isEmpty)
        var schedule = TTLWarningSchedule(deadline: 10_000)
        XCTAssertNil(schedule.due(now: 10_001))
    }

    func testAClockThatJumpsDoesNotRepeatWarnings() {
        var schedule = TTLWarningSchedule(deadline: 10_000)
        XCTAssertNil(schedule.due(now: 9_000))
        // The host slept past both thresholds: one warning, with the time actually left.
        XCTAssertEqual(schedule.due(now: 9_950), 50)
        XCTAssertNil(schedule.due(now: 9_951))
        XCTAssertNil(schedule.due(now: 9_700), "a clock stepping back does not repeat a warning")
    }

    func testCustomThresholdsAreOrderedAndEachUsedOnce() {
        var schedule = TTLWarningSchedule(deadline: 100, thresholds: [10, 50, 30])
        XCTAssertNil(schedule.due(now: 49))
        XCTAssertEqual(schedule.due(now: 50), 50)
        XCTAssertEqual(schedule.due(now: 75), 25)
        XCTAssertNil(schedule.due(now: 80))
        XCTAssertEqual(schedule.due(now: 92), 8)
        XCTAssertNil(schedule.due(now: 95))
        XCTAssertEqual(ttlWarningThresholds, [300, 60], "documented in docs/how-to/interactive-shells-and-terminal.mdx")
    }

    func testWarningTextIsAHostDiagnosticLine() {
        let text = ttlWarningText(name: "demo", remaining: 299, deadline: 1_794_490_000)
        XCTAssertTrue(text.hasPrefix("\r\nmicrovm: demo expires in 4m 59s (2026-11-12 "), text)
        XCTAssertTrue(text.hasSuffix(".\r\n"), text)
        for part in ["UTC)", "TTL is not renewed", "unexported edits are lost", "`microvm finish demo`"] {
            XCTAssertTrue(text.contains(part), part)
        }
        XCTAssertTrue(ttlWarningText(name: "demo", remaining: 60, deadline: 0).contains("expires in 1m ("))
        XCTAssertTrue(ttlWarningText(name: "demo", remaining: 45, deadline: 0).contains("expires in 45s ("))
        XCTAssertTrue(ttlWarningText(name: "demo", remaining: 0, deadline: 0).contains("1970-01-01 00:00:00 UTC"))
    }

    func testDeadlineFrameRoundTrips() throws {
        let frame = try ControlCodec.encode(.deadline(1_794_490_000))
        XCTAssertEqual(frame, Data([0, 0, 0, 9, ControlType.deadline, 0, 0, 0, 0, 0x6a, 0xf5, 0xbe, 0x90]))
        XCTAssertEqual(try ControlCodec.decode(frame), .deadline(1_794_490_000))
        for value in [Int64(0), -1, Int64.max, Int64.min] {
            XCTAssertEqual(try ControlCodec.decode(try ControlCodec.encode(.deadline(value))), .deadline(value))
        }
        XCTAssertThrowsError(try ControlCodec.decode(Data([0, 0, 0, 5, ControlType.deadline, 0, 0, 0, 1])))
        XCTAssertThrowsError(try ControlCodec.decode(frame + Data([0])))
    }
}
