import SwiftUI
import SwiftData
import LiftCore

/// Wraps a decoded plan in its own identity for `.sheet(item:)`.
///
/// `PlanPayload` itself is not `Identifiable`: `l` (recipient), `n` (coach
/// name), and `v` (always 1) are constant across every plan a given coach
/// sends a given client, so any id derived from those fields alone collides
/// across distinct plans. A content hash (`PlanImporter.hash(of:)`) would be
/// genuinely unique, but calling it from here would point this decode-only
/// codec's dependency at `PlanImporter.swift`, which already depends on
/// `PlanLinkCodec.swift`'s types — the wrong direction. A fresh `UUID` at the
/// point a payload is captured into `@State` sidesteps that entirely and is
/// exactly as unique as `.sheet(item:)` needs: every distinct decode gets its
/// own identity, so a second plan link arriving while the first's preview
/// sheet is still open is never mistaken for the same item.
struct IdentifiablePlan: Identifiable {
    let id = UUID()
    /// The payload and the road picks that arrived with it, kept together --
    /// see `PlanLinkIntake.IncomingPlan`.
    let plan: PlanLinkIntake.IncomingPlan
}

@main
struct LiftApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var incomingPlan: IdentifiablePlan?
    @State private var refusal: PlanLinkIntake.Refusal?
    /// Recipes Safari handed over, and the rules for when each may open. Its
    /// held "reports" are plan outcomes: a plan sheet or a refusal alert that
    /// arrives while a recipe is under review would be dropped by SwiftUI,
    /// which presents one thing at a time on this view, so it waits here.
    @State private var recipes = RecipeReviewQueue<PlanLinkIntake.Outcome>()

    // `WatchSyncReceiver` doesn't drive any UI, so it isn't `@State` — it
    // just needs to exist for the app's lifetime so its `WCSessionDelegate`
    // stays registered. `init()` (below) is where it's actually built,
    // because that's the one place in this type that's guaranteed to run on
    // the main actor before this: `App.init()` is declared `@MainActor` by
    // SwiftUI itself, which `LiftStore.shared.mainContext` needs.
    init() {
        WatchSyncReceiver.activate(context: LiftStore.shared.mainContext)
        // The share extension has its own defaults and cannot read this id,
        // which it needs before `PlanLinkCodec` will hand it a payload at all.
        // Written once; a no-op on every launch after the first.
        PendingPlanLinks.shared?.mirror(lifterID: CoachShare.Settings.lifterID)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.appIsPresenting,
                             recipes.reviewing != nil || incomingPlan != nil || refusal != nil)
                // `dugcanliftlift://plan#1z...`, LIFT's own scheme, which
                // needs no entitlement — and, on a paid team where Associated
                // Domains can be signed, a `www.dugcanlift.com/lift/#...`
                // Universal Link. Both go through the same intake, so a link
                // that opens one way opens the other.
                .onOpenURL { url in
                    handle(PlanLinkIntake.open(url, expectedLifterID: CoachShare.Settings.lifterID))
                }
                // `.active` covers both a cold launch and returning from the
                // share sheet, which is when the extension's queue has
                // something in it.
                // Plans first, then recipes, the order the extension decides in.
                .onChange(of: scenePhase, initial: true) { _, phase in
                    guard phase == .active else { return }
                    recipes.activated()
                    drainSharedPlans()
                    if let drained = PendingRecipeImports.shared {
                        recipes.enqueue(drained.takeAll())
                    }
                    presentNextRecipe()
                }
                // One presentation at a time on this view: a recipe waits for
                // the plan sheet and the refusal alert, and tries again when
                // either goes away (see `RecipeReviewQueue`). The sheet's
                // `onDismiss` runs once its dismissal has finished, which is
                // when the next presentation may start; an alert has no such
                // callback, so it is watched.
                .onChange(of: refusal == nil) { _, clear in
                    if clear { advance() }
                }
                .sheet(item: $incomingPlan, onDismiss: advance) { identifiablePlan in
                    PlanPreviewView(plan: identifiablePlan.plan)
                }
                .sheet(item: Binding(get: { recipes.reviewing },
                                     set: { if $0 == nil { recipes.dismissed() } }),
                       onDismiss: afterRecipeReview) { queued in
                    RecipeImportView(item: queued.item)
                        .onAppear { recipes.markAppeared() }
                        // Cancel and Save only: a swipe that ended the review
                        // would drop a recipe that is already gone from the
                        // App Group.
                        .interactiveDismissDisabled()
                        .liftAppearance()
                }
                .alert("Couldn't open this plan", isPresented: .constant(refusal != nil), presenting: refusal) { _ in
                    Button("OK") { refusal = nil }
                } message: { refusal in
                    Text(refusal.message)
                }
        }
        .modelContainer(LiftStore.shared)
    }

    /// Plans the share extension queued while LIFT was not running. Each goes
    /// through the same intake a pasted link does. There is one preview sheet,
    /// so when several are waiting the last one that decodes is the one shown
    /// — the rest stay out of the library, which is the safe direction: a plan
    /// is only ever added by tapping Accept. Plans arriving while a recipe is
    /// under review are different: they are held, and each is shown in order
    /// once the review ends (see `handle`).
    private func drainSharedPlans() {
        guard let inbox = PendingPlanLinks.shared else { return }
        let queued = inbox.takeAll()
        guard !queued.isEmpty else { return }
        for fragment in queued {
            handle(PlanLinkIntake.read(fragment, expectedLifterID: CoachShare.Settings.lifterID))
        }
    }

    /// A plan or refusal ready to show. With a recipe under review it is held
    /// instead (nothing else may present beside it) and shown when the review
    /// ends, before the next recipe.
    private func handle(_ outcome: PlanLinkIntake.Outcome) {
        if case .ignored = outcome { return }
        if let now = recipes.report(outcome) { show(now) }
    }

    /// Opens the next waiting recipe, unless something is already on screen.
    private func presentNextRecipe() {
        _ = recipes.next(canPresent: incomingPlan == nil && refusal == nil)
    }

    /// A review ended: end it (idempotently), then `advance()`.
    private func afterRecipeReview() {
        recipes.dismissed()
        advance()
    }

    /// Whatever is on screen has gone. A plan or refusal that arrived during a
    /// review is shown first, and the next recipe opens once it has gone too;
    /// with none held, it opens at once.
    private func advance() {
        // Still something up (a sheet's dismissal can finish while an alert
        // is already showing): the next one waits for that to go too.
        guard incomingPlan == nil && refusal == nil else { return }
        if let held = recipes.takeHeldReport() { show(held); return }
        presentNextRecipe()
    }

    private func show(_ outcome: PlanLinkIntake.Outcome) {
        switch outcome {
        case .ignored:
            return
        case .plan(let incoming):
            incomingPlan = IdentifiablePlan(plan: incoming)
            refusal = nil
        case .refused(let reason):
            incomingPlan = nil
            refusal = reason
        }
    }
}
