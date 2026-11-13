import XCTest
@testable import MicroVMCore

final class CLIExecutableTests: XCTestCase {
    func testBareCommandNameUsesTheRunningBinary() {
        XCTAssertEqual(CLIExecutable.resolve(argument: "microvm").path, CLIExecutable.current()?.path)
    }

    func testExplicitPathIsKept() {
        XCTAssertEqual(CLIExecutable.resolve(argument: "/tmp/not-the-running-microvm").path, "/tmp/not-the-running-microvm")
        let relative = CLIExecutable.resolve(argument: "./microvm")
        XCTAssertNotEqual(relative.path, CLIExecutable.current()?.path)
        XCTAssertTrue(relative.path.hasSuffix("/microvm"))
    }
}
