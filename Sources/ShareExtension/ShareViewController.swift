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
            model.resolve(candidates: await Self.candidateTexts(in: items))
        }
    }

    /// Every string the share could be carrying a link in: shared URLs,
    /// shared text, and the item's own text (Messages and Mail put the
    /// message body there). Order is only a preference; the first that
    /// decodes wins.
    private static func candidateTexts(in items: [NSExtensionItem]) async -> [String] {
        var texts: [String] = []
        for item in items {
            for provider in item.attachments ?? [] {
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
        return texts
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
    }

    @Published var state: State = .reading
    var finish: () -> Void = {}

    func resolve(candidates: [String]) {
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
            case .plan(let payload):
                guard let fragment = PlanLinkExtractor.fragment(in: text) else { continue }
                state = .ready(summary: PlanLinkExtractor.summary(of: payload), fragment: fragment)
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
