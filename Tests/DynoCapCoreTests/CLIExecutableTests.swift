import XCTest
@testable import DynoCapCore

final class CLIExecutableTests: XCTestCase {
    func testBareCommandNameUsesTheRunningBinary() {
        XCTAssertEqual(CLIExecutable.resolve(argument: "dynocap").path, CLIExecutable.current()?.path)
    }

    func testExplicitPathIsKept() {
        XCTAssertEqual(CLIExecutable.resolve(argument: "/tmp/not-the-running-dynocap").path, "/tmp/not-the-running-dynocap")
        let relative = CLIExecutable.resolve(argument: "./dynocap")
        XCTAssertNotEqual(relative.path, CLIExecutable.current()?.path)
        XCTAssertTrue(relative.path.hasSuffix("/dynocap"))
    }
}
