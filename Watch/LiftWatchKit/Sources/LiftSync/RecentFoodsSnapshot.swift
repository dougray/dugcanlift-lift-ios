import Foundation

/// Pushed phone -> watch via `WCSession.updateApplicationContext` so the
/// watch's local "recent foods" cache stays warm without a round trip.
/// Matches `Watch/contracts/recent-foods-snapshot.schema.json` field-for-
/// field — not part of `SyncEnvelope`'s event shape, since this is a
/// replace-in-place snapshot, not a discrete event. The phone encodes this
/// same type (`WatchSyncReceiver.makeSnapshot`) and the watch decodes it.
public struct RecentFoodsSnapshot: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Hashable, Sendable {
        public var foodRefID: String
        public var displayName: String
        public var lastAmountGrams: Double?
        /// Per 100 g, so a watch-logged entry can be exported without the
        /// reader having to resolve `foodRefID` — which nothing downstream
        /// can do. Optional because snapshots cached before this field
        /// existed decode without it; an entry whose macros are unknown is
        /// excluded from export rather than exported as zeroes.
        public var nutritionPer100g: WatchFood?

        public init(foodRefID: String, displayName: String,
                    lastAmountGrams: Double?, nutritionPer100g: WatchFood? = nil) {
            self.foodRefID = foodRefID
            self.displayName = displayName
            self.lastAmountGrams = lastAmountGrams
            self.nutritionPer100g = nutritionPer100g
        }

        /// The macros under the name the user actually picked.
        public var watchFood: WatchFood? {
            guard let macros = nutritionPer100g else { return nil }
            return WatchFood(name: displayName, kcal: macros.kcal, protein: macros.protein,
                             fat: macros.fat, carbs: macros.carbs, fibre: macros.fibre)
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
    /// The `[String: Any]` dictionary `updateApplicationContext` sends, encoded
    /// with `SyncEnvelope`'s own `.iso8601` encoder so `generatedAt` travels
    /// as a date-time string like every other date in this contract, never
    /// as a numeric `timeIntervalSinceReferenceDate`.
    public func messageBody() throws -> [String: Any] {
        let data = try SyncEnvelope.encoder.encode(self)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SyncTransportError.malformedPayload
        }
        return object
    }

    /// Bridges the `[String: Any]` dictionary `WCSessionDelegate.session(_:
    /// didReceiveApplicationContext:)` actually hands over, decoding with
    /// `SyncEnvelope`'s own `.iso8601` decoder.
    public init(messageBody: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: messageBody)
        self = try SyncEnvelope.decoder.decode(RecentFoodsSnapshot.self, from: data)
    }
}
