import XCTest
import LiftCore
@testable import Lift

final class RecipePageShareTests: XCTestCase {

    // The shapes publishers actually use: a bare object, an array, an @graph.
    static let bare = #"{"@context":"https://schema.org","@type":"Recipe","name":"Beef Chilli","recipeYield":"4","recipeIngredient":["500 g beef mince","400 g kidney beans"],"recipeInstructions":["Brown the beef.","Simmer."]}"#
    static let array = #"[{"@type":"WebSite","name":"A site"},{"@type":"Recipe","name":"Overnight Oats","recipeIngredient":["60 g rolled oats"]}]"#
    static let graph = #"{"@context":"https://schema.org","@graph":[{"@type":"Organization","name":"A publisher"},{"@type":"Recipe","name":"Salmon Traybake","recipeIngredient":["2 salmon fillets"]}]}"#
    static let article = #"{"@context":"https://schema.org","@type":"Article","headline":"Ten tips"}"#

    let recipePage = URL(string: "https://example.org/beef-chilli")!
    let noLinks: (String) -> Bool = { _ in false }

    func testReadsWhatRecipePageJSReturns() {
        let page = SharedRecipePage(preprocessingResults: ["url": "https://example.org/a", "jsonld": [Self.bare]])
        XCTAssertEqual(page, SharedRecipePage(url: URL(string: "https://example.org/a")!, blocks: [Self.bare]))
        XCTAssertNil(SharedRecipePage(preprocessingResults: ["jsonld": [Self.bare]]), "no address")
        XCTAssertNil(SharedRecipePage(preprocessingResults: "not a dictionary"))
        XCTAssertEqual(SharedRecipePage(preprocessingResults: ["url": "https://example.org/a"])?.blocks, [])
        XCTAssertEqual(SharedRecipePage(preprocessingResults: ["url": "https://example.org/a", "jsonld": [Self.bare, 42]])?.blocks,
                       [Self.bare], "one non-string entry must not drop the good blocks")
    }

    /// Blank stays blank: a page that states no yield is an unknown number of
    /// servings, never 1 and never 4.
    func testAnUnstatedYieldIsUnknown() {
        let toast = #"{"@type":"Recipe","name":"Plain Toast","recipeIngredient":["2 slices bread"]}"#
        let page = SharedRecipePage(url: recipePage, blocks: [toast])
        let decision = RecipeShareDecision.decide(candidates: [recipePage.absoluteString], page: page, isLink: noLinks)
        guard case let .recipe(name, servings, item) = decision else { return XCTFail("expected a recipe, got \(decision)") }
        XCTAssertEqual(name, "Plain Toast")
        XCTAssertNil(servings)
        XCTAssertEqual(item, .init(block: toast, pageURL: recipePage.absoluteString))
    }

    func testFindsTheRecipeInEveryShape() {
        for (block, name) in [(Self.bare, "Beef Chilli"), (Self.array, "Overnight Oats"), (Self.graph, "Salmon Traybake")] {
            let found = SharedRecipePage(url: recipePage, blocks: [Self.article, block]).firstRecipe()
            XCTAssertEqual(found?.recipe.name, name)
            XCTAssertEqual(found?.block, block, "the raw block that held it is what gets queued")
        }
    }

    func testARecipePageOffersTheRecipe() {
        let page = SharedRecipePage(url: recipePage, blocks: [Self.bare])
        let decision = RecipeShareDecision.decide(candidates: [recipePage.absoluteString], page: page, isLink: noLinks)
        // Servings as the kit's own parser reads them: this tests the routing,
        // and RecipeJSONLDTests in the kit already pin how a yield is read.
        let servings = RecipeJSONLD.recipe(fromJSON: Self.bare)?.servings
        XCTAssertEqual(decision, .recipe(name: "Beef Chilli", servings: servings,
                                         item: .init(block: Self.bare, pageURL: recipePage.absoluteString)))
    }

    func testALinkAlwaysWins() {
        let page = SharedRecipePage(url: recipePage, blocks: [Self.bare])
        let decision = RecipeShareDecision.decide(candidates: ["a link"], page: page,
                                                  isLink: { $0 == "a link" })
        XCTAssertEqual(decision, .useLinkFlow(candidates: ["a link", recipePage.absoluteString]))
    }

    /// A real plan link in what was shared beats a recipe card on the page,
    /// read with the predicate the share extension itself uses.
    func testARealLinkWinsOverARecipePage() {
        let link = "https://www.dugcanlift.com/lift/#1zABCDEF"
        let page = SharedRecipePage(url: recipePage, blocks: [Self.bare])
        let decision = RecipeShareDecision.decide(candidates: [link], page: page, isLink: PlanLinkExtractor.isLink)
        guard case let .useLinkFlow(candidates) = decision else { return XCTFail("expected the link flow, got \(decision)") }
        XCTAssertTrue(candidates.contains(link))
    }

    func testAPageThatIsItselfALinkUsesTheLinkFlow() {
        let page = SharedRecipePage(url: URL(string: "https://www.dugcanlift.com/lift/")!, blocks: [])
        let decision = RecipeShareDecision.decide(candidates: [], page: page,
                                                  isLink: { $0.contains("dugcanlift.com/lift/") })
        XCTAssertEqual(decision, .useLinkFlow(candidates: ["https://www.dugcanlift.com/lift/"]))
    }

    /// The Coach web page with no log in it is not a link LIFT answers, so a
    /// page-only share of it is a page with no recipe card -- by design.
    func testAPageOnlyCoachWebPageHasNoRecipeCard() {
        let page = SharedRecipePage(url: URL(string: "https://www.dugcanlift.com/coach/")!, blocks: [])
        XCTAssertEqual(RecipeShareDecision.decide(candidates: [], page: page, isLink: PlanLinkExtractor.isLink),
                       .noRecipe)
    }

    /// Safari may hand over only the page (no `public.url`). The LIFT web
    /// app's own address must still reach the link flow, or the lifter is told
    /// "not a plan link" instead of "the plan isn't in this address".
    func testAPageOnlyLiftPageReachesTheLinkFlowWithItsAddress() {
        let liftPage = URL(string: "https://www.dugcanlift.com/lift/")!
        let page = SharedRecipePage(url: liftPage, blocks: [])
        let decision = RecipeShareDecision.decide(candidates: [], page: page, isLink: PlanLinkExtractor.isLink)
        guard case let .useLinkFlow(candidates) = decision else { return XCTFail("expected the link flow, got \(decision)") }
        XCTAssertTrue(candidates.contains(liftPage.absoluteString), "the page's address is what the link flow reads")
        XCTAssertTrue(candidates.contains(where: PlanLinkExtractor.isLiftPageWithoutPlan),
                      "which the link flow answers as the LIFT page with no plan in its address")
        // And the link flow's own reading of those candidates, as the share
        // extension's `resolveLink` reads them, says exactly that.
        XCTAssertTrue(candidates.contains { PlanLinkIntake.read($0, expectedLifterID: "a1b2c3d4") == .refused(.pageWithoutPlan) },
                      "the lifter is told the plan isn't in this address")
    }

    /// The lifter's own log link, shared from Safari with the page, is the link
    /// flow's to refuse in its own words -- never offered as a recipe.
    func testACoachLogLinkWinsOverARecipePage() {
        let log = "https://www.dugcanlift.com/coach/#1zABCDEF"
        let page = SharedRecipePage(url: recipePage, blocks: [Self.bare])
        let decision = RecipeShareDecision.decide(candidates: [log], page: page, isLink: PlanLinkExtractor.isLink)
        guard case let .useLinkFlow(candidates) = decision else { return XCTFail("expected the link flow, got \(decision)") }
        XCTAssertTrue(candidates.contains { PlanLinkIntake.read($0, expectedLifterID: "a1b2c3d4") == .refused(.ownLogLink) })
    }

    func testARecipePageWithNoLinkIsARecipeUnderTheRealPredicate() {
        let page = SharedRecipePage(url: recipePage, blocks: [Self.bare])
        let decision = RecipeShareDecision.decide(candidates: [recipePage.absoluteString], page: page,
                                                  isLink: PlanLinkExtractor.isLink)
        guard case .recipe = decision else { return XCTFail("expected a recipe, got \(decision)") }
    }

    func testTheLinkPredicate() {
        XCTAssertTrue(PlanLinkExtractor.isLink("https://www.dugcanlift.com/lift/#1zABCDEF"))
        XCTAssertTrue(PlanLinkExtractor.isLink("https://www.dugcanlift.com/lift/"), "the LIFT page with no plan")
        XCTAssertTrue(PlanLinkExtractor.isLink("https://www.dugcanlift.com/coach/#1zABCDEF"), "the lifter's own log link")
        XCTAssertFalse(PlanLinkExtractor.isLink("https://www.dugcanlift.com/coach/"), "the Coach web page, no log")
        XCTAssertFalse(PlanLinkExtractor.isLink(recipePage.absoluteString))
        XCTAssertFalse(PlanLinkExtractor.isLink("https://example.org/#1zABCDEF"), "another site's fragment")
    }

    func testAPageWithNoRecipeSaysSo() {
        let page = SharedRecipePage(url: recipePage, blocks: [Self.article])
        XCTAssertEqual(RecipeShareDecision.decide(candidates: [recipePage.absoluteString], page: page, isLink: noLinks),
                       .noRecipe)
        XCTAssertEqual(RecipeShareDecision.decide(candidates: [], page: SharedRecipePage(url: recipePage, blocks: []),
                                                  isLink: noLinks),
                       .noRecipe)
    }

    func testNotFromSafariLeavesItToTheLinkFlow() {
        XCTAssertEqual(RecipeShareDecision.decide(candidates: ["some text"], page: nil, isLink: noLinks),
                       .useLinkFlow(candidates: ["some text"]), "the link flow already says what it says for stray text")
    }
}
