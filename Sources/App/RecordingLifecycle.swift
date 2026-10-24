import Foundation
import Observation

/// When an outdoor recording starts and when it stops: once per presentation,
/// and only on an explicit end.
///
/// SwiftUI's `onAppear` / `onDisappear` say when a view is in the hierarchy,
/// not when the person opened or closed the screen. Switching the phone
/// between light and dark -- which a phone on Auto does at sunset -- sent the
/// recording screen a disappear and an appear in the same instant, with fresh
/// `@State`. The screen stopped tracking on the disappear and started a new
/// recording on the appear, and the run so far was gone. So a disappear stops
/// nothing, a second appear starts nothing, and the run ends on Cancel, on
/// Finish, or when the presentation itself is dismissed.
///
/// A value type with no view in it, for the reason `OutdoorRemoval` is one: a
/// rule in a view's `@State` cannot be tested, and this one decides whether
/// somebody's run survives. `RecordingLifecycleTests` pins it.
struct RecordingLifecycle: Equatable {
    enum Event {
        /// The recording screen appeared -- the first time, or again.
        case appear
        /// The recording screen left the hierarchy, perhaps only for a moment.
        case disappear
        /// The person discarded the run.
        case cancel
        /// The run was saved.
        case finish
        /// The presentation really went away (the cover's `onDismiss`).
        case dismissed
    }

    enum Action: Equatable { case start, stop, none }

    enum Phase: Equatable { case idle, recording, ended }

    private(set) var phase: Phase = .idle

    mutating func handle(_ event: Event) -> Action {
        switch (phase, event) {
        case (.idle, .appear):
            phase = .recording
            return .start
        case (.recording, .cancel), (.recording, .finish), (.recording, .dismissed):
            phase = .ended
            return .stop
        case (.idle, .cancel), (.idle, .finish), (.idle, .dismissed):
            // Gone before it began: nothing to stop, and nothing may start.
            phase = .ended
            return .none
        case (_, .disappear), (.recording, .appear), (.ended, _):
            return .none
        }
    }
}

/// One recording, owned by the screen that presents it rather than by the
/// recording screen itself.
///
/// The light/dark switch rebuilt the recording screen with fresh `@State`, so a
/// tracker held there was a new, empty tracker. Held here, by the presenter,
/// and handed to the cover as its item, the same recording -- its points, its
/// start time and where it is in its lifecycle -- is what any rebuilt
/// recording screen is given.
@MainActor
@Observable
final class OutdoorRecording: Identifiable {
    let id = UUID()
    let activityType: OutdoorActivityType
    let tracker = LocationTracker()
    private(set) var startedAt = Date.now
    private var lifecycle = RecordingLifecycle()

    init(activityType: OutdoorActivityType) {
        self.activityType = activityType
    }

    func handle(_ event: RecordingLifecycle.Event) {
        switch lifecycle.handle(event) {
        case .start:
            tracker.requestAuthorization()
            tracker.start()
            startedAt = .now
        case .stop:
            tracker.stop()
        case .none:
            break
        }
    }
}
