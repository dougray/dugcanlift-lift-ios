import LiftKit
import SwiftUI
import WatchKit

struct RestTimerView: View {
    @EnvironmentObject private var session: WorkoutSessionModel
    @State private var now = Date()
    @State private var didAlert = false

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 8) {
            Text("REST")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(RestTimer.format(session.restTimer.remaining(at: now) ?? session.restTimer.interval))
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()

            ProgressView(value: session.restTimer.progress(at: now))
                .tint(.orange)

            if session.restTimer.isRunning {
                Button("Skip") { session.restTimer.stop() }
                    .buttonStyle(.bordered)
            } else {
                Button("Start Rest") { session.restTimer.start() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal)
        .onReceive(tick) { date in
            now = date
            alertIfFinished()
        }
    }

    /// The point of a watch rest timer is not having to look at it.
    private func alertIfFinished() {
        guard session.restTimer.isRunning else { return }
        if session.restTimer.hasFinished(at: now) {
            if !didAlert {
                WKInterfaceDevice.current().play(.notification)
                didAlert = true
            }
        } else {
            didAlert = false
        }
    }
}
