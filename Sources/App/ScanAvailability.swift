import Foundation

/// Whether food search offers "Scan a barcode", and what tapping it does.
/// `unsupported` (no camera, an older device, the simulator) hides the row;
/// `unavailable` (camera access refused or restricted) keeps it and says how
/// to allow the camera, rather than leaving someone wondering where it went.
enum ScanAvailability: Equatable {
    case unsupported, unavailable, ready

    static let unavailableMessage = "LIFT can't use the camera right now. You can allow it in Settings."

    static func current(isSupported: Bool, isAvailable: Bool) -> ScanAvailability {
        guard isSupported else { return .unsupported }
        return isAvailable ? .ready : .unavailable
    }
}
