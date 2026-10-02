import Foundation

/// A coach's road picks, as this phone holds them: the Road Food item ids
/// that arrived in a plan link, and the name to put on them.
///
/// **Where they are kept.** A side-car in `UserDefaults`, the way `PlanSides`
/// and `perSideExercises` are, rather than a `@Model`: it is one short list of
/// strings, replaced whole, with nothing to query and nothing to relate it to.
/// A schema change here is a schema change for Coach iOS too, and this does
/// not need one.
///
/// **Not in the backup**, for the same reason the recently used chains are
/// not: it is not a record of anything this phone did. The coach still holds
/// the picks and can send them again, and LIFT web keeps them out of its
/// backup identically.
///
/// **Replaced whole by the next plan that carries any; a plan with no `rf`
/// changes nothing** (PLAN-FORMAT.md "Road picks"). A link without the key is
/// silence about picks rather than a retraction, because that is also what
/// every older Coach and every "here is a recipe" send looks like. Clearing
/// them is this phone's own action, on the Road Food screen.
///
/// **An id this build's `road-food.json` does not have is skipped where the
/// list is drawn**, silently, and is never thrown away on arrival: an item
/// withdrawn since the plan was sent is not a broken row, and it comes back
/// if a later release has the item again.
struct RoadPicks: Codable, Equatable {

    static let storageKey = "roadPicks"

    /// The ids as sent, in the coach's own order.
    var ids: [String] = []
    /// The coach's name from the plan's `n`, or empty when it was not given.
    var from: String = ""
    /// When this phone took them in. Shown nowhere yet; kept because web's
    /// stored shape has it and one file should read as the other.
    var at: Date = .now

    // MARK: Storage

    static func load(from defaults: UserDefaults = .standard) -> RoadPicks? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return decode(data)
    }

    /// The same, from the bytes `@AppStorage("roadPicks")` hands a view, so a
    /// clear or a fresh plan redraws the screen. Empty, junk, or a list with
    /// nothing in it is no picks.
    static func decode(_ data: Data) -> RoadPicks? {
        guard let value = try? JSONDecoder().decode(RoadPicks.self, from: data),
              !value.ids.isEmpty else { return nil }
        return value
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// What "Clear these picks" does. Nothing else clears them: a plan that
    /// carries none says nothing about picks.
    static func clear(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }

    /// What arrived in a plan, stored whole. Returns how many ids that was, or
    /// zero when the plan said nothing about picks -- in which case whatever
    /// is stored is left exactly as it is.
    @discardableResult
    static func accept(ids: [String], from coachName: String,
                       in defaults: UserDefaults = .standard, at now: Date = .now) -> Int {
        let list = RoadPickLink.normalise(ids)
        guard !list.isEmpty else { return 0 }
        RoadPicks(ids: list, from: coachName.trimmingCharacters(in: .whitespacesAndNewlines),
                  at: now).save(to: defaults)
        return list.count
    }

    // MARK: What the screen says

    /// "Doug’s picks" when the coach named themselves, "Your coach’s picks"
    /// otherwise. One place, so a label and a heading cannot drift apart --
    /// LIFT web's `roadPicksLabel`, word for word, curly apostrophe included.
    func label(_ suffix: String) -> String {
        from.isEmpty ? "Your coach’s \(suffix)" : "\(from)’s \(suffix)"
    }

    /// The same sentence with no picks stored, for a caller that has none.
    static func label(_ suffix: String, from picks: RoadPicks?) -> String {
        picks?.label(suffix) ?? "Your coach’s \(suffix)"
    }
}
