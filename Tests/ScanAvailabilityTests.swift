import XCTest
@testable import Lift

final class ScanAvailabilityTests: XCTestCase {
    func testStates() {
        XCTAssertEqual(ScanAvailability.current(isSupported: false, isAvailable: false), .unsupported)
        XCTAssertEqual(ScanAvailability.current(isSupported: true, isAvailable: false), .unavailable)
        XCTAssertEqual(ScanAvailability.current(isSupported: true, isAvailable: true), .ready)
    }
    func testTheWords() {
        XCTAssertEqual(ScanAvailability.unavailableMessage, "LIFT can't use the camera right now. You can allow it in Settings.")
        XCTAssertEqual(BarcodeLookup.notFoundMessage, "LIFT doesn't know this barcode yet. Enter it once and LIFT will remember it.")
    }
}
