import SwiftUI
import SwiftData
import LiftCore

/// Paste a Plan Link: the way a coach's plan reaches LIFT when tapping the
/// link does not open the app.
///
/// It usually does not. Universal Links need the Associated Domains
/// entitlement, which a free Apple Personal Team cannot sign (see the
/// Makefile's `FREE_ENTITLEMENTS`), so on a free-team build a
/// `www.dugcanlift.com/lift/#...` link opens the browser and nothing reaches
/// here. This screen, `dugcanliftlift://plan#...` and the share extension are
/// the three doors that do not need one — the same three Coach iOS has, and
/// they accept and refuse exactly the same text because all three ask
/// `PlanLinkIntake`.
///
/// Accepting is `PlanPreviewView`'s job, unchanged: this screen only decides
/// whether there is a plan in the text and says what it is. Nothing is written
/// until the lifter taps Accept there.
struct PastePlanLinkView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    /// Recomputed as the text changes, so a good link names itself the moment
    /// it lands. A refusal is held back until Open is tapped: half a link
    /// typed or pasted in pieces is not yet a mistake worth a red sentence.
    @State private var outcome: PlanLinkIntake.Outcome?
    @State private var showsRefusal = false
    @State private var plan: IdentifiablePlan?

    private var readyPlan: PlanPayload? {
        if case .plan(let payload) = outcome { return payload }
        return nil
    }

    private var refusal: PlanLinkIntake.Refusal? {
        if case .refused(let reason) = outcome { return reason }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 120)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Paste the link your coach sent you")
                } footer: {
                    Text(verbatim: "It starts with www.dugcanlift.com/lift/#. Nothing is uploaded — the plan travels inside the link itself.")
                }

                if let readyPlan {
                    Section {
                        Label(PlanLinkExtractor.summary(of: readyPlan), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button("Open Plan") { open(readyPlan) }
                    }
                }

                if showsRefusal, let refusal {
                    Section {
                        Text(refusal.message)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Paste a Plan Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open") {
                        if let readyPlan { open(readyPlan) } else { showsRefusal = true }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(item: $plan) { plan in
                PlanPreviewView(payload: plan.payload)
                    .liftAppearance()
            }
            .onChange(of: text, initial: false) { _, latest in
                showsRefusal = false
                let trimmed = latest.trimmingCharacters(in: .whitespacesAndNewlines)
                outcome = trimmed.isEmpty
                    ? nil
                    : PlanLinkIntake.read(trimmed, expectedLifterID: CoachShare.Settings.lifterID)
            }
        }
    }

    private func open(_ payload: PlanPayload) {
        plan = IdentifiablePlan(payload: payload)
    }
}
