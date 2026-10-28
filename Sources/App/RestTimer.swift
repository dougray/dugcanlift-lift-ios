import Foundation
import Observation
import ActivityKit
import UserNotifications

/// Where a rest shows up outside the screen it was started on: a notification
/// when it is over, and the Live Activity. A protocol so the rules in
/// `RestTimer` can be tested without either.
@MainActor
protocol RestOutlets: AnyObject {
    func restStarted(_ rest: RestCountdown)
    func restChanged(_ rest: RestCountdown)
    func restCleared()
}

/// The iPhone's rest between sets, during a live session.
///
/// Ticking a set done starts a rest of the length in Settings -- the same
/// "Rest between sets" the watch uses, so the two never disagree. Ticking the
/// next set starts a fresh one; unticking the set that started a rest takes
/// it back; ending the session ends it. The rest is kept in `UserDefaults`, so
/// iOS ending LIFT mid-rest does not lose it, and one long over is dropped on
/// the way back in rather than greeting someone the next morning.
@MainActor
@Observable
final class RestTimer {
    static let shared = RestTimer(outlets: SystemRestOutlets(), defaults: .standard)

    static let storageKey = "phoneRestCountdown"
    /// How long "Rest over" stays on screen once it is.
    static let keepsOverFor: TimeInterval = 120
    static let step: TimeInterval = 15

    private(set) var current: RestCountdown?

    @ObservationIgnored private let outlets: RestOutlets
    @ObservationIgnored private let defaults: UserDefaults

    init(outlets: RestOutlets, defaults: UserDefaults) {
        self.outlets = outlets
        self.defaults = defaults
        current = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(RestCountdown.self, from: $0) }
    }

    /// `restSeconds` nil is the watch setting's "no rest": nothing starts.
    func setDone(_ setID: UUID, exerciseName: String?, restSeconds: Int?, now: Date = .now) {
        guard let restSeconds, restSeconds > 0 else { return }
        let rest = RestCountdown(seconds: TimeInterval(restSeconds), setID: setID,
                                 exerciseName: exerciseName, now: now)
        store(rest)
        outlets.restStarted(rest)
    }

    func setUndone(_ setID: UUID) {
        guard current?.setID == setID else { return }
        clear()
    }

    func adjust(by seconds: TimeInterval, now: Date = .now) {
        guard let rest = current?.adjusted(by: seconds, now: now) else { return }
        store(rest)
        outlets.restChanged(rest)
    }

    func skip() {
        guard current != nil else { return }
        clear()
    }

    func sessionEnded() { skip() }

    /// On the way back into the app: a rest over for a while is done with.
    func restore(now: Date = .now) {
        guard let rest = current,
              now.timeIntervalSince(rest.endsAt) > Self.keepsOverFor else { return }
        clear()
    }

    private func store(_ rest: RestCountdown) {
        current = rest
        defaults.set(try? JSONEncoder().encode(rest), forKey: Self.storageKey)
    }

    private func clear() {
        current = nil
        defaults.removeObject(forKey: Self.storageKey)
        outlets.restCleared()
    }
}

/// The real outlets: a local notification at the end of the rest, which is
/// what reaches someone whose phone is locked in a pocket, and a Live Activity
/// counting down on the lock screen and in the Dynamic Island.
///
/// Both are local. The notification is scheduled on the phone for a time on
/// the phone; nothing is pushed from anywhere.
@MainActor
final class SystemRestOutlets: NSObject, RestOutlets, UNUserNotificationCenterDelegate {
    static let notificationID = "lift.rest.over"

    private var activity: Activity<RestActivityAttributes>?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        // One left over from a run of LIFT that iOS ended.
        activity = Activity<RestActivityAttributes>.activities.first
    }

    func restStarted(_ rest: RestCountdown) {
        schedule(rest)
        if let activity {
            update(activity, to: rest)
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            activity = try? Activity.request(
                attributes: RestActivityAttributes(),
                content: ActivityContent(state: rest, staleDate: rest.endsAt))
        }
    }

    func restChanged(_ rest: RestCountdown) {
        schedule(rest)
        if let activity { update(activity, to: rest) }
    }

    func restCleared() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [Self.notificationID])
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private func update(_ activity: Activity<RestActivityAttributes>, to rest: RestCountdown) {
        Task { await activity.update(ActivityContent(state: rest, staleDate: rest.endsAt)) }
    }

    /// Asked the first time a rest starts, which is the first time it means
    /// anything. Refused, the timer still runs on screen and on the lock
    /// screen; only the alert at the end is missing.
    private func schedule(_ rest: RestCountdown) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
        let seconds = rest.remaining(at: .now)
        guard seconds > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Rest over"
        content.body = rest.exerciseName.map { "Back to \($0)." } ?? "Time for your next set."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: Self.notificationID, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false))

        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(request)
        }
    }

    /// On screen, the rest banner says it is over and the phone taps; the
    /// sound is all the notification needs to add.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        notification.request.identifier == Self.notificationID ? [.sound] : [.banner, .sound]
    }
}
