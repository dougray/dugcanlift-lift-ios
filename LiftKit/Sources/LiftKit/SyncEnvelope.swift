import Foundation

/// The wire format defined by `shared/contracts/workout-sync.schema.json`.
///
/// Wear OS encodes the same envelope over the Wearable Data Layer, so the
/// field names and enum spellings here are a contract, not an implementation
/// detail. `SyncEnvelopeTests` pins them.
public struct SyncEnvelope: Codable, Equatable, Sendable {

    public enum Event: String, Codable, Sendable {
        case sessionFinished          = "SESSION_FINISHED"
        case workoutEdited            = "WORKOUT_EDITED"
        case workoutSyncAck           = "WORKOUT_SYNC_ACK"
        case outdoorActivityFinished  = "OUTDOOR_ACTIVITY_FINISHED"
    }

    public enum Origin: String, Codable, Sendable {
        case watchOS, wearOS, android, ios, pwa
    }

    public var event: Event
    public var workoutID: UUID
    public var revision: Int
    public var updatedAt: Date
    public var origin: Origin

    private enum CodingKeys: String, CodingKey {
        case event
        case workoutID = "workoutId"
        case revision
        case updatedAt
        case origin
    }

    public init(event: Event, workoutID: UUID, revision: Int, updatedAt: Date, origin: Origin) {
        self.event = event
        self.workoutID = workoutID
        self.revision = revision
        self.updatedAt = updatedAt
        self.origin = origin
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        event = try container.decode(Event.self, forKey: .event)
        workoutID = try container.decode(UUID.self, forKey: .workoutID)
        revision = try container.decode(Int.self, forKey: .revision)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        origin = try container.decode(Origin.self, forKey: .origin)

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

extension SyncEnvelope {
    /// ISO-8601 with a `Z` offset, matching the schema's `date-time` format.
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Convenience for the payload dictionary WatchConnectivity actually sends.
    public func messageBody() throws -> [String: Any] {
        let data = try Self.encoder.encode(self)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SyncTransportError.malformedPayload
        }
        return object
    }

    public init(messageBody: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: messageBody)
        self = try Self.decoder.decode(SyncEnvelope.self, from: data)
    }
}

public enum SyncTransportError: Error {
    case malformedPayload
    case counterpartUnreachable
}
