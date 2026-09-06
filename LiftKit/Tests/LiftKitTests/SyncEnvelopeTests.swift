import XCTest
@testable import LiftKit

/// `shared/contracts/workout-sync.schema.json` is the wire contract shared with
/// Wear OS. These tests pin the encoding to the field names and enum values in
/// that schema so the two platforms cannot drift apart silently.
final class SyncEnvelopeTests: XCTestCase {

    private func json(_ envelope: SyncEnvelope) throws -> [String: Any] {
        let data = try SyncEnvelope.encoder.encode(envelope)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testEncodesContractFieldNames() throws {
        let envelope = SyncEnvelope(
            event: .workoutEdited,
            workoutID: UUID(uuidString: "6A2A8B6E-3D2F-4E77-9B4E-2C6A5E8C1D01")!,
            revision: 4,
            updatedAt: Date(timeIntervalSince1970: 0),
            origin: .watchOS
        )
        let object = try json(envelope)

        XCTAssertEqual(Set(object.keys), ["event", "workoutId", "revision", "updatedAt", "origin"])
        XCTAssertEqual(object["event"] as? String, "WORKOUT_EDITED")
        XCTAssertEqual(object["origin"] as? String, "watchOS")
        XCTAssertEqual(object["revision"] as? Int, 4)
        XCTAssertEqual(object["updatedAt"] as? String, "1970-01-01T00:00:00Z")
        XCTAssertEqual(
            (object["workoutId"] as? String)?.lowercased(),
            "6a2a8b6e-3d2f-4e77-9b4e-2c6a5e8c1d01"
        )
    }

    func testRoundTrips() throws {
        let envelope = SyncEnvelope(
            event: .sessionFinished,
            workoutID: UUID(),
            revision: 9,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            origin: .watchOS
        )
        let data = try SyncEnvelope.encoder.encode(envelope)
        let decoded = try SyncEnvelope.decoder.decode(SyncEnvelope.self, from: data)
        XCTAssertEqual(decoded, envelope)
    }

    func testRevisionMustBePositive() throws {
        let data = Data("""
        {"event":"WORKOUT_EDITED","workoutId":"6A2A8B6E-3D2F-4E77-9B4E-2C6A5E8C1D01",
         "revision":0,"updatedAt":"1970-01-01T00:00:00Z","origin":"watchOS"}
        """.utf8)
        XCTAssertThrowsError(try SyncEnvelope.decoder.decode(SyncEnvelope.self, from: data))
    }

    func testUnknownFieldsAreTolerated() throws {
        // The schema sets additionalProperties: true — a newer phone build must
        // not break an older watch build.
        let data = Data("""
        {"event":"WORKOUT_SYNC_ACK","workoutId":"6A2A8B6E-3D2F-4E77-9B4E-2C6A5E8C1D01",
         "revision":2,"updatedAt":"1970-01-01T00:00:00Z","origin":"ios","futureField":true}
        """.utf8)
        let decoded = try SyncEnvelope.decoder.decode(SyncEnvelope.self, from: data)
        XCTAssertEqual(decoded.event, .workoutSyncAck)
        XCTAssertEqual(decoded.origin, .ios)
    }
}
