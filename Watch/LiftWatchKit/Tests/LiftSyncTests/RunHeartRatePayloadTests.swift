import XCTest
import LiftSync

/// The one reading the watch sends the phone during a run it measures (path B),
/// checked against `Watch/contracts/run-heart-rate.schema.json` itself.
final class RunHeartRatePayloadTests: XCTestCase {

    private static let contract = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // LiftSyncTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // LiftWatchKit
        .deletingLastPathComponent()   // Watch
        .appendingPathComponent("contracts/run-heart-rate.schema.json")

    private func schema() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.contract)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// 2026-11-10T18:00:00Z.
    private let at = Date(timeIntervalSince1970: 1_794_333_600)

    func testTheContractExampleDecodes() throws {
        let examples = try XCTUnwrap(try schema()["examples"] as? [[String: Any]])
        let example = try XCTUnwrap(examples.first)
        let data = try JSONSerialization.data(withJSONObject: example)
        XCTAssertEqual(RunHeartRatePayload.decode(data), RunHeartRatePayload(bpm: 142, at: at))
    }

    func testTheExampleTextDecodes() {
        let data = Data(#"{"bpm":142,"at":"2026-11-10T18:00:00Z"}"#.utf8)
        XCTAssertEqual(RunHeartRatePayload.decode(data), RunHeartRatePayload(bpm: 142, at: at))
    }

    func testARoundTripIsExact() throws {
        let payload = RunHeartRatePayload(bpm: 157, at: at.addingTimeInterval(37))
        let data = try payload.encoded()
        XCTAssertEqual(RunHeartRatePayload.decode(data), payload)
    }

    /// Exactly the contract's two keys, a whole number and an ISO 8601 UTC
    /// string, so another build's decoder reads it.
    func testTheEncodingIsTheContractsShape() throws {
        let data = try RunHeartRatePayload(bpm: 142, at: at).encoded()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["bpm"] as? Int, 142)
        XCTAssertEqual(object["at"] as? String, "2026-11-10T18:00:00Z")
        let properties = try XCTUnwrap(try schema()["properties"] as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(properties.keys))
        XCTAssertEqual(Set(try XCTUnwrap(try schema()["required"] as? [String])), ["bpm", "at"])
    }

    /// A watch may write fractional seconds; the phone reads them.
    func testFractionalSecondsDecode() throws {
        let data = Data(#"{"bpm":150,"at":"2026-11-10T18:00:05.250Z"}"#.utf8)
        let payload = try XCTUnwrap(RunHeartRatePayload.decode(data))
        XCTAssertEqual(payload.bpm, 150)
        XCTAssertEqual(payload.at.timeIntervalSince1970, at.timeIntervalSince1970 + 5.25, accuracy: 0.001)
    }

    func testAnOffsetOtherThanUTCDecodesToTheSameInstant() {
        let data = Data(#"{"bpm":150,"at":"2026-11-10T13:00:00-05:00"}"#.utf8)
        XCTAssertEqual(RunHeartRatePayload.decode(data)?.at, at)
    }

    func testZeroOrLessIsNoReading() {
        XCTAssertNil(RunHeartRatePayload.decode(Data(#"{"bpm":0,"at":"2026-11-10T18:00:00Z"}"#.utf8)))
        XCTAssertNil(RunHeartRatePayload.decode(Data(#"{"bpm":-4,"at":"2026-11-10T18:00:00Z"}"#.utf8)))
    }

    func testGarbageIsIgnoredNotACrash() {
        for text in ["", "null", "[]", "{}", "not json", #"{"bpm":"142","at":"2026-11-10T18:00:00Z"}"#,
                     #"{"bpm":142}"#, #"{"bpm":142,"at":"yesterday"}"#, #"{"bpm":142.5,"at":"2026-11-10T18:00:00Z"}"#] {
            XCTAssertNil(RunHeartRatePayload.decode(Data(text.utf8)), text)
        }
        XCTAssertNil(RunHeartRatePayload.decode(Data([0xFF, 0x00, 0x13])))
    }

    func testManyDecodeAndDropWhatIsNotAReading() throws {
        let good = try RunHeartRatePayload(bpm: 140, at: at).encoded()
        let later = try RunHeartRatePayload(bpm: 141, at: at.addingTimeInterval(5)).encoded()
        let readings = RunHeartRatePayload.decodeAll([good, Data("junk".utf8), later,
                                                      Data(#"{"bpm":0,"at":"2026-11-10T18:00:00Z"}"#.utf8)])
        XCTAssertEqual(readings.map(\.bpm), [140, 141])
    }

    /// What the watch sends from a HealthKit statistic: rounded, and nothing
    /// for a value that is not a pulse.
    func testAReadingFromAStatistic() {
        XCTAssertEqual(RunHeartRatePayload.reading(bpm: 141.6, at: at), RunHeartRatePayload(bpm: 142, at: at))
        XCTAssertEqual(RunHeartRatePayload.reading(bpm: 141.4, at: at)?.bpm, 141)
        XCTAssertNil(RunHeartRatePayload.reading(bpm: 0, at: at))
        XCTAssertNil(RunHeartRatePayload.reading(bpm: 0.4, at: at), "rounds to zero, so no reading")
        XCTAssertNil(RunHeartRatePayload.reading(bpm: -3, at: at))
        XCTAssertNil(RunHeartRatePayload.reading(bpm: .nan, at: at))
        XCTAssertNil(RunHeartRatePayload.reading(bpm: .infinity, at: at))
    }

    /// A reading is a few dozen bytes: far inside HealthKit's 100 KB per
    /// ten seconds for `sendToRemoteWorkoutSession`.
    func testAReadingIsSmall() throws {
        XCTAssertLessThan(try RunHeartRatePayload(bpm: 199, at: at).encoded().count, 64)
    }
}
