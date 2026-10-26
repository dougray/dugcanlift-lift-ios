import Foundation

/// What the share extension's recipe queue answers. `PendingRecipeImports`
/// is the real one; the seam exists so `RecipeIntake` holds no file paths.
protocol RecipeInbox {
    func forReview(givingUp: Bool) -> [PendingRecipeImports.Item]
    func markOpened(_ item: PendingRecipeImports.Item)
    func unmarkOpened(_ item: PendingRecipeImports.Item)
    func remove(_ item: PendingRecipeImports.Item)
}

extension PendingRecipeImports: RecipeInbox {}

/// What the app root does with recipes Safari handed over: `RecipeReviewQueue`
/// decides when each may open, and this keeps the App Group's files in step
/// with it. Both are value types with no view in them, because together they
/// decide whether a recipe is lost, and a rule wired in a view cannot be
/// tested -- `RecipeIntakeTests` drives this against real files.
///
/// - Every activation reads the files; the first in a process is a launch,
///   and only a launch gives up a recipe that has been opened
///   `PendingRecipeImports.mostOpens` times without finishing.
/// - Opening a review counts a try in the recipe's file. A sheet SwiftUI
///   dropped, found on the next activation, gives its try back: it never ran,
///   so it cannot have ended the app.
/// - Save or Cancel deletes the file as the sheet starts to close
///   (`closing`), and nothing opens until it has gone (`closed`).
struct RecipeIntake<Report> {
    private(set) var queue = RecipeReviewQueue<Report>()
    private let inbox: (any RecipeInbox)?
    private var launched = false

    init(inbox: (any RecipeInbox)?) {
        self.inbox = inbox
    }

    var reviewing: QueuedRecipe? { queue.reviewing }
    var waiting: [QueuedRecipe] { queue.waiting }

    /// The app became active.
    mutating func activated() {
        if let dropped = queue.reviewing, !queue.reviewingAppeared {
            inbox?.unmarkOpened(dropped.item)
        }
        queue.activated()
        if let inbox {
            queue.enqueue(inbox.forReview(givingUp: !launched))
        }
        launched = true
    }

    /// Opens the next review when the caller has nothing else on screen.
    mutating func next(canPresent: Bool) -> QueuedRecipe? {
        guard let opened = queue.next(canPresent: canPresent) else { return nil }
        inbox?.markOpened(opened.item)
        return opened
    }

    /// The review's content came on screen.
    mutating func appeared() {
        queue.markAppeared()
    }

    /// The sheet's binding was cleared: Save or Cancel. The file goes now.
    mutating func closing() {
        guard queue.dismissed() else { return }
        for item in queue.takeFinished() { inbox?.remove(item) }
    }

    /// The sheet's `onDismiss`: it has gone, and the next may open.
    mutating func closed() {
        closing()
        queue.closed()
    }

    mutating func report(_ report: Report) -> Report? { queue.report(report) }
    mutating func takeHeldReport() -> Report? { queue.takeHeldReport() }
}
