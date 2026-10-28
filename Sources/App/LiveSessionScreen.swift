import SwiftUI
import SwiftData
import UIKit

/// The screen stays on during a live session, so a phone propped on a bench
/// does not lock between sets. On by default; Settings turns it off.
///
/// A value type with no view in it, so the rule can be tested: a session
/// somebody forgot to end must not keep a phone awake on the nightstand. Past
/// eight hours -- as long as iOS keeps a Live Activity -- a session no longer
/// holds the screen, whether or not it was ever ended. The day a session
/// started on does not matter, so one that runs past midnight keeps holding.
enum LiveSessionScreen {
    static let enabledKey = "keepScreenOnDuringLiveSession"
    static let defaultEnabled = true
    static let longestHold: TimeInterval = 8 * 3600

    /// `liveSince` is the start of every session not yet ended.
    static func holdsScreenOn(liveSince: [Date], enabled: Bool, now: Date) -> Bool {
        guard enabled else { return false }
        return liveSince.contains { start in
            let elapsed = now.timeIntervalSince(start)
            return elapsed >= 0 && elapsed < longestHold
        }
    }

    /// Never set means on: the Settings toggle's `@AppStorage` default only
    /// reaches disk once someone moves it.
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) == nil ? defaultEnabled : defaults.bool(forKey: enabledKey)
    }
}

/// Applies `LiveSessionScreen` to the app's idle timer. Attached once, at the
/// root, so it holds whichever tab is showing: someone checking Food between
/// sets is still training.
private struct KeepsScreenOnDuringLiveSession: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(LiveSessionScreen.enabledKey) private var enabled = LiveSessionScreen.defaultEnabled

    @Query(filter: #Predicate<WorkoutDay> { $0.liveStartedAt != nil && $0.liveEndedAt == nil })
    private var liveDays: [WorkoutDay]

    private var starts: [Date] { liveDays.compactMap(\.liveStartedAt) }

    func body(content: Content) -> some View {
        content
            .onChange(of: starts, initial: true) { apply() }
            .onChange(of: enabled) { apply() }
            // The eight-hour limit is checked again whenever the app comes
            // back, which is when a forgotten session would matter.
            .onChange(of: scenePhase) { apply() }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func apply() {
        UIApplication.shared.isIdleTimerDisabled = LiveSessionScreen.holdsScreenOn(
            liveSince: starts, enabled: enabled, now: .now)
    }
}

extension View {
    func keepsScreenOnDuringLiveSession() -> some View {
        modifier(KeepsScreenOnDuringLiveSession())
    }
}
