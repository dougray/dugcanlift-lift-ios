import XCTest
import AVFoundation
@testable import Lift

final class ScanAvailabilityTests: XCTestCase {
    private let allAccess: [ScanAvailability.CameraAccess] = [.notDetermined, .granted, .denied]

    /// No camera, an older device, the simulator: hidden, whatever else is true.
    func testAnUnsupportedDeviceIsUnsupportedWhateverTheCameraSays() {
        for access in allAccess {
            for available in [false, true] {
                XCTAssertEqual(ScanAvailability.current(isSupported: false, isAvailable: available,
                                                        cameraAccess: access), .unsupported)
            }
        }
    }

    /// Never asked yet (every fresh install): VisionKit reports unavailable
    /// until the person answers, so the answer is to ask, not to send them to
    /// a Settings page that has no Camera switch for LIFT yet.
    func testNotAskedYetNeedsPermission() {
        XCTAssertEqual(ScanAvailability.current(isSupported: true, isAvailable: false,
                                                cameraAccess: .notDetermined), .needsPermission)
        XCTAssertEqual(ScanAvailability.current(isSupported: true, isAvailable: true,
                                                cameraAccess: .notDetermined), .needsPermission)
    }

    func testAllowedAndAvailableIsReady() {
        XCTAssertEqual(ScanAvailability.current(isSupported: true, isAvailable: true,
                                                cameraAccess: .granted), .ready)
    }

    func testAllowedButNotAvailableIsUnavailable() {
        XCTAssertEqual(ScanAvailability.current(isSupported: true, isAvailable: false,
                                                cameraAccess: .granted), .unavailable)
    }

    func testRefusedIsUnavailable() {
        XCTAssertEqual(ScanAvailability.current(isSupported: true, isAvailable: false,
                                                cameraAccess: .denied), .unavailable)
    }

    /// Once asked, VisionKit's own answer decides; camera access only adds
    /// the "never asked" case in front of it.
    func testOnceAskedAvailabilityDecides() {
        XCTAssertEqual(ScanAvailability.current(isSupported: true, isAvailable: true,
                                                cameraAccess: .denied), .ready)
    }

    /// Restricted (parental controls, a managed phone) is a refusal the person
    /// can't undo here either, so it reads as denied, not as never asked.
    func testTheSystemsAnswerMapsToCameraAccess() {
        XCTAssertEqual(ScanAvailability.CameraAccess(.notDetermined), .notDetermined)
        XCTAssertEqual(ScanAvailability.CameraAccess(.authorized), .granted)
        XCTAssertEqual(ScanAvailability.CameraAccess(.denied), .denied)
        XCTAssertEqual(ScanAvailability.CameraAccess(.restricted), .denied)
    }

    func testTheWords() {
        XCTAssertEqual(ScanAvailability.unavailableMessage, "LIFT can't use the camera right now. You can allow it in Settings.")
        XCTAssertEqual(BarcodeLookup.notFoundMessage, "LIFT doesn't know this barcode yet. Enter it once and LIFT will remember it.")
    }
}
