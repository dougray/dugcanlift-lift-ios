import UIKit
import SwiftUI
import UniformTypeIdentifiers
import LiftCore

/// The share sheet's entry point: finds a coach's plan link in what was
/// shared, says what it is, and queues its fragment for the app
/// (`PendingPlanLinks`). LIFT shows the plan the next time it comes to the
/// foreground, through Paste a Plan Link's own code path.
///
/// Nothing here touches SwiftData, and nothing here accepts a plan. The link
/// is decoded only to show who it is from and to refuse a bad one before the
/// lifter leaves the share sheet; Accept still happens on `PlanPreviewView`
/// in the app.
///
/// A port of Coach iOS's `ShareViewController`, in the other direction: there
/// a coach receives a client's log, here a lifter receives a coach's plan.
final class ShareViewController: UIViewController {

    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.finish = { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }

        let host = UIHostingController(rootView: SharePlanView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)

        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        Task { @MainActor in
            let shared = await Self.sharedContent(in: items)
            model.resolve(candidates: shared.texts, page: shared.page)
        }
    }

    /// Every string the share could be carrying a link in -- shared URLs,
    /// shared text, the item's own text (Messages and Mail put the message
    /// body there) -- and, when the share came from Safari, what RecipePage.js
    /// returned. Order is only a preference; the first that decodes wins.
    private static func sharedContent(in items: [NSExtensionItem]) async -> (texts: [String], page: SharedRecipePage?) {
        var texts: [String] = []
        var page: SharedRecipePage?
        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier),
                   let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier),
                   let results = (loaded as? NSDictionary)?[NSExtensionJavaScriptPreprocessingResultsKey] {
                    page = page ?? SharedRecipePage(preprocessingResults: results)
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    texts.append(url.absoluteString)
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) {
                    if let string = loaded as? String { texts.append(string) }
                    else if let data = loaded as? Data, let string = String(data: data, encoding: .utf8) { texts.append(string) }
                }
            }
            if let body = item.attributedContentText?.string, !body.isEmpty {
                texts.append(body)
            }
        }
        return (texts, page)
    }
}

@MainActor
final class ShareModel: ObservableObject {

    enum State {
        case reading
        case ready(summary: String, fragment: String)
        /// Refused before the lifter leaves the share sheet, with the same
        /// sentence Paste a Plan Link would have given for the same text.
        case refused(PlanLinkIntake.Refusal)
        /// LIFT has never been opened on this phone, so the lifter's own id
        /// has not been mirrored into the App Group and no plan can be
        /// checked against it. Said plainly rather than queueing a link that
        /// might not be theirs.
        case needsApp
        /// The build is missing the App Group entitlement, so nothing written
        /// here would reach the app. Said plainly rather than failing quietly.
        case noSharedStorage
        /// The same missing App Group, met while adding a recipe rather than a
        /// link. Kept apart from `noSharedStorage`, whose words are about
        /// links; the way round for a recipe is Paste a recipe.
        case noSharedStorageForRecipe
        /// A schema.org recipe on the page Safari shared.
        case recipe(name: String, servings: Double?, item: PendingRecipeImports.Item)
        /// A page from Safari with no plan link and no recipe card.
        case noRecipe
    }

    @Published var state: State = .reading
    var finish: () -> Void = {}

    /// A plan link, the LIFT page with no plan in it, or the lifter's own
    /// log link -- everything the link flow answers. None of these needs the
    /// lifter's id, so a recipe can be told apart before that gate, and a
    /// recipe works on a phone where LIFT has never been opened.
    static func isLink(_ text: String) -> Bool {
        PlanLinkExtractor.fragment(in: text) != nil
            || PlanLinkExtractor.isLiftPageWithoutPlan(text)
            || PlanLinkExtractor.isCoachLogLink(text)
    }

    func resolve(candidates: [String], page: SharedRecipePage?) {
        switch RecipeShareDecision.decide(candidates: candidates, page: page, isLink: Self.isLink) {
        case .useLinkFlow:
            resolveLink(candidates: candidates)
        case let .recipe(name, servings, item):
            state = .recipe(name: name, servings: servings, item: item)
        case .noRecipe:
            state = .noRecipe
        }
    }

    func addRecipe(_ item: PendingRecipeImports.Item) {
        guard let inbox = PendingRecipeImports.shared, (try? inbox.add(item)) != nil else {
            state = .noSharedStorageForRecipe
            return
        }
        finish()
    }

    private func resolveLink(candidates: [String]) {
        guard let inbox = PendingPlanLinks.shared else {
            state = .noSharedStorage
            return
        }
        guard let lifterID = inbox.lifterID else {
            state = .needsApp
            return
        }

        var firstRefusal: PlanLinkIntake.Refusal?
        for text in candidates {
            switch PlanLinkIntake.read(text, expectedLifterID: lifterID) {
            case .plan(let incoming):
                guard let fragment = PlanLinkExtractor.fragment(in: text) else { continue }
                // The picks are named here too, or a plan that is only picks
                // would be offered as a plan with nothing in it.
                state = .ready(summary: PlanLinkExtractor.summary(
                    of: incoming.payload, roadPickCount: incoming.roadPickIDs.count),
                    fragment: fragment)
                return
            case .refused(let reason):
                // Safari hands over the page address as well as the message
                // body, so the most specific reason among the candidates is
                // the one worth showing -- "not a plan link" is what every
                // stray line says.
                if firstRefusal == nil || firstRefusal == .notAPlanLink { firstRefusal = reason }
            case .ignored:
                continue
            }
        }
        state = .refused(firstRefusal ?? .notAPlanLink)
    }

    func add(_ fragment: String) {
        guard let inbox = PendingPlanLinks.shared else {
            state = .noSharedStorage
            return
        }
        inbox.add(fragment)
        finish()
    }
}

struct SharePlanView: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                content
                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.background)
            .navigationTitle("LIFT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.finish() }
                        .foregroundStyle(Theme.textSecondary)
                }
                if case .ready(_, let fragment) = model.state {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") { model.add(fragment) }
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.accent)
                    }
                }
                if case .recipe(_, _, let item) = model.state {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") { model.addRecipe(item) }
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
        }
        .tint(Theme.accent)
        .liftAppearance()
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .reading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
        case .ready(let summary, _):
            LiftCard(title: "Send to LIFT") {
                Text(summary)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("Open LIFT and it will show you the plan. Nothing is added to your routines until you accept it there.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .refused(let reason):
            LiftCard {
                Text(title(for: reason))
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                // Verbatim, or SwiftUI turns the address into a tappable link.
                Text(verbatim: reason.message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .needsApp:
            LiftCard {
                Text("Open LIFT once first")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("LIFT hasn't been opened on this phone yet, so there's nothing to check this plan against. Open it once, then share the link again.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .noSharedStorage:
            LiftCard {
                Text("This build of LIFT can't pass links from the share sheet. Copy the link and use Paste a Plan Link in Settings instead.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
            }
        case .noSharedStorageForRecipe:
            LiftCard {
                Text("This build of LIFT can't pass recipes from the share sheet")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("Copy the recipe's text and use Paste a recipe in LIFT instead.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        case let .recipe(name, servings, _):
            LiftCard(title: "Add to LIFT") {
                Text("Add \(name)")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                if let servings {
                    Text("Serves \(CookFormat.trimmed(servings))")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                }
                Text("LIFT shows it for review the next time you open it.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .noRecipe:
            LiftCard {
                Text("There's no recipe card on this page")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("Copy the recipe's text and use Paste a recipe in LIFT instead.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    /// A headline for the card. Deliberately not a shortening of the message
    /// below it -- measured on the simulator, where "The plan isn't in this
    /// address" appeared as both and read like a stutter.
    private func title(for refusal: PlanLinkIntake.Refusal) -> String {
        switch refusal {
        case .notAPlanLink:           return "That isn't a plan link"
        case .ownLogLink:             return "This link goes the other way"
        case .pageWithoutPlan:        return "Shared from the open page"
        case .link(.notAddressedToThisDevice): return "This plan isn't for this phone"
        case .link:                   return "This plan link couldn't be read"
        }
    }
}
