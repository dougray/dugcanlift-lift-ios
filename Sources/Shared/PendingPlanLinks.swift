import Foundation

/// The share extension's hand-off to the app: plan fragments the lifter
/// confirmed in the share sheet, waiting in the App Group's `UserDefaults`
/// suite until LIFT next comes to the foreground and opens them.
///
/// Why a queue and not a URL the extension opens: iOS gives a share extension
/// no supported way to open its containing app (`NSExtensionContext.open` is
/// for Today widgets only), and the responder-chain walk to `UIApplication`
/// that some apps use is undocumented. Why not import straight into SwiftData
/// from the extension: accepting a plan is the lifter's decision, taken on
/// `PlanPreviewView` in the app, and a share sheet is not where a routine
/// should silently appear in someone's library.
///
/// Only fragments cross -- never decoded data -- so the app opens them through
/// the exact code path Paste a Plan Link uses. Compiled into both targets;
/// Foundation only.
///
/// This is a port of Coach iOS's `PendingShareLinks`, in the other direction:
/// there a coach queues a client's log, here a lifter queues a coach's plan.
struct PendingPlanLinks {

    /// The app's existing group -- the same one the SwiftData store and the
    /// widget already use, so this costs no new entitlement. App Groups sign
    /// on a free Personal Team; Associated Domains, which is what Universal
    /// Links would need, does not. That is the whole reason this file exists.
    static let appGroup = "group.com.dugcanlift.lift"
    static let key = "pendingPlanLinkFragments"
    /// The lifter's own id, mirrored out of `UserDefaults.standard` by the app
    /// at launch. An extension has its own defaults, so without the mirror the
    /// share sheet could not tell a plan addressed to this phone from one
    /// addressed to somebody else -- and `PlanLinkCodec.decode` needs the id
    /// before it will hand back a payload at all.
    static let lifterIDKey = "coachLifterID"
    /// A lifter sharing more than this many plans without opening LIFT once
    /// loses the oldest -- a bound so a stuck queue cannot grow forever.
    static let limit = 20

    let defaults: UserDefaults

    /// Nil when the App Group entitlement is missing from the running build.
    /// `UserDefaults(suiteName:)` alone would succeed regardless and write to
    /// a private suite the other process never sees, so the container check
    /// is what proves the two processes really share storage.
    static var shared: PendingPlanLinks? {
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) != nil,
              let defaults = UserDefaults(suiteName: appGroup)
        else { return nil }
        return PendingPlanLinks(defaults: defaults)
    }

    /// Queues a fragment. The same link shared twice is queued once.
    func add(_ fragment: String) {
        var queue = pending.filter { $0 != fragment }
        queue.append(fragment)
        defaults.set(Array(queue.suffix(Self.limit)), forKey: Self.key)
    }

    /// Everything queued, oldest first, and empties the queue.
    func takeAll() -> [String] {
        let queue = pending
        if !queue.isEmpty { defaults.removeObject(forKey: Self.key) }
        return queue
    }

    var pending: [String] {
        defaults.stringArray(forKey: Self.key) ?? []
    }

    /// What the extension decodes against. Nil before LIFT has been opened
    /// once on this phone, which the extension says in words rather than
    /// guessing an id or queueing a plan it could not read.
    var lifterID: String? {
        let id = defaults.string(forKey: Self.lifterIDKey)
        return (id?.isEmpty ?? true) ? nil : id
    }

    /// Called by the app at launch. Writes only when it would change
    /// something: the id is generated once and never regenerated, so this is
    /// a no-op on every launch after the first.
    func mirror(lifterID id: String) {
        guard !id.isEmpty, lifterID != id else { return }
        defaults.set(id, forKey: Self.lifterIDKey)
    }
}
