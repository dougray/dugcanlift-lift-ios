import Foundation

/// Caches the most recent `RecentFoodsSnapshot` the phone has pushed, so the
/// watch's recent-foods list has something to show even before it talks to
/// the phone again after a relaunch. This repo has no other on-disk
/// persistence anywhere (`docs/ARCHITECTURE.md`) — `UserDefaults` is
/// deliberately the simplest thing that works for one small, infrequently-
/// written JSON blob; this is new work, not a port of an existing pattern.
public final class RecentFoodsSnapshotStore {
    private let defaults: UserDefaults
    private let key = "com.dugcanlift.lift.recentFoodsSnapshot"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var cached: RecentFoodsSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? SyncEnvelope.decoder.decode(RecentFoodsSnapshot.self, from: data)
    }

    public func save(_ snapshot: RecentFoodsSnapshot) {
        guard let data = try? SyncEnvelope.encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }
}
