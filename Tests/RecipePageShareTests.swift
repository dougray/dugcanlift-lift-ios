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
        XCTAssertEqual(decision, .useLinkFlow)
    }

    func testAPageThatIsItselfALinkUsesTheLinkFlow() {
        let page = SharedRecipePage(url: URL(string: "https://www.dugcanlift.com/coach/")!, blocks: [])
        let decision = RecipeShareDecision.decide(candidates: [], page: page,
                                                  isLink: { $0.contains("dugcanlift.com/coach/") })
        XCTAssertEqual(decision, .useLinkFlow)
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
                       .useLinkFlow, "the link flow already says what it says for stray text")
    }
}
