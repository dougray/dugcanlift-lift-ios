import SwiftUI
import SwiftData
import MessageUI

/// "Send to Coach" — one tap opens Mail with the whole thing written.
///
/// The final Send belongs to the mail composer, not to this app. Sending
/// silently would mean holding the person's mail credentials or standing up a
/// server, and neither belongs in a tracker that otherwise keeps everything on
/// the phone. Nothing has to be typed or attached, which is the part that
/// matters.
struct CoachSection: View {
    @AppStorage("weightUnit") private var unitRaw = WeightUnit.pounds.rawValue
    @AppStorage("goalCalories") private var goalCalories = 1748.0
    @AppStorage("goalProtein") private var goalProtein = 160.0
    @AppStorage("goalFat") private var goalFat = 49.0
    @AppStorage("goalCarbs") private var goalCarbs = 167.0
    @AppStorage("goalFiber") private var goalFiber = 24.0
    @AppStorage("goalIsSet") private var goalIsSet = false

    @AppStorage("coachEmail") private var email = ""
    @AppStorage("coachLifterName") private var lifterName = ""
    @AppStorage("coachWeeks") private var weeks = 8
    @AppStorage("coachItemisedFood") private var itemisedFood = false

    @Query(sort: \WorkoutDay.date, order: .reverse) private var days: [WorkoutDay]
    @Query private var food: [FoodEntry]
    @Query private var measurements: [BodyMeasurement]

    @State private var health = HealthKitManager.shared
    /// Read from HealthKit rather than stored, so it is whatever Health
    /// believes right now — including steps a Watch logged. Empty when the
    /// permission was declined, which costs the step lines and nothing else.
    @State private var steps: [String: Int] = [:]
    @State private var isEditing = false
    @State private var linkSize: String?
    @State private var composing: Composition?
    @State private var problem: String?

    private var unit: WeightUnit { WeightUnit(rawValue: unitRaw) ?? .pounds }

    private var snapshot: CoachShare.Snapshot {
        CoachShare.Snapshot(
            days: days,
            food: food,
            measurements: measurements,
            steps: steps,
            goal: goalIsSet ? .init(
                calories: Int(goalCalories), proteinG: Int(goalProtein),
                fatG: Int(goalFat), carbsG: Int(goalCarbs), fiberG: Int(goalFiber)
            ) : nil,
            unit: unit
        )
    }

    var body: some View {
        Section("Coach") {
            if isEditing || email.isEmpty {
                TextField("Your name", text: $lifterName)
                    .textInputAutocapitalization(.words)
                TextField("Coach's email", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Text("Put their email in once and you can send them your training "
                     + "and eating with one tap.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Save") { isEditing = false }
                    .disabled(!email.contains("@") || !email.contains("."))
            } else {
                LabeledContent("Sends to", value: email)

                Picker("How much", selection: $weeks) {
                    ForEach(CoachShare.windowChoices, id: \.self) { choice in
                        Text(choice == 26 ? "6 months" : "\(choice) weeks").tag(choice)
                    }
                }

                Toggle("Include every food logged", isOn: $itemisedFood)

                Button("Send to Coach", systemImage: "paperplane.fill") { compose() }

                if let linkSize {
                    Text(linkSize)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Your log travels inside the link itself. It is never uploaded "
                     + "anywhere, and there is no account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Change these details") { isEditing = true }
            }
        }
        .task(id: "\(weeks)-\(itemisedFood)-\(days.count)-\(food.count)") {
            steps = (try? await health.dailyStepCounts(days: weeks * 7)) ?? [:]
            measureLink()
        }
        .sheet(item: $composing) { composition in
            MailComposer(composition: composition) { composing = nil }
        }
        .alert("Couldn't send", isPresented: .constant(problem != nil)) {
            Button("OK") { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    /// Recomputed rather than guessed: the person deserves to know how long the
    /// email is before they send one their coach's mail app might mangle.
    private func measureLink() {
        guard !email.isEmpty else { return }
        guard let link = try? CoachShare.buildLink(from: snapshot) else {
            linkSize = nil
            return
        }
        let kb = Double(link.count) / 1024
        linkSize = String(format: "About %.1f KB of email.", kb)
            + (CoachShare.linkIsRisky(link)
               ? " That is long enough that some mail apps will break it — send a shorter window."
               : "")
    }

    private func compose() {
        do {
            let link = try CoachShare.buildLink(from: snapshot)
            let summary = CoachShare.weekSummary(from: snapshot)

            guard MFMailComposeViewController.canSendMail() else {
                // No Mail account: hand it to whatever the system opens for
                // mailto: instead of dead-ending.
                let body = CoachShare.plainBody(link: link, summary: summary, weeks: weeks)
                var components = URLComponents(string: "mailto:\(email)")
                components?.queryItems = [
                    URLQueryItem(name: "subject", value: CoachShare.subject),
                    URLQueryItem(name: "body", value: body),
                ]
                if let url = components?.url {
                    UIApplication.shared.open(url)
                } else {
                    problem = "No email account is set up on this iPhone."
                }
                return
            }

            composing = Composition(
                to: email,
                subject: CoachShare.subject,
                html: CoachShare.htmlBody(link: link, summary: summary, weeks: weeks)
            )
        } catch {
            problem = error.localizedDescription
        }
    }
}

struct Composition: Identifiable {
    let id = UUID()
    let to: String
    let subject: String
    let html: String
}

/// MFMailComposeViewController rather than a mailto: URL, because mailto is
/// plain text by specification and the coach should get a button to tap, not a
/// wall of base64.
private struct MailComposer: UIViewControllerRepresentable {
    let composition: Composition
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([composition.to])
        controller.setSubject(composition.subject)
        controller.setMessageBody(composition.html, isHTML: true)
        return controller
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult,
                                   error: Error?) {
            onFinish()
        }
    }
}
