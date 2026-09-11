import XCTest
import Compression
@testable import LiftKit

final class StandaloneExportTests: XCTestCase {

    private func food(_ name: String) -> WatchFood {
        WatchFood(name: name, kcal: 165, protein: 31, fat: 3.6, carbs: 0, fibre: 0)
    }

    private func entries(_ count: Int, distinctFoods: Int = 3) -> [LoggedFood] {
        (0..<count).map { i in
            LoggedFood(food: food("food\(i % distinctFoods)"),
                       grams: 100,
                       meal: .lunch,
                       loggedAt: Date(timeIntervalSince1970: 1_757_486_400 + Double(i) * 3600))
        }
    }

    /// Reverses one code back into its JSON object, the way the PWA will.
    private func decode(_ code: String) throws -> [String: Any] {
        var padded = code.replacingOccurrences(of: "-", with: "+")
                         .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        let deflated = try XCTUnwrap(Data(base64Encoded: padded))
        let capacity = 1 << 20
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }
        let written = deflated.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(destination, capacity, base, deflated.count,
                                             nil, COMPRESSION_ZLIB)
        }
        let json = Data(bytes: destination, count: written)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
    }

    func testMealIndicesMatchShareFormat() {
        // 0 breakfast, 1 lunch, 2 dinner, 3 snack. An off-by-one here
        // silently refiles every meal on the far side.
        XCTAssertEqual(StandaloneExport.mealIndex(.breakfast), 0)
        XCTAssertEqual(StandaloneExport.mealIndex(.lunch), 1)
        XCTAssertEqual(StandaloneExport.mealIndex(.dinner), 2)
        XCTAssertEqual(StandaloneExport.mealIndex(.snack), 3)
    }

    func testEmptyLogProducesNoCodes() {
        XCTAssertTrue(StandaloneExport.codes(for: []).isEmpty)
    }

    func testSingleCodeCarriesEveryEntryAndADeduplicatedFoodDictionary() throws {
        let payload = try decode(try XCTUnwrap(StandaloneExport.codes(for: entries(9, distinctFoods: 3)).first))
        XCTAssertEqual(payload["v"] as? Int, 1)
        XCTAssertEqual((payload["e"] as? [[Any]])?.count, 9)
        // Three distinct foods across nine entries — the dictionary holds
        // three, which is what keeps the payload affordable.
        XCTAssertEqual((payload["fd"] as? [[Any]])?.count, 3)
    }

    func testEntryTupleIsIndexGramsMealTimestamp() throws {
        let one = [LoggedFood(food: food("Chicken breast, roasted"), grams: 140,
                              meal: .dinner,
                              loggedAt: Date(timeIntervalSince1970: 1_757_486_400))]
        let payload = try decode(try XCTUnwrap(StandaloneExport.codes(for: one).first))
        let tuple = try XCTUnwrap((payload["e"] as? [[Any]])?.first)
        XCTAssertEqual(tuple[0] as? Int, 0)
        XCTAssertEqual((tuple[1] as? NSNumber)?.doubleValue, 140)
        XCTAssertEqual(tuple[2] as? Int, 2)
        XCTAssertEqual((tuple[3] as? NSNumber)?.doubleValue, 1_757_486_400)
    }

    func testFoodDictionaryRowIsNameThenMacrosPer100g() throws {
        let one = [LoggedFood(food: food("Chicken breast, roasted"), grams: 140,
                              meal: .dinner, loggedAt: Date(timeIntervalSince1970: 1))]
        let payload = try decode(try XCTUnwrap(StandaloneExport.codes(for: one).first))
        let row = try XCTUnwrap((payload["fd"] as? [[Any]])?.first)
        XCTAssertEqual(row[0] as? String, "Chicken breast, roasted")
        XCTAssertEqual((row[1] as? NSNumber)?.doubleValue, 165)
        XCTAssertEqual((row[2] as? NSNumber)?.doubleValue, 31)
        XCTAssertEqual((row[3] as? NSNumber)?.doubleValue, 3.6)
    }

    func testLogsLongerThanTheCapSplitAcrossNumberedCodes() throws {
        let codes = StandaloneExport.codes(for: entries(120))
        XCTAssertEqual(codes.count, 3)   // 50 + 50 + 20
        for (i, code) in codes.enumerated() {
            let position = try XCTUnwrap(decode(code)["p"] as? [Int])
            XCTAssertEqual(position, [i + 1, 3])
        }
    }

    func testEveryEntrySurvivesTheSplit() throws {
        let codes = StandaloneExport.codes(for: entries(120))
        let total = try codes.reduce(0) { $0 + ((try decode($1)["e"] as? [[Any]])?.count ?? 0) }
        XCTAssertEqual(total, 120)
    }

    func testAllCodesInASequenceShareAnExportTimestamp() throws {
        let codes = StandaloneExport.codes(for: entries(120))
        let stamps = try codes.map { try decode($0)["z"] as? Int }
        XCTAssertEqual(Set(stamps.compactMap { $0 }).count, 1)
    }

    func testASingleCodeStaysUnderTheScannableCeiling() {
        // 50 entries DEFLATEd measured at 744 base64url bytes. 800 is the
        // ceiling the spec sets for a watch display; this is the test that
        // catches a payload-shape change blowing through it.
        let code = StandaloneExport.codes(for: entries(50, distinctFoods: 8)).first ?? ""
        XCTAssertLessThanOrEqual(code.count, 800)
    }
}
