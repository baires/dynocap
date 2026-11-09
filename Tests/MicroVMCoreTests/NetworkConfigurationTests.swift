#if os(macOS)
import XCTest
import MicroVMCore
import Virtualization
@testable import MicroVMVZ

final class NetworkConfigurationTests: XCTestCase {
    func testOfflineHasNoNICAndNATHasExactlyOneNATAttachment() {
        XCTAssertTrue(networkDevices(for: .none).isEmpty)
        let devices = networkDevices(for: .nat)
        XCTAssertEqual(devices.count, 1)
        XCTAssertTrue(devices.first?.attachment is VZNATNetworkDeviceAttachment)
    }
}
#endif
