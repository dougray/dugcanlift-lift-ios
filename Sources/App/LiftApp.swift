import SwiftUI
import SwiftData

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
private struct IdentifiablePlan: Identifiable {
    let id = UUID()
    let payload: PlanPayload
}

@main
struct LiftApp: App {
    @State private var incomingPlan: IdentifiablePlan?
    @State private var planLinkError: PlanLinkError?

    // `WatchSyncReceiver` doesn't drive any UI, so it isn't `@State` — it
    // just needs to exist for the app's lifetime so its `WCSessionDelegate`
    // stays registered. `init()` (below) is where it's actually built,
    // because that's the one place in this type that's guaranteed to run on
    // the main actor before this: `App.init()` is declared `@MainActor` by
    // SwiftUI itself, which `LiftStore.shared.mainContext` needs.
    init() {
        WatchSyncReceiver.activate(context: LiftStore.shared.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
                .sheet(item: $incomingPlan) { identifiablePlan in
                    PlanPreviewView(payload: identifiablePlan.payload)
                }
                .alert("Couldn't open this plan", isPresented: .constant(planLinkError != nil), presenting: planLinkError) { _ in
                    Button("OK") { planLinkError = nil }
                } message: { error in
                    Text(message(for: error))
                }
        }
        .modelContainer(LiftStore.shared)
    }

    private func handleIncomingURL(_ url: URL) {
        // The Associated Domains entitlement covers the whole
        // www.dugcanlift.com host (not just /lift/*), so a coach's own
        // `/coach/#...` log link — a different link type/destination
        // (CoachShare.swift) — also lands here once Universal Links
        // verification is live. Only a `/lift/...` path is meant for LIFT to
        // handle; anything else is silently left alone, same as "no
        // fragment" below, since it isn't an error, just not ours.
        guard url.path.hasPrefix("/lift") else { return }
        guard let fragment = url.fragment else { return }
        do {
            let payload = try PlanLinkCodec.decode(
                fragment: fragment,
                expectedLifterID: CoachShare.Settings.lifterID
            )
            incomingPlan = IdentifiablePlan(payload: payload)
            planLinkError = nil
        } catch let error as PlanLinkError {
            incomingPlan = nil
            planLinkError = error
        } catch {
            incomingPlan = nil
            planLinkError = .corruptPayload
        }
    }

    private func message(for error: PlanLinkError) -> String {
        switch error {
        case .notAddressedToThisDevice:
            return "This plan isn't addressed to you."
        default:
            return "This plan link couldn't be read."
        }
    }
}
