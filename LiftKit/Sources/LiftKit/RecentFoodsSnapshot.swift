import Foundation

/// Pushed phone -> watch via `WCSession.updateApplicationContext` so the
/// watch's local "recent foods" cache stays warm without a round trip.
/// Matches `shared/contracts/recent-foods-snapshot.schema.json` field-for-
/// field — not part of `SyncEnvelope`'s event shape, since this is a
/// replace-in-place snapshot, not a discrete event. The phone side's own
/// `RecentFoodsSnapshot` (a separate repo, `lift-ios`) is the counterpart
/// this type must stay byte-for-byte compatible with.
public struct RecentFoodsSnapshot: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Hashable, Sendable {
        public var foodRefID: String
        public var displayName: String
        public var lastAmountGrams: Double?

        public init(foodRefID: String, displayName: String, lastAmountGrams: Double?) {
            self.foodRefID = foodRefID
            self.displayName = displayName
            self.lastAmountGrams = lastAmountGrams
        }
    }

    public var items: [Item]
    public var generatedAt: Date

    public init(items: [Item], generatedAt: Date) {
        self.items = items
        self.generatedAt = generatedAt
    }
}

extension RecentFoodsSnapshot {
    /// Bridges the `[String: Any]` dictionary `WCSessionDelegate.session(_:
    /// didReceiveApplicationContext:)` actually hands over, reusing
    /// `SyncEnvelope`'s own `.iso8601`-configured decoder so `generatedAt`
    /// decodes the same way every date in this wire contract does.
    public init(applicationContext: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: applicationContext)
        self = try SyncEnvelope.decoder.decode(RecentFoodsSnapshot.self, from: data)
    }
}
