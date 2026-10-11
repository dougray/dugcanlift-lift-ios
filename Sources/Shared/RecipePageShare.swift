import Foundation
import LiftCore

/// What Safari's `RecipePage.js` hands the share extension when a page is
/// shared: the page's address and the text of every `application/ld+json`
/// block on it. Safari already has the page on screen, so LIFT requests
/// nothing. Compiled into the app, its share extension and the widget;
/// Foundation and LiftCore only.
struct SharedRecipePage: Equatable {
    var url: URL
    var blocks: [String]

    init(url: URL, blocks: [String]) {
        self.url = url
        self.blocks = blocks
    }

    /// Reads the dictionary Safari passes under
    /// `NSExtensionJavaScriptPreprocessingResultsKey`. Nil when it is not the
    /// shape `RecipePage.js` produces.
    init?(preprocessingResults results: Any?) {
        guard let dictionary = results as? [String: Any],
              let address = dictionary["url"] as? String,
              let url = URL(string: address)
        else { return nil }
        // Tolerant: one non-string entry must not drop every good block.
        let blocks = ((dictionary["jsonld"] as? [Any]) ?? []).compactMap { $0 as? String }
        self.init(url: url, blocks: blocks)
    }

    /// The first block that holds a schema.org Recipe, and the recipe read
    /// from it. The block is what gets queued: the raw text is the contract.
    func firstRecipe() -> (block: String, recipe: ImportedRecipe)? {
        for block in blocks {
            if let recipe = RecipeJSONLD.recipe(fromJSON: block) { return (block, recipe) }
        }
        return nil
    }
}

/// The share sheet's answer to what was shared, in the order the spec fixes:
/// a plan link always wins, then a recipe, then neither.
enum RecipeShareDecision: Equatable {
    /// Leave it to the link flow that existed before recipes came from Safari,
    /// reading `candidates`: what was shared, plus the page's own address when
    /// Safari passed the page. Safari may hand over only the page, and the LIFT
    /// web app's address with no plan in it is a link-flow answer of its own.
    case useLinkFlow(candidates: [String])
    case recipe(name: String, servings: Double?, item: PendingRecipeImports.Item)
    /// A page from Safari with no link and no recipe card.
    case noRecipe

    /// `isLink` is the app's own link predicate, passed in so this file stays
    /// Foundation and LiftCore only.
    static func decide(candidates: [String], page: SharedRecipePage?,
                       isLink: (String) -> Bool) -> RecipeShareDecision {
        guard let page else { return .useLinkFlow(candidates: candidates) }
        let withPage = candidates + [page.url.absoluteString]
        if withPage.contains(where: isLink) { return .useLinkFlow(candidates: withPage) }
        guard let found = page.firstRecipe() else { return .noRecipe }
        return .recipe(name: found.recipe.name, servings: found.recipe.servings,
                       item: .init(block: found.block, pageURL: page.url.absoluteString))
    }
}
