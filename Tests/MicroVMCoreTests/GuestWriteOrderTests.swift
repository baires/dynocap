import XCTest
@testable import MicroVMCore

final class GuestWriteOrderTests: XCTestCase {
    func testLaterStdinWaitsBehindTheQueuedExecFrame() {
        let writes = GuestWriteOrder(label: "test.guest-io")
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        var order: [String] = []
        let lock = NSLock()
        writes.async {
            started.wait()
            lock.lock()
            order.append("exec")
            lock.unlock()
        }
        Thread.detachNewThread {
            writes.sync {
                lock.lock()
                order.append("stdin")
                lock.unlock()
            }
            finished.signal()
        }
        Thread.sleep(forTimeInterval: 0.05)
        started.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(order, ["exec", "stdin"])
    }
}
