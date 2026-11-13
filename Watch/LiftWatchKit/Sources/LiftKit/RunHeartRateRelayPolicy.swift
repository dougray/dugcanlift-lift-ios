import Foundation

/// The watch's side of path B, as values: when it relays heart rate to a run
/// the phone records, and when it stops.
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

    public enum Next: Equatable {
        case mirrorAgain
        case keepRelaying
        case end
    }

    /// How many times a lost phone is asked again before the relay ends.
    public static let mirroringRetries = 3

    /// The phone dropped off the mirrored session. It is asked again a few
    /// times, the same source reconnecting; after that the relay ends, so a
    /// phone that is gone (or a run that ended there without a word) never
    /// leaves a workout running on the wrist.
    public static func afterDisconnect(retriesSoFar: Int) -> Next {
        retriesSoFar < mirroringRetries ? .mirrorAgain : .end
    }

    /// A session that cannot reach the phone has no one to send to.
    public static func afterMirroring(succeeded: Bool) -> Next {
        succeeded ? .keepRelaying : .end
    }

    /// The HealthKit quantity types the relay's data source keeps, by
    /// identifier (`HKQuantityTypeIdentifier.heartRate.rawValue`); every other
    /// type the data source would collect for the configuration is turned
    /// off. Spelled as a string so this package needs no HealthKit.
    public static let collectedTypeIdentifiers: Set<String> = ["HKQuantityTypeIdentifierHeartRate"]
}
