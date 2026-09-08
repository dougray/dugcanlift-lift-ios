import XCTest
import Compression
@testable import Lift

/// Builds a valid `1z<payload>` / `1u<payload>` fragment the way Coach's web
/// app would, independent of PlanLinkCodec's own decode implementation — a
/// fixture that shares code with the thing under test could hide a real bug.
enum PlanLinkFixtures {
    static func fragment(json: String, compressed: Bool = true) -> String {
        let data = Data(json.utf8)
        let codec: Character
        let payload: Data
        if compressed {
            codec = "z"
            payload = deflateRaw(data) ?? data
        } else {
            codec = "u"
            payload = data
        }
        return "1\(codec)\(base64URL(payload))"
    }

    private static func deflateRaw(_ data: Data) -> Data? {
        let capacity = max(data.count * 2, 256)
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }
        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(destination, capacity, base, data.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }
        return Data(bytes: destination, count: written)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

final class PlanLinkCodecTests: XCTestCase {

    // The literal example payload from PLAN-FORMAT.md, addressed to "a1b2c3d4".
    private let examplePayloadJSON = """
    {
      "v": 1, "t": "plan", "l": "a1b2c3d4", "n": "Doug",
      "r": [{"n": "Beef Chilli", "s": 4, "u": [438, 36, 31, 19, 9],
             "i": ["500 g lean beef mince", "2 cloves garlic", "1 can kidney beans"],
             "t": ["Brown the mince."]}],
      "m": [{"d": "2026-08-26", "s": 2, "x": 0, "q": 2}]
    }
    """

    func testDecodesCompressedPayloadAddressedToThisDevice() throws {
        let fragment = PlanLinkFixtures.fragment(json: examplePayloadJSON)
        let payload = try PlanLinkCodec.decode(fragment: fragment, expectedLifterID: "a1b2c3d4")

        XCTAssertEqual(payload.v, 1)
        XCTAssertEqual(payload.n, "Doug")
        XCTAssertEqual(payload.r?.first?.n, "Beef Chilli")
        XCTAssertEqual(payload.r?.first?.u, [438, 36, 31, 19, 9])
        XCTAssertEqual(payload.m?.first?.d, "2026-08-26")
    }

    func testDecodesUncompressedFallback() throws {
        let fragment = PlanLinkFixtures.fragment(json: examplePayloadJSON, compressed: false)
        let payload = try PlanLinkCodec.decode(fragment: fragment, expectedLifterID: "a1b2c3d4")
        XCTAssertEqual(payload.n, "Doug")
    }

    func testWorkoutTemplateWithMixedNullSets() throws {
        let json = """
        {"v": 1, "t": "plan", "l": "a1b2c3d4", "n": "Doug",
         "w": [{"n": "Lower A", "e": [{"n": "Back Squat", "q": "Barbell",
                "s": [[225, 5, 8], [null, 5], [null, null, null, 600, 1600]],
                "c": "Belt on the last set."}]}],
         "k": [{"d": "2026-09-08", "x": 0}]}
        """
        let payload = try PlanLinkCodec.decode(
            fragment: PlanLinkFixtures.fragment(json: json),
            expectedLifterID: "a1b2c3d4"
        )
        let sets = payload.w?.first?.e.first?.s
        XCTAssertEqual(sets?[0], [225, 5, 8])
        XCTAssertEqual(sets?[1], [nil, 5])
        XCTAssertEqual(sets?[2], [nil, nil, nil, 600, 1600])
        XCTAssertEqual(payload.k?.first?.x, 0)
    }

    func testRejectsPlanAddressedToSomeoneElse() {
        let fragment = PlanLinkFixtures.fragment(json: examplePayloadJSON)
        XCTAssertThrowsError(
            try PlanLinkCodec.decode(fragment: fragment, expectedLifterID: "someone-else")
        ) { error in
            XCTAssertEqual(error as? PlanLinkError, .notAddressedToThisDevice)
        }
    }

    func testRejectsUnsupportedVersion() {
        let json = #"{"v": 2, "t": "plan", "l": "a1b2c3d4", "n": "Doug"}"#
        let fragment = PlanLinkFixtures.fragment(json: json)
        XCTAssertThrowsError(
            try PlanLinkCodec.decode(fragment: fragment, expectedLifterID: "a1b2c3d4")
        ) { error in
            XCTAssertEqual(error as? PlanLinkError, .unsupportedVersion("2"))
        }
    }

    func testRejectsUnknownCodec() {
        XCTAssertThrowsError(
            try PlanLinkCodec.decode(fragment: "1qSGVsbG8", expectedLifterID: "a1b2c3d4")
        ) { error in
            XCTAssertEqual(error as? PlanLinkError, .unsupportedCodec("q"))
        }
    }

    func testRejectsFragmentTooShortToContainVersionAndCodec() {
        XCTAssertThrowsError(try PlanLinkCodec.decode(fragment: "1", expectedLifterID: "x")) { error in
            XCTAssertEqual(error as? PlanLinkError, .malformedFragment)
        }
    }

    func testRejectsCorruptCompressedPayload() {
        XCTAssertThrowsError(
            try PlanLinkCodec.decode(fragment: "1znot-valid-deflate!!", expectedLifterID: "x")
        ) { error in
            XCTAssertEqual(error as? PlanLinkError, .corruptPayload)
        }
    }

    func testIgnoresExtraCharactersAfterThePayload() throws {
        // "Decoders must ignore any characters after the payload" — a browser
        // may append its own tracking junk after the fragment.
        let fragment = PlanLinkFixtures.fragment(json: examplePayloadJSON, compressed: false)
        let payload = try PlanLinkCodec.decode(
            fragment: fragment + "&utm_source=mail",
            expectedLifterID: "a1b2c3d4"
        )
        XCTAssertEqual(payload.n, "Doug")
    }
}
