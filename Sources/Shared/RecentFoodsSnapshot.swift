import Foundation

/// Wire format pushed phone -> watch via `WCSession.updateApplicationContext`
/// so the watch's local "recent foods" cache stays warm without a round
/// trip. Lives alongside `SyncEnvelope` because it is the same kind of thing:
/// a cross-platform contract, not an implementation detail internal to
/// `WatchSyncReceiver`. See
/// `dugcanlift-watch/shared/contracts/recent-foods-snapshot.schema.json`
/// for the contract of record.
///
/// Field names here are a contract, not an implementation detail —
/// `RecentFoodsSnapshotTests` pins them to the schema, same as
/// `SyncEnvelopeTests` does for `SyncEnvelope`.
struct RecentFoodsSnapshot: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Sendable {
        let foodRefID: String
        let displayName: String
        let lastAmountGrams: Double?
    }
    let items: [Item]
    let generatedAt: Date
}

extension RecentFoodsSnapshot {
    /// Reuses `SyncEnvelope`'s own `.iso8601`-configured encoder/decoder
    /// rather than a bare `JSONEncoder()`/`JSONDecoder()` — `generatedAt`
    /// must round-trip as an ISO-8601 date-time string like every other date
    /// in this wire contract, not as a numeric
    /// `timeIntervalSinceReferenceDate`.
    func messageBody() throws -> [String: Any] {
        let data = try SyncEnvelope.encoder.encode(self)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SyncTransportError.malformedPayload
        }
        return object
    }

    init(messageBody: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: messageBody)
        self = try SyncEnvelope.decoder.decode(RecentFoodsSnapshot.self, from: data)
    }
}
