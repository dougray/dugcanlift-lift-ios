import Foundation

/// Wire format shared with LIFT watchOS (ported, not shared source — the two
/// apps are separate Xcode projects with no shared source, only an agreed
/// wire format). See `dugcanlift-watch/shared/contracts/workout-sync.schema.json`
/// for the contract of record both platforms' Swift types must match exactly.
///
/// Field names and enum spellings here are a contract, not an implementation
/// detail — `SyncEnvelopeTests` pins them to the schema.
struct SyncEnvelope: Codable, Equatable, Sendable {

    enum Event: String, Codable, Sendable {
        case sessionFinished          = "SESSION_FINISHED"
        case workoutEdited            = "WORKOUT_EDITED"
        case workoutSyncAck           = "WORKOUT_SYNC_ACK"
        case outdoorActivityFinished  = "OUTDOOR_ACTIVITY_FINISHED"
        case foodLogged               = "FOOD_LOGGED"
    }

    enum Origin: String, Codable, Sendable {
        case watchOS, wearOS, android, ios, pwa
    }

    var event: Event
    var workoutID: UUID
    var revision: Int
    var updatedAt: Date
    var origin: Origin
    /// Only non-nil for `.foodLogged`. Every other event case predates this
    /// field and never sets it. Must round-trip as an absent key, not a JSON
    /// `null`, so older decoders on either platform never see the key at all.
    var foodLog: FoodLogPayload?

    private enum CodingKeys: String, CodingKey {
        case event
        case workoutID = "workoutId"
        case revision
        case updatedAt
        case origin
        case foodLog
    }

    init(
        event: Event,
        workoutID: UUID,
        revision: Int,
        updatedAt: Date,
        origin: Origin,
        foodLog: FoodLogPayload? = nil
    ) {
        self.event = event
        self.workoutID = workoutID
        self.revision = revision
        self.updatedAt = updatedAt
        self.origin = origin
        self.foodLog = foodLog
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        event = try container.decode(Event.self, forKey: .event)
        workoutID = try container.decode(UUID.self, forKey: .workoutID)
        revision = try container.decode(Int.self, forKey: .revision)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        origin = try container.decode(Origin.self, forKey: .origin)
        // decodeIfPresent treats both a missing key and an explicit JSON
        // `null` as nil, so either wire shape from the watch decodes cleanly.
        foodLog = try container.decodeIfPresent(FoodLogPayload.self, forKey: .foodLog)

        // The schema says `revision` has a minimum of 1. Decoding is the only
        // place a foreign device's value enters, so reject it here rather than
        // letting a zero poison reconciliation later.
        guard revision >= 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .revision,
                in: container,
                debugDescription: "revision must be >= 1, got \(revision)"
            )
        }
    }
}

/// Payload for the `.foodLogged` event, added to the wire contract by the
/// watch food quick-log feature. `dugcanlift-watch` does not have a matching
/// Swift type yet — this is the iOS side landing first; the watch side and
/// the schema update land alongside this task.
///
/// `meal` carries the same raw values as the app's `MealType`
/// (breakfast/lunch/dinner/snack) but is kept as a plain `String` here since
/// this type describes the wire shape, not the app's internal model.
struct FoodLogPayload: Codable, Equatable, Sendable {
    let foodRefID: String
    let amountGrams: Double
    let meal: String
    let loggedAt: Date
}

extension SyncEnvelope {
    /// ISO-8601 with a `Z` offset, matching the schema's `date-time` format.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Convenience for the payload dictionary WatchConnectivity actually sends.
    func messageBody() throws -> [String: Any] {
        let data = try Self.encoder.encode(self)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SyncTransportError.malformedPayload
        }
        return object
    }

    init(messageBody: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: messageBody)
        self = try Self.decoder.decode(SyncEnvelope.self, from: data)
    }
}

enum SyncTransportError: Error {
    case malformedPayload
    case counterpartUnreachable
}
