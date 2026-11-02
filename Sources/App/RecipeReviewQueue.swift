import Foundation

/// A recipe Safari handed over, waiting for the lifter to review it.
struct QueuedRecipe: Identifiable, Equatable {
    let id = UUID()
    let item: PendingRecipeImports.Item
}

/// When a recipe Safari handed over may open, as a value type with no view in
/// it: the rule MacroFields follows, because a rule in a view's `@State`
/// cannot be tested and this one decides whether a recipe is lost. A recipe's
/// file in the App Group is deleted only when its review is finished
/// (`takeFinished`), so LIFT reads the file again on every activation and
/// this queue is what keeps a recipe from opening twice.
///
/// SwiftUI shows one presentation at a time on a view and silently drops a
/// second one, so a recipe must never be offered while LiftApp's plan sheet or
/// refusal alert, or a sheet the app root cannot see, is up. Three things follow:
///
/// - `next(canPresent:)` offers nothing unless the caller says it is clear.
/// - A sheet that was offered but never appeared (`markAppeared` never came)
///   was dropped; `activated()` puts it back at the front for another try.
/// - A report arriving while a recipe is under review would be dropped the
///   same way, so it is held and shown when the review ends, before the next
///   recipe.
///
/// `Report` is whatever the caller shows -- LIFT holds a plan intake outcome (a
/// plan sheet or a refusal alert); it is only held.
struct RecipeReviewQueue<Report> {

    private(set) var waiting: [QueuedRecipe] = []
    private(set) var reviewing: QueuedRecipe?
    private(set) var reviewingAppeared = false
    private(set) var heldReports: [Report] = []
    /// Reviews that ended in Save or Cancel, whose files are now to be deleted.
    private(set) var finished: [PendingRecipeImports.Item] = []
    /// A review's sheet is animating away. Nothing opens until `closed()`:
    /// a review opened now would be ended by the old sheet's `onDismiss`.
    private(set) var closing = false

    /// Adds what the share extension queued, skipping a recipe already waiting,
    /// under review, or finished and not yet deleted: the same page shared
    /// twice is one review, and a file read again is not a new one.
    mutating func enqueue(_ items: [PendingRecipeImports.Item]) {
        for item in items where reviewing?.item != item
            && !waiting.contains(where: { $0.item == item }) && !finished.contains(item) {
            waiting.append(QueuedRecipe(item: item))
        }
    }

    /// Starts the next review, only when nothing is under review and the
    /// caller has nothing else on screen.
    mutating func next(canPresent: Bool) -> QueuedRecipe? {
        guard canPresent, !closing, reviewing == nil, !waiting.isEmpty else { return nil }
        let queued = waiting.removeFirst()
        reviewing = queued
        reviewingAppeared = false
        return queued
    }

    /// The review sheet's content came on screen. With an `id`, only if it is
    /// the review under way: an old sheet's late `onAppear` is not the retry
    /// appearing.
    mutating func markAppeared(_ id: UUID? = nil) {
        guard let current = reviewing, id == nil || id == current.id else { return }
        reviewingAppeared = true
    }

    /// The app became active. A review that never appeared was dropped by
    /// SwiftUI and will never report its own dismissal: retry it first, as a
    /// new `QueuedRecipe` so the sheet's item changes identity.
    mutating func activated() {
        dropped()
    }

    /// The review under way never came on screen, so SwiftUI dropped it:
    /// it goes back to the front, as a new `QueuedRecipe`. Nothing if it
    /// appeared.
    mutating func dropped() {
        guard let stuck = reviewing, !reviewingAppeared else { return }
        waiting.insert(QueuedRecipe(item: stuck.item), at: 0)
        reviewing = nil
    }

    /// The review sheet closed. Idempotent: the first call ends the review and
    /// returns true, and any later one finds nothing under review and returns
    /// false. The sheet's binding setter and its `onDismiss` may both call it;
    /// the caller advances only from `onDismiss`, so a close is one advance.
    /// The sheet cannot be swiped away, so a close is Save or Cancel: the
    /// recipe is finished.
    @discardableResult
    mutating func dismissed() -> Bool {
        guard let ended = reviewing else { return false }
        finished.append(ended.item)
        closing = true
        reviewing = nil
        reviewingAppeared = false
        return true
    }

    /// The closing sheet has gone (its `onDismiss`): the next may open.
    mutating func closed() {
        closing = false
    }

    /// The recipes whose reviews finished since the last call, for the caller
    /// to delete from the App Group.
    mutating func takeFinished() -> [PendingRecipeImports.Item] {
        defer { finished = [] }
        return finished
    }

    /// A plan outcome is ready: returned to be shown now, or held (nil) while a
    /// recipe is under review or earlier outcomes are still waiting to be
    /// shown. Every outcome held during a review is kept, in arrival order: a
    /// refusal must never be replaced by a later plan.
    mutating func report(_ report: Report) -> Report? {
        guard reviewing != nil || !heldReports.isEmpty else { return report }
        heldReports.append(report)
        return nil
    }

    /// The oldest held report, to be shown next -- before the next recipe.
    mutating func takeHeldReport() -> Report? {
        heldReports.isEmpty ? nil : heldReports.removeFirst()
    }
}
