import SwiftUI
import SwiftData

@main
struct LiftApp: App {
    @State private var incomingPlan: PlanPayload?
    @State private var planLinkError: PlanLinkError?

    var body: some Scene {
        WindowGroup {
            RootView()
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
                .sheet(item: $incomingPlan) { payload in
                    PlanPreviewView(payload: payload)
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
        guard let fragment = url.fragment else { return }
        do {
            let payload = try PlanLinkCodec.decode(
                fragment: fragment,
                expectedLifterID: CoachShare.Settings.lifterID
            )
            incomingPlan = payload
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
