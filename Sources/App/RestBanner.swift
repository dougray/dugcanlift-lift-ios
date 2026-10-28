import SwiftUI
import LiftCore

/// The rest under Train while one is running: the time left, fifteen seconds
/// either way, and Skip. Once it is over it says so, and the phone taps.
struct RestBanner: View {
    private var timer = RestTimer.shared

    var body: some View {
        if let rest = timer.current {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content(rest, now: context.date)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .frame(maxWidth: AdaptiveLayout.readableWidth)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func content(_ rest: RestCountdown, now: Date) -> some View {
        let over = rest.isOver(at: now)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(over ? "Rest over" : "Rest")
                    .font(Theme.detail)
                    .foregroundStyle(Theme.textSecondary)
                if over {
                    Text(rest.exerciseName.map { "Back to \($0)" } ?? "Next set")
                        .scaledFont(size: 17, weight: .bold)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                } else {
                    Text(RestCountdown.clock(rest.remaining(at: now)))
                        .scaledFont(size: 28, weight: .bold)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                        .contentTransition(.numericText(countsDown: true))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)

            Spacer(minLength: 0)

            if !over {
                button("−15", label: "Fifteen seconds less") { timer.adjust(by: -RestTimer.step) }
                button("+15", label: "Fifteen seconds more") { timer.adjust(by: RestTimer.step) }
            }
            button(over ? "Done" : "Skip", label: over ? "Done" : "Skip rest") { timer.skip() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .liftCardBackground()
        .sensoryFeedback(.success, trigger: over) { _, isOver in isOver }
    }

    private func button(_ title: String, label: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .scaledFont(size: 15, weight: .semibold)
            .foregroundStyle(Theme.accentText)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel(label)
    }
}
