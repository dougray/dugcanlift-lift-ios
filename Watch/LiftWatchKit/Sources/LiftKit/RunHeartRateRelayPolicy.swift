import Foundation

/// The watch's side of path B, as values: when it relays heart rate to a run
/// the phone records, how it reconnects, and when it gives up.
///
/// The relay (`Watch/LiftWatch/RunHeartRateRelay.swift`) runs an
/// `HKWorkoutSession` mirrored to the phone and saves nothing: the phone
/// exports the run. watchOS allows one live workout session, so the watch's own
/// run or lift always comes first -- the relay does not start while one is
/// going, and steps aside when one starts.
public enum RunHeartRateRelayPolicy {

    /// Start only when the watch is recording nothing of its own and is not
    /// already relaying.
    public static func shouldStart(watchBusy: Bool, relaying: Bool) -> Bool {
        !watchBusy && !relaying
    }

    /// The first mirroring, when the phone has just asked: a phone that
    /// cannot be reached at that moment has no run to send to.
    public static func afterFirstMirroring(succeeded: Bool) -> Bool {
        succeeded
    }

    /// The waits before each try at reaching a phone that dropped off, in
    /// order. After the last one fails the relay ends: a phone that is gone
    /// must not leave a workout running on the wrist.
    public static let reconnectDelays: [TimeInterval] = [2, 5, 10]

    /// No connection to the phone for this long ends the relay, whatever
    /// else happened -- the backstop for a phone whose end of the session
    /// never reached the watch. Five minutes outlasts every reconnect wait
    /// several times over and is still short for a battery.
    public static let unheardLimit: TimeInterval = 5 * 60

    /// Whether the relay has gone unheard too long. `lastHeard` is the last
    /// time the phone was known to be there (mirroring succeeded or a reading
    /// was delivered), or the relay's start when it never was.
    public static func isUnheardTooLong(lastHeard: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastHeard) >= unheardLimit
    }

    /// What the relay does next.
    public enum Step: Equatable {
        /// Wait this long, then try mirroring to the phone again.
        case mirrorAgain(after: TimeInterval)
        /// End the session and discard its workout.
        case end
    }

    /// Reconnecting a phone that dropped off: the same source, tried again
    /// after a wait that grows, up to `reconnectDelays.count` tries. The count
    /// starts over only when a reading reaches the phone again -- a mirroring
    /// call that returns is not proof the phone is listening.
    public struct Reconnect: Equatable {
        public private(set) var failedTries = 0
        /// Whether a disconnect is being handled (waiting or trying).
        public private(set) var reconnecting = false

        public init() {}

        /// The phone dropped off.
        public mutating func disconnected() -> Step {
            reconnecting = true
            return next()
        }

        /// A try at mirroring again failed.
        public mutating func tryFailed() -> Step {
            failedTries += 1
            return next()
        }

        /// A try at mirroring again succeeded. The count is kept until a
        /// reading gets through.
        public mutating func trySucceeded() {
            reconnecting = false
        }

        /// A reading reached the phone: it is really back.
        public mutating func readingDelivered() {
            failedTries = 0
            reconnecting = false
        }

        private func next() -> Step {
            let delays = RunHeartRateRelayPolicy.reconnectDelays
            return failedTries < delays.count ? .mirrorAgain(after: delays[failedTries]) : .end
        }
    }

    /// The HealthKit quantity types the relay's data source keeps, by
    /// identifier (`HKQuantityTypeIdentifier.heartRate.rawValue`); every other
    /// type the data source would collect for the configuration is turned
    /// off. Spelled as a string so this package needs no HealthKit.
    public static let collectedTypeIdentifiers: Set<String> = ["HKQuantityTypeIdentifierHeartRate"]
}
