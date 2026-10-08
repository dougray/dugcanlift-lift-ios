import LiftKit
import SwiftUI

struct RestTimerView: View {
    @EnvironmentObject private var session: WorkoutSessionModel
    @State private var now = Date()

    /// 44pt at the default size, growing with the wearer's text size.
    @ScaledMetric(relativeTo: .largeTitle) private var countdownSize: CGFloat = 44

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 8) {
            Text("REST")
                .font(.caption2)
                .foregroundStyle(DclTheme.muted)
                .accessibilityHidden(true)

            Text(RestTimer.format(session.restTimer.remaining(at: now) ?? session.restTimer.interval))
                .font(.system(size: countdownSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .accessibilityLabel("Rest remaining")
                .accessibilityValue(RestTimer.format(session.restTimer.remaining(at: now) ?? session.restTimer.interval))

            ProgressView(value: session.restTimer.progress(at: now))
                .tint(DclTheme.accent)
                .accessibilityHidden(true)

            if session.restTimer.isRunning {
                Button("Skip") { session.restTimer.stop() }
                    .buttonStyle(.bordered)
            } else {
                Button("Start Rest") { session.restTimer.start() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal)
        // Display only. The end-of-rest haptic lives in WorkoutSessionModel,
        // so it fires whichever page is showing.
        .onReceive(tick) { now = $0 }
    }
}
