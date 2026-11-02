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
    /// The session is over: anything still on the lock screen goes, even an
    /// activity left from a run of LIFT that iOS ended.
    func sessionEnded()
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

    /// What the banner says when a tick starts no rest: "Next: Seated Cable
    /// Rows" inside a superset round, "Drop set next" before a drop set
    /// (`SessionRest`). Never at the same time as a rest. Not kept across a
    /// relaunch: it has no end time, and the next tick says it again.
    struct Cue: Equatable {
        var setID: UUID
        var text: String
    }

    private(set) var cue: Cue?

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
        cue = nil
        guard let restSeconds, restSeconds > 0 else { return }
        let rest = RestCountdown(seconds: TimeInterval(restSeconds), setID: setID,
                                 exerciseName: exerciseName, now: now)
        store(rest)
        outlets.restStarted(rest)
    }

    /// A tick that starts no rest. A rest still running is over -- the next
    /// set has begun -- and the banner says what comes next instead.
    func setDone(_ setID: UUID, noRest text: String) {
        if current != nil { clear() }
        cue = Cue(setID: setID, text: text)
    }

    /// What `SessionRest` decided, carried out. Everything that is not a set
    /// type's case goes through `setDone(_:exerciseName:restSeconds:)` as it
    /// always did.
    func setDone(_ setID: UUID, after: SessionRest.After, exerciseName: String?, now: Date = .now) {
        switch after {
        case let .rest(seconds, before):
            setDone(setID, exerciseName: before ?? exerciseName, restSeconds: seconds, now: now)
        case let .noRest(text):
            setDone(setID, noRest: text)
        case .nothing:
            setDone(setID, exerciseName: exerciseName, restSeconds: nil, now: now)
        }
    }

    func setUndone(_ setID: UUID) {
        if cue?.setID == setID { cue = nil }
        guard current?.setID == setID else { return }
        clear()
    }

    func adjust(by seconds: TimeInterval, now: Date = .now) {
        guard let rest = current?.adjusted(by: seconds, now: now) else { return }
        store(rest)
        outlets.restChanged(rest)
    }

    func skip() {
        cue = nil
        guard current != nil else { return }
        clear()
    }

    func sessionEnded() {
        skip()
        outlets.sessionEnded()
    }

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

    private var activityStorage: Activity<RestActivityAttributes>?
    /// The end time of the rest a notification is wanted for, or nil. Checked
    /// again once permission has been answered, which takes a round trip: a
    /// rest skipped or moved in the meantime must not get the old alert.
    private var scheduledFor: Date?
    private var askedForNotifications = false

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        // One left over from a run of LIFT that iOS ended.
        activityStorage = Activity<RestActivityAttributes>.activities.first(where: Self.isLive)
    }

    /// The activity, while iOS still shows it. One swiped off the lock screen
    /// or ended by iOS is gone for good: updating it does nothing, so the next
    /// rest has to ask for a new one.
    private var activity: Activity<RestActivityAttributes>? {
        guard let activityStorage, Self.isLive(activityStorage) else { return nil }
        return activityStorage
    }

    private static func isLive(_ activity: Activity<RestActivityAttributes>) -> Bool {
        activity.activityState == .active || activity.activityState == .stale
    }

    func restStarted(_ rest: RestCountdown) {
        schedule(rest)
        if let activity {
            update(activity, to: rest)
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            activityStorage = try? Activity.request(
                attributes: RestActivityAttributes(),
                content: ActivityContent(state: rest, staleDate: rest.endsAt))
        }
    }

    func restChanged(_ rest: RestCountdown) {
        schedule(rest)
        if let activity { update(activity, to: rest) }
    }

    func restCleared() {
        scheduledFor = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [Self.notificationID])
        guard let activity = activityStorage else { return }
        activityStorage = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    func sessionEnded() {
        restCleared()
        for leftover in Activity<RestActivityAttributes>.activities {
            Task { await leftover.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func update(_ activity: Activity<RestActivityAttributes>, to rest: RestCountdown) {
        Task { await activity.update(ActivityContent(state: rest, staleDate: rest.endsAt)) }
    }

    /// Permission is asked the first time a rest starts, which is the first
    /// time it means anything. Refused, the timer still runs on screen and on
    /// the lock screen; only the alert at the end is missing.
    ///
    /// Everything here is on the main actor and in order. The time left is
    /// worked out after permission is answered, so a first rest's alert is
    /// not late by however long the prompt was up, and only if this is still
    /// the rest wanted.
    private func schedule(_ rest: RestCountdown) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
        scheduledFor = rest.endsAt
        Task { @MainActor in
            if !askedForNotifications {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
                askedForNotifications = true
            }
            guard scheduledFor == rest.endsAt,
                  await center.notificationSettings().authorizationStatus == .authorized,
                  scheduledFor == rest.endsAt else { return }
            let seconds = rest.remaining(at: .now)
            guard seconds > 0 else { return }

            let content = UNMutableNotificationContent()
            content.title = "Rest over"
            content.body = rest.exerciseName.map { "Back to \($0)." } ?? "Time for your next set."
            content.sound = .default
            try? await center.add(UNNotificationRequest(
                identifier: Self.notificationID, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)))
            // Skipped or moved while that was being added: take it back.
            if scheduledFor != rest.endsAt {
                center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
            }
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
