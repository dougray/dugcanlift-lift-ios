import Foundation

/// When LIFT may put Apple Health's permission sheet in front of someone.
///
/// The rule is **ask once, then never again on its own**. Home used to call
/// `requestAuthorization` from its `.task`, so every launch asked -- and a
/// "Don't Allow" was answered with the same question the next time the app
/// opened. Now the automatic ask (first run, from Home's Steps card) happens
/// only while the app has never asked, and after that only a tap on
/// "Connect Apple Health" can ask again, and only while HealthKit itself says
/// there is something left to ask about. Once there is not, the answer is
/// Settings, not another sheet.
///
/// "Has asked" is the app's own record (`askedKey` in `UserDefaults`), because
/// HealthKit never reveals whether *read* access was denied -- an app that
/// could tell would know the person had something to hide. HealthKit's own
/// request status fills the gap for installs that answered before the flag
/// existed: `.unnecessary` means the sheet has already been shown for every
/// type LIFT asks about, so it counts as asked.
///
/// A value type with no HealthKit in it, so the rule is testable.
enum HealthAuthorization {

    /// The `UserDefaults` key recording that the sheet has been shown.
    static let askedKey = "healthAuthorizationRequested"

    /// HealthKit's `HKAuthorizationRequestStatus`, without the import.
    enum SystemStatus: Equatable {
        /// Some type LIFT uses has never been put to the person.
        case shouldRequest
        /// Every type has been put to the person already. The sheet would
        /// not appear; asking again does nothing.
        case unnecessary
        /// HealthKit could not say (or is unavailable).
        case unknown
    }

    /// What prompted the question.
    enum Trigger: Equatable {
        /// The app on its own -- a screen appearing, a launch.
        case automatic
        /// The person tapped "Connect Apple Health".
        case userAction
    }

    enum Decision: Equatable {
        /// Show HealthKit's permission sheet.
        case request
        /// Do nothing; read whatever Health gives and degrade quietly.
        case skip
        /// The sheet will not come back; send the person to Settings.
        case openSettings
    }

    /// Whether the app counts as having asked, from its own flag and
    /// HealthKit's status together.
    static func hasAsked(flag: Bool, status: SystemStatus) -> Bool {
        flag || status == .unnecessary
    }

    static func decide(trigger: Trigger, askedFlag: Bool, status: SystemStatus) -> Decision {
        let asked = hasAsked(flag: askedFlag, status: status)
        switch trigger {
        case .automatic:
            // Once, ever. An update that adds a type does not re-ask on
            // launch either: a new feature asks when it is used, from a tap.
            return asked ? .skip : .request
        case .userAction:
            switch status {
            case .unnecessary: return .openSettings
            case .shouldRequest: return .request
            case .unknown: return asked ? .openSettings : .request
            }
        }
    }
}

/// Which Apple Health block Settings shows, decided from facts rather than
/// read off the view, so the order of the checks is testable.
///
/// "Connected" means LIFT may write workouts. It used to be checked before
/// HealthKit's request status, which hid the Connect button from everyone who
/// had already allowed workouts -- including after an update added heart rate
/// and VO2 max to what LIFT reads. Nothing else asks for a type added later
/// (an automatic ask happens once, ever), and iOS lists only requested types
/// under Settings > Health > LIFT, so a connected person whose status is still
/// `shouldRequest` is shown the button as well.
enum HealthSettingsLayout: Equatable {
    /// No Health on this device.
    case unavailable
    /// Workouts are allowed and HealthKit has nothing left to ask.
    case connected
    /// Workouts are allowed, but some type LIFT reads was never put to the
    /// person: the connected block, and the Connect button.
    case connectedWithConnect
    /// Asked already for everything and not allowed workouts: the sheet will
    /// not come back, so Settings.
    case openSettings
    /// Never asked, or HealthKit could not say.
    case connect

    static func of(isAvailable: Bool, isWorkoutWritingAuthorized: Bool,
                   status: HealthAuthorization.SystemStatus) -> HealthSettingsLayout {
        guard isAvailable else { return .unavailable }
        if isWorkoutWritingAuthorized {
            return status == .shouldRequest ? .connectedWithConnect : .connected
        }
        return status == .unnecessary ? .openSettings : .connect
    }

    var showsConnected: Bool { self == .connected || self == .connectedWithConnect }
    var showsConnectButton: Bool { self == .connect || self == .connectedWithConnect }
}

#if canImport(UIKit)
import UIKit

/// Where to send someone once the sheet will not come back. iOS gives no URL
/// for Health's per-app page, so this opens LIFT's own Settings page and the
/// text beside every use of it names the path to Health.
enum HealthSettingsLink {
    @MainActor
    static func open() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
#endif
