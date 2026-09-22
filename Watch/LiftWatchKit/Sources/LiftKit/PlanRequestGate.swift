import Foundation

/// Decides whether the watch should send a `PLAN_REQUEST` now, so that
/// several triggers landing together ask the phone once.
///
/// Three things ask for today's plan: the app becoming active, the phone
/// becoming reachable, and the lifter tapping "Get Today's Plan". The first
/// two routinely happen within milliseconds of each other — raising a wrist
/// both foregrounds the app and brings the phone back into reach — and on a
/// paired simulator pair every launch sent two requests 1 ms apart, so the
/// phone built and sent the plan twice. The revision rule made the second
/// push harmless on arrival, but it was still twice the traffic, twice the
/// plan building on the phone, and twice the battery on the wrist.
///
/// The rule, per `window`:
/// - A request that went out while the phone was reachable (`sendMessage`,
///   whose answer is already on its way) suppresses every other request.
/// - A request that could only be queued (`transferUserInfo`, the phone out
///   of reach) suppresses further queued ones, but not a reachable one: the
///   phone coming back is exactly when the fast path is worth taking, and the
///   queued request may not be delivered for a long time.
/// - A deliberate tap always goes (`force`). No plan today gets no reply at
///   all, so nothing here can know the earlier request was answered.
///
/// A value type with no WatchConnectivity in it, so the rule is testable.
public struct PlanRequestGate: Equatable, Sendable {

    /// Long enough to cover a phone building and replying to a plan (about
    /// three seconds on a simulator pair), short enough that a lifter who
    /// comes back to the app a minute later asks again.
    public static let window: TimeInterval = 10

    private var lastSentAt: Date?
    private var lastWasLive = false

    public init() {}

    /// Whether to send a request now. Records it when the answer is yes, so
    /// call it only when the request will actually be sent.
    public mutating func shouldRequest(reachable: Bool, now: Date, force: Bool = false) -> Bool {
        if !force, let lastSentAt {
            // A negative gap is a clock that moved backwards, not a recent
            // request, and must not hold the gate shut.
            let elapsed = now.timeIntervalSince(lastSentAt)
            if elapsed >= 0, elapsed < Self.window, lastWasLive || !reachable {
                return false
            }
        }
        lastSentAt = now
        lastWasLive = reachable
        return true
    }
}

/// Turns WatchConnectivity's reachability callbacks into changes.
///
/// `PhoneSyncTransport` hears about reachability from two delegate methods:
/// activation completing, which reports the current value, and
/// `sessionReachabilityDidChange`. When activation already finds the phone
/// reachable, the second one follows with the same value, and each used to be
/// passed on as if the phone had just come back, flushing the outbox and
/// requesting a plan twice. Only a change is passed on now.
public struct ReachabilityTracker: Equatable, Sendable {
    private var last: Bool?

    public init() {}

    /// The new value when it differs from the last one reported, otherwise
    /// `nil`. The first report always counts, reachable or not.
    public mutating func update(_ reachable: Bool) -> Bool? {
        guard reachable != last else { return nil }
        last = reachable
        return reachable
    }
}
