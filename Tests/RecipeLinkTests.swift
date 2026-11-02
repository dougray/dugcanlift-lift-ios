import XCTest
import CryptoKit
import LiftCore
@testable import Lift

/// The port of `dugcanlift-kit/bookmarklet/recipe-link.mjs`, checked against
/// the kit's own fixture pair: `Fixtures/recipe-link.txt` is a link the
/// bookmarklet itself wrote, and `recipe-link-expected.json` is what the
/// reference decoder makes of it. Both are copies of the kit's files. Never
/// regenerate them from Swift -- a fixture this code wrote proves only that it
/// agrees with itself.
final class RecipeLinkTests: XCTestCase {

    private func fixture(_ name: String, _ ext: String) throws -> String {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext),
                                "\(name).\(ext) missing from the test bundle")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func fixtureLink() throws -> String {
        try fixture("recipe-link", "txt").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What `recipe-link.test.mjs`'s `encode` writes: `#r1` and the JSON,
    /// deflated raw and base64url'd with no padding.
    private func encode(_ object: Any) throws -> String {
        let json = try JSONSerialization.data(withJSONObject: object)
        return "#r1" + base64URL(try deflate(json))
    }

    private func deflate(_ data: Data) throws -> Data {
        // NSData's `.zlib` is raw deflate (RFC 1951), as `deflateRawSync` is.
        try (data as NSData).compressed(using: .zlib) as Data
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private let ok: [String: Any] = ["v": 1, "url": "https://a.example/r", "jsonld": [#"{"@type":"Recipe"}"#]]

    private func with(_ key: String, _ value: Any) -> [String: Any] {
        var doc = ok
        doc[key] = value
        return doc
    }

    // MARK: The kit's fixture

    func testTheFixtureLinkDecodesToTheExpectedPage() throws {
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(try fixture("recipe-link-expected", "json").utf8)) as? [String: Any])
        let page = try XCTUnwrap(RecipeLink.decode(try fixtureLink()))
        XCTAssertEqual(page.url.absoluteString, expected["url"] as? String)
        // Byte for byte, non-ASCII and the emoji included.
        XCTAssertEqual(page.blocks, expected["jsonld"] as? [String])
    }

    /// The page the fixture carries is a recipe this app can review: the same
    /// reader a Safari share uses finds the stew in it.
    func testTheFixtureCarriesTheStew() throws {
        let found = try XCTUnwrap(RecipeLink.decode(try fixtureLink())?.firstRecipe())
        XCTAssertEqual(found.recipe.name, "Beef & barley stew — crème fraîche finish 🍲")
        XCTAssertEqual(found.recipe.ingredientLines.count, 6)
        XCTAssertEqual(found.recipe.servings, 4)
    }

    // MARK: The reference's refusals, case for case

    func testRefusals() throws {
        XCTAssertNotNil(RecipeLink.decode(try encode(ok)))
        XCTAssertNil(RecipeLink.decode("dugcanliftlift://recipe"), "no fragment")
        XCTAssertNil(RecipeLink.decode("#1zabc"), "a log link is not a recipe link")
        XCTAssertNil(RecipeLink.decode("#r1!!!"), "not base64url")
        XCTAssertNil(RecipeLink.decode("#r1AAAA"), "not deflate")
        XCTAssertNil(RecipeLink.decode(try encode(with("v", 2))), "unknown version")
        XCTAssertNil(RecipeLink.decode(try encode(with("url", "javascript:alert(1)"))), "not http(s)")
        XCTAssertNil(RecipeLink.decode(try encode(with("url", 7))), "url not a string")
        XCTAssertNil(RecipeLink.decode(try encode(with("jsonld", "x"))), "jsonld not an array")
        XCTAssertNil(RecipeLink.decode(try encode(with("jsonld", [Any]()))), "no blocks")
        XCTAssertNil(RecipeLink.decode(try encode(with("jsonld", [3, NSNull()]))), "no string blocks")
    }

    func testANonStringBlockIsDroppedNotFatal() throws {
        let doc: [String: Any] = ["v": 1, "url": "http://a.example/r", "jsonld": [5, #"{"@type":"Recipe"}"#]]
        XCTAssertEqual(RecipeLink.decode(try encode(doc))?.blocks, [#"{"@type":"Recipe"}"#])
    }

    func testMoreThanMaxBytesOnceInflatedIsRefused() throws {
        let big = with("jsonld", [String(repeating: "x", count: RecipeLink.maxBytes + 1)])
        XCTAssertNil(RecipeLink.decode(try encode(big)))
    }

    /// The cap is on the inflated JSON, and it is inclusive, as Node's
    /// `maxOutputLength` is.
    func testExactlyMaxBytesIsRead() throws {
        func doc(padding: Int) -> [String: Any] { with("jsonld", [String(repeating: "x", count: padding)]) }
        let overhead = try JSONSerialization.data(withJSONObject: doc(padding: 0)).count
        let exact = doc(padding: RecipeLink.maxBytes - overhead)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: exact).count, RecipeLink.maxBytes)
        XCTAssertNotNil(RecipeLink.decode(try encode(exact)))
        XCTAssertNil(RecipeLink.decode(try encode(doc(padding: RecipeLink.maxBytes - overhead + 1))))
    }

    /// `v !== 1` in JavaScript: `true` and `"1"` are not one, `1.0` is.
    func testVersionIsTheNumberOne() throws {
        XCTAssertNil(RecipeLink.decode(try encode(with("v", true))))
        XCTAssertNil(RecipeLink.decode(try encode(with("v", "1"))))
        XCTAssertNil(RecipeLink.decode("#r1" + base64URL(try deflate(Data(#"{"url":"https://a.example/r","jsonld":["x"]}"#.utf8)))),
                     "no version")
        let decimal = #"{"v":1.0,"url":"https://a.example/r","jsonld":["x"]}"#
        XCTAssertNotNil(RecipeLink.decode("#r1" + base64URL(try deflate(Data(decimal.utf8)))))
    }

    func testTheSchemeIsCaseInsensitiveAsInTheReference() throws {
        XCTAssertNotNil(RecipeLink.decode(try encode(with("url", "HTTPS://A.example/r"))))
    }

    /// A deflate stream cut off before its last block is bad deflate, not a
    /// shorter page.
    func testATruncatedStreamIsRefused() throws {
        let link = try fixtureLink()
        XCTAssertNil(RecipeLink.decode(String(link.dropLast(40))))
    }

    func testJSONThatIsNotAnObjectIsRefused() throws {
        for json in ["[1]", "1", #""text""#, "null", "{"] {
            XCTAssertNil(RecipeLink.decode("#r1" + base64URL(try deflate(Data(json.utf8)))), json)
        }
    }

    // MARK: Which link is which

    func testARecipeLinkOpensTheStewForReview() throws {
        let url = try XCTUnwrap(URL(string: try fixtureLink()))
        guard case .recipe(let item) = IncomingLink.open(url, expectedLifterID: PlanLinkExtractorTests.fixtureLifterID) else {
            return XCTFail("the bookmarklet's link should open a review")
        }
        let page = try XCTUnwrap(RecipeLink.decode(try fixtureLink()))
        // Exactly what a Safari share of the same page would queue.
        guard case .recipe(_, _, let fromSafari) = RecipeShareDecision.decide(
            candidates: [], page: page, isLink: PlanLinkExtractor.isLink) else {
            return XCTFail("Safari's path should find the recipe too")
        }
        XCTAssertEqual(item, fromSafari)
        XCTAssertEqual(item.pageURL, "https://example.com/recipes/stew")
    }

    func testAnUnreadableRecipeLinkSaysSo() {
        for text in ["dugcanliftlift://recipe#r1abc", "dugcanliftlift://recipe", "dugcanliftlift://recipe#",
                     "dugcanliftlift://RECIPE#r1abc"] {
            XCTAssertEqual(IncomingLink.open(URL(string: text)!, expectedLifterID: "a1b2c3d4"),
                           .report(.refused(.unreadableRecipeLink)), text)
        }
        XCTAssertEqual(PlanLinkIntake.Refusal.unreadableRecipeLink.message,
                       "That recipe link could not be read, so nothing was added. Open the recipe page and tap Send to LIFT again.")
        XCTAssertEqual(PlanLinkIntake.Refusal.noRecipeInLink.message,
                       "That page has no recipe LIFT can read. Copy the recipe text and use Paste a recipe instead.")
        XCTAssertEqual(PlanLinkIntake.Refusal.noRecipeInLink.alertTitle, "Couldn't read that recipe")
        XCTAssertEqual(PlanLinkIntake.Refusal.unreadableRecipeLink.alertTitle, "Couldn't read that recipe")
        XCTAssertEqual(PlanLinkIntake.Refusal.link(.corruptPayload).alertTitle, "Couldn't open this plan")
    }

    /// A link that decodes but carries no Recipe is refused, not opened empty.
    func testALinkWithNoRecipeInItIsRefused() throws {
        let article = with("jsonld", [#"{"@type":"Article","headline":"Ten recipe tips"}"#])
        let url = try XCTUnwrap(URL(string: "dugcanliftlift://recipe" + (try encode(article))))
        XCTAssertNotNil(RecipeLink.decode(url.absoluteString), "it is a well-formed link")
        XCTAssertEqual(IncomingLink.open(url, expectedLifterID: "a1b2c3d4"), .report(.refused(.noRecipeInLink)))
    }

    /// A plan link still opens the plan, exactly as before recipe links.
    func testAPlanLinkStillOpensThePlan() throws {
        let fragment = try XCTUnwrap(PlanLinkExtractor.fragment(in: try PlanLinkExtractorTests.fixtureLink()))
        let url = try XCTUnwrap(PlanLinkExtractor.openURL(for: fragment))
        let lifter = PlanLinkExtractorTests.fixtureLifterID
        XCTAssertEqual(IncomingLink.open(url, expectedLifterID: lifter),
                       .report(PlanLinkIntake.open(url, expectedLifterID: lifter)))
        guard case .report(.plan(let incoming)) = IncomingLink.open(url, expectedLifterID: lifter) else {
            return XCTFail("a plan link should open the plan")
        }
        XCTAssertEqual(incoming.payload.n, "Doug")
    }

    /// The host decides, and neither fragment is read under the other's host:
    /// a plan's `#1z...` under `recipe` is not a recipe and does not open as a
    /// plan, and a recipe's `#r1...` under `plan` is not a plan.
    func testAPlanAndARecipeAreNeverConfused() throws {
        let lifter = PlanLinkExtractorTests.fixtureLifterID
        let planFragment = try XCTUnwrap(PlanLinkExtractor.fragment(in: try PlanLinkExtractorTests.fixtureLink()))
        let recipeFragment = try XCTUnwrap(try fixtureLink().split(separator: "#", maxSplits: 1).last)

        let planUnderRecipe = try XCTUnwrap(URL(string: "dugcanliftlift://recipe#\(planFragment)"))
        XCTAssertEqual(IncomingLink.open(planUnderRecipe, expectedLifterID: lifter),
                       .report(.refused(.unreadableRecipeLink)))

        let recipeUnderPlan = try XCTUnwrap(URL(string: "dugcanliftlift://plan#\(recipeFragment)"))
        XCTAssertEqual(IncomingLink.open(recipeUnderPlan, expectedLifterID: lifter),
                       .report(.refused(.notAPlanLink)))

        // Neither decoder reads the other's fragment, whatever the host.
        XCTAssertNil(RecipeLink.decode("#\(planFragment)"))
        XCTAssertNil(PlanLinkExtractor.fragment(in: try fixtureLink()))
    }

    /// A URL that was never LIFT's is still ignored, not refused as a recipe.
    func testSomeoneElsesLinkIsStillIgnored() {
        let other = URL(string: "https://example.com/recipe#r1abc")!
        XCTAssertEqual(IncomingLink.open(other, expectedLifterID: "a1b2c3d4"), .report(.ignored))
    }
}

/// `Resources/bookmarklets.json` is a verbatim copy of
/// `dugcanlift-kit/bookmarklet/bookmarklets.json`, and `bookmarklets.sha256`
/// the kit's checksum of it, copied across together.
final class BookmarkletTests: XCTestCase {

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// **It hashes what the bundle holds, not what sits in the repo**, the rule
    /// `RoadFoodDataTests` follows: a build that dropped the resource fails
    /// instead of passing, and a copy behind the kit's fails too.
    func testTheBundledFileIsTheKitsBytes() throws {
        let bundle = Bundle(for: Self.self)
        let json = try XCTUnwrap(bundle.url(forResource: "bookmarklets", withExtension: "json"),
                                 "Resources/bookmarklets.json is not in this build")
        let sumURL = try XCTUnwrap(bundle.url(forResource: "bookmarklets", withExtension: "sha256"),
                                   "bookmarklets.sha256 is not in this build -- copy it from the kit beside the JSON")
        let sum = try String(contentsOf: sumURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotNil(sum.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression),
                        "bookmarklets.sha256 should be one bare sha256 and nothing else")
        XCTAssertEqual(sha256(try Data(contentsOf: json)), sum, """
            The bundled bookmarklets.json does not match bookmarklets.sha256.
            Copy dugcanlift-kit/bookmarklet/bookmarklets.json AND bookmarklets.sha256 over together.
            Never edit either file here, and never re-write the checksum by hand to make this
            pass: the kit writes both with `node bookmarklet/build-bookmarklets.mjs`.
            """)
    }

    /// What the sheet shows and copies is the `liftApp` string as the kit wrote
    /// it, and it opens this app's recipe host.
    func testTheSheetShowsTheLiftAppTarget() throws {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "bookmarklets", withExtension: "json"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let liftApp = try XCTUnwrap(object["liftApp"] as? String)
        XCTAssertEqual(Bookmarklet.liftApp(in: bundle), liftApp)
        XCTAssertEqual(Bookmarklet.liftApp(in: .main), liftApp, "the app bundle carries the same file")
        XCTAssertTrue(liftApp.hasPrefix("javascript:"))
        XCTAssertTrue(liftApp.contains("dugcanliftlift%3A%2F%2Frecipe"), "the liftApp target, not another app's")
        XCTAssertFalse(liftApp.contains("dugcanliftcoach"))
    }
}
