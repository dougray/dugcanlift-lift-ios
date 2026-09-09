import XCTest
@testable import Lift

/// `dugcanlift-watch/shared/contracts/workout-sync.schema.json` is the wire
/// contract shared with watchOS. These tests pin the encoding to the field
/// names and enum values in that schema so the two platforms cannot drift
/// apart silently.
final class SyncEnvelopeTests: XCTestCase {

    private func json(_ envelope: SyncEnvelope) throws -> [String: Any] {
        let data = try SyncEnvelope.encoder.encode(envelope)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - .foodLogged

    func testFoodLoggedRoundTrips() throws {
        let payload = FoodLogPayload(
            foodRefID: "usda:174608",
            amountGrams: 150,
            meal: "lunch",
            loggedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let envelope = SyncEnvelope(
            event: .foodLogged,
            workoutID: UUID(),
            revision: 1,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            origin: .ios,
            foodLog: payload
        )

        let data = try SyncEnvelope.encoder.encode(envelope)
        let decoded = try SyncEnvelope.decoder.decode(SyncEnvelope.self, from: data)

        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(decoded.event, .foodLogged)
        XCTAssertEqual(decoded.foodLog, payload)
    }

    func testFoodLoggedEncodesContractFieldNames() throws {
        let payload = FoodLogPayload(
            foodRefID: "off:3017620422003",
            amountGrams: 42.5,
            meal: "snack",
            loggedAt: Date(timeIntervalSince1970: 0)
        )
        let envelope = SyncEnvelope(
            event: .foodLogged,
            workoutID: UUID(uuidString: "6A2A8B6E-3D2F-4E77-9B4E-2C6A5E8C1D01")!,
            revision: 1,
            updatedAt: Date(timeIntervalSince1970: 0),
            origin: .ios,
            foodLog: payload
        )
        let object = try json(envelope)

        XCTAssertEqual(object["event"] as? String, "FOOD_LOGGED")
        let foodLog = try XCTUnwrap(object["foodLog"] as? [String: Any])
        XCTAssertEqual(Set(foodLog.keys), ["foodRefID", "amountGrams", "meal", "loggedAt"])
        XCTAssertEqual(foodLog["foodRefID"] as? String, "off:3017620422003")
        XCTAssertEqual(foodLog["amountGrams"] as? Double, 42.5)
        XCTAssertEqual(foodLog["meal"] as? String, "snack")
        XCTAssertEqual(foodLog["loggedAt"] as? String, "1970-01-01T00:00:00Z")
    }

    // MARK: - foodLog absence on pre-existing event types

    func testSessionFinishedOmitsFoodLogKeyEntirely() throws {
        let envelope = SyncEnvelope(
            event: .sessionFinished,
            workoutID: UUID(),
            revision: 9,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            origin: .watchOS
        )
        let object = try json(envelope)

        // foodLog must be an absent key, not a JSON `null` — a `null` would
        // still round-trip via decodeIfPresent, but an older decoder on
        // either platform that doesn't know about the key at all should
        // never see it, present-but-null, in the payload it receives.
        XCTAssertFalse(object.keys.contains("foodLog"))
        XCTAssertEqual(Set(object.keys), ["event", "workoutId", "revision", "updatedAt", "origin"])
    }

    func testSessionFinishedRoundTripsWithNilFoodLog() throws {
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
        XCTAssertNil(decoded.foodLog)
    }

    func testExplicitNullFoodLogDecodesAsNil() throws {
        // A future/other-platform encoder might send `"foodLog": null`
        // explicitly rather than omitting the key. decodeIfPresent must
        // treat that the same as an absent key.
        let data = Data("""
        {"event":"WORKOUT_SYNC_ACK","workoutId":"6A2A8B6E-3D2F-4E77-9B4E-2C6A5E8C1D01",
         "revision":2,"updatedAt":"1970-01-01T00:00:00Z","origin":"ios","foodLog":null}
        """.utf8)
        let decoded = try SyncEnvelope.decoder.decode(SyncEnvelope.self, from: data)
        XCTAssertNil(decoded.foodLog)
    }

    // MARK: - pre-existing behavior (unchanged by this port)

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

    func testOutdoorActivityFinishedRoundTrips() throws {
        let envelope = SyncEnvelope(
            event: .outdoorActivityFinished,
            workoutID: UUID(),
            revision: 3,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            origin: .watchOS
        )
        let object = try json(envelope)
        XCTAssertEqual(object["event"] as? String, "OUTDOOR_ACTIVITY_FINISHED")

        let data = try SyncEnvelope.encoder.encode(envelope)
        let decoded = try SyncEnvelope.decoder.decode(SyncEnvelope.self, from: data)
        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(decoded.event, .outdoorActivityFinished)
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
