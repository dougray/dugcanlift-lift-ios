import Foundation

/// One heart rate reading, watch -> phone, during a run the phone records and
/// the watch measures (path B). Contract: `Watch/contracts/run-heart-rate.schema.json`,
/// `{"bpm":142,"at":"2026-11-10T18:00:00Z"}`.
///
/// Rides `HKWorkoutSession.sendToRemoteWorkoutSession(data:)`, not
/// WatchConnectivity: each `Data` is one of these as UTF-8 JSON. Tracked and
/// shown, never targeted -- the phone shows the newest and keeps only the run's
/// average and max, never the readings.
public struct RunHeartRatePayload: Codable, Equatable, Sendable {
    /// Beats per minute. Zero or less is no reading.
    public let bpm: Int
    /// When it was measured.
    public let at: Date

    public init(bpm: Int, at: Date) {
        self.bpm = bpm
        self.at = at
    }

    /// What the watch sends for a HealthKit statistic: rounded to a whole
    /// beat, and nil for a value that is not a pulse (zero, negative, or not
    /// finite).
    public static func reading(bpm: Double, at: Date) -> RunHeartRatePayload? {
        guard bpm.isFinite else { return nil }
        let rounded = Int(bpm.rounded())
        return rounded > 0 ? RunHeartRatePayload(bpm: rounded, at: at) : nil
    }

    /// ISO 8601 in UTC, whole seconds, as the contract's example.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// The reading in `data`, or nil for anything that is not one: data that
    /// is not the contract's JSON, a date that is not ISO 8601, and a bpm of
    /// zero or less. Never throws: what arrives from another device is
    /// ignored when it is wrong, never a crash. Fractional seconds are read
    /// as well as whole ones, since a watch may send them.
    public static func decode(_ data: Data) -> RunHeartRatePayload? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = parseDate(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "not ISO 8601: \(text)")
            }
            return date
        }
        guard let payload = try? decoder.decode(RunHeartRatePayload.self, from: data),
              payload.bpm > 0 else { return nil }
        return payload
    }

    /// Every reading in a delivery, in order, without the ones that are not.
    public static func decodeAll(_ data: [Data]) -> [RunHeartRatePayload] {
        data.compactMap(decode)
    }

    private static func parseDate(_ text: String) -> Date? {
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        if let date = whole.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}
