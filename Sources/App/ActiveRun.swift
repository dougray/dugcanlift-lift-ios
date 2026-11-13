import Foundation
import LiftCore
import Observation
import SwiftData

/// The one run in progress, and whether its full screen is showing.
///
/// A run used to belong to the cover that presented it, so leaving the screen
/// ended the run. It belongs here instead, to the app: the screen is a view of
/// the run and can be closed and reopened, and the Train card shows the run
/// live while the screen is away. The run ends only on Cancel or Finish --
/// leaving the screen, switching tabs, a light/dark switch and backgrounding
/// stop nothing.
///
/// One run at a time: `start` refuses while one is recording.
@MainActor
@Observable
final class ActiveRun {
    enum FinishError: Error { case notRecording }

    private(set) var recording: OutdoorRecording?
    /// Whether the full recording screen is up. The run goes on either way.
    var isScreenShown = false
    /// The run just saved, for the review screen. Whichever view finished it
    /// -- the full screen or the card -- it is presented from one place, because
    /// the view that finished it is gone by the time the review shows.
    var justFinished: OutdoorActivity?

    init() {}

    /// Begins a run and shows its screen. False, and nothing changes, while
    /// one is already recording.
    @discardableResult
    func start(_ type: OutdoorActivityType) -> Bool {
        guard recording == nil else { return false }
        recording = OutdoorRecording(activityType: type)
        isScreenShown = true
        return true
    }

    /// Brings the full screen back.
    func open() {
        guard recording != nil else { return }
        isScreenShown = true
    }

    /// The person closed the screen. The run continues.
    func close() {
        recording?.handle(.left)
        isScreenShown = false
    }

    /// Throws the run away.
    func cancel() {
        recording?.handle(.cancel)
        end()
    }

    /// Saves the run and ends it. A failed save throws and keeps recording, so
    /// nothing walked after it is lost; the unsaved insert is backed out so a
    /// retry cannot save two copies. The screen and the card both come here.
    func finish(in context: ModelContext) throws -> OutdoorActivity {
        guard let recording else { throw FinishError.notRecording }
        let points = recording.tracker.points
        let activity = OutdoorActivity(activityType: recording.activityType, startedAt: recording.startedAt)
        activity.endedAt = .now
        activity.routePoints = points
        activity.distanceMeters = OutdoorActivityMath.totalDistanceMeters(points)
        activity.elevationGainMeters = OutdoorActivityMath.elevationGainMeters(points)
        context.insert(activity)
        do {
            try context.save()
        } catch {
            context.delete(activity)
            throw error
        }
        recording.handle(.finish)
        end()
        justFinished = activity
        return activity
    }

    private func end() {
        recording = nil
        isScreenShown = false
    }
}

// The words for those numbers live in the app target: `DistanceUnit` and
// `OutdoorRecords` are not in the widget, which also compiles Shared.
extension LiveRunStats {
    /// "00:12:07".
    var elapsedText: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    func distanceText(unit: DistanceUnit) -> String {
        OutdoorRecords.distanceText(distanceMeters, unit: unit)
    }

    /// "8:42 /mi", or "--" before there is a pace to show.
    func paceText(unit: DistanceUnit) -> String {
        paceSecondsPerMeter.map { OutdoorRecords.paceText($0, unit: unit) } ?? "--"
    }
}
