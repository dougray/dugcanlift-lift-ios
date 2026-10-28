import ActivityKit
import WidgetKit
import SwiftUI
import LiftCore

/// The rest between sets on the lock screen and in the Dynamic Island.
///
/// `Text(timerInterval:)` counts down on its own, so the app does not have to
/// be running to keep it right; past the end the content is stale (its
/// `staleDate` is the end of the rest) and says "Rest over" instead.
struct RestActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RestActivityAttributes.self) { context in
            RestLockScreenView(rest: context.state, isOver: context.isStale)
                .padding(16)
                .activitySystemActionForegroundColor(Theme.accent)
        } dynamicIsland: { context in
            let rest = context.state
            let over = context.isStale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Rest", systemImage: "timer")
                        .font(.headline)
                        .foregroundStyle(Theme.accentText)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RestClock(rest: rest, isOver: over)
                        .font(.title2.monospacedDigit().weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let name = rest.exerciseName {
                        Text(over ? "Back to \(name)" : "Next: \(name)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } compactLeading: {
                Image(systemName: "timer")
                    .foregroundStyle(Theme.accentText)
            } compactTrailing: {
                RestClock(rest: rest, isOver: over)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .frame(maxWidth: 44)
            } minimal: {
                Image(systemName: over ? "checkmark" : "timer")
                    .foregroundStyle(Theme.accentText)
            }
        }
    }
}

/// The time left, or "Done" once there is none.
private struct RestClock: View {
    let rest: RestCountdown
    let isOver: Bool

    var body: some View {
        if isOver {
            Text("Done")
        } else {
            Text(timerInterval: rest.startedAt...rest.endsAt, countsDown: true)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct RestLockScreenView: View {
    let rest: RestCountdown
    let isOver: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label(isOver ? "Rest over" : "Resting", systemImage: "timer")
                    .font(.headline)
                    .foregroundStyle(Theme.accentText)
                if let name = rest.exerciseName {
                    Text(isOver ? "Back to \(name)" : "Next: \(name)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if !isOver {
                RestClock(rest: rest, isOver: isOver)
                    .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                    .frame(maxWidth: 120, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
