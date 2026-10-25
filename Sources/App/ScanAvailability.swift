import AVFoundation
import Foundation

/// Whether food search offers "Scan a barcode", and what tapping it does.
/// `unsupported` (no camera, an older device, the simulator) hides the row;
/// `needsPermission` (never asked, every fresh install) keeps it and asks for
/// the camera on tap; `unavailable` (camera access refused or restricted)
/// keeps it and says how to allow the camera, rather than leaving someone
/// wondering where it went.
enum ScanAvailability: Equatable {
    case unsupported, needsPermission, unavailable, ready

    /// The camera permission, as far as scanning cares.
    enum CameraAccess: Equatable {
        case notDetermined, granted, denied

        init(_ status: AVAuthorizationStatus) {
            switch status {
            case .notDetermined: self = .notDetermined
            case .authorized: self = .granted
            case .denied, .restricted: self = .denied
            @unknown default: self = .denied
            }
        }
    }

    static let unavailableMessage = "LIFT can't use the camera right now. You can allow it in Settings."

    /// VisionKit reports the scanner unavailable until the camera has been
    /// allowed, so a phone that was never asked would otherwise be sent to a
    /// Settings page with no Camera switch for LIFT on it.
    static func current(isSupported: Bool, isAvailable: Bool, cameraAccess: CameraAccess) -> ScanAvailability {
        guard isSupported else { return .unsupported }
        if cameraAccess == .notDetermined { return .needsPermission }
        return isAvailable ? .ready : .unavailable
    }
}
