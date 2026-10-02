import Foundation
import LiftCore

/// Which of this phone's planned meals a coach booked, and who booked them.
///
/// A coach's plan can book meals as well as sessions (PLAN-FORMAT's `m`), and
/// `PlanImporter` files them as ordinary `PlannedMeal` rows beside the ones the
/// lifter places in Cook. The week card shows **only the coach's**: a dinner you
/// planned yourself is yours to move, and holding it up on a card headed "your
/// coach's plan" would make an expectation out of your own note-taking. So the
/// two have to be told apart, and `PlannedMeal` has nothing on it that does.
///
/// **Where it is kept.** Not a property on `PlannedMeal`: that is LiftKit's
/// shared `@Model`, so a column there is a schema change for this app *and* for
/// Coach iOS, and it would mean freezing the recipe models in every version
/// since V2. It is a preference-sized side-car in `UserDefaults`, exactly as
/// `PlanSides` is and for the same reason — written when a plan is accepted,
/// keyed by the row's own id, and read by the card and by nothing else.
///
/// LIFT web keeps the same fact on the plan row itself as `fromCoach`, which is
/// `payload.n` or `true`; LIFT for Android keeps it as two fields on its own
/// `PlannedMeal` data class. The three spellings meet in the backup file, where
/// it is web's `fromCoach` — a name, or `true` for a coach who named nobody.
///
/// **The cost, stated:** nothing sweeps this when a planned meal is deleted, so
/// a removed meal can leave an id behind. That is `PlanSides`' own cost, it is
/// bounded by the number of meals a coach has ever booked, and an id matching no
/// row is read by nothing — the card asks the question the other way round, of
/// the meals it already holds.
struct PlanMeals: Codable, Equatable {

    static let storageKey = "coachPlanMeals"

    /// `PlannedMeal.id` of every meal a coach's plan booked.
    var fromCoach: Set<UUID> = []

    /// `PlannedMeal.id` -> the coach who booked it, for the meals whose plan
    /// carried an `n`. Absent means a coach who named nobody — never a meal of
    /// your own, which is absent from `fromCoach` instead.
    var coachNames: [UUID: String] = [:]

    // MARK: Storage

    static func load(from defaults: UserDefaults = .standard) -> PlanMeals {
        guard let data = defaults.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(PlanMeals.self, from: data)
        else { return PlanMeals() }
        return value
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    // MARK: Reading and writing one meal

    func isFromCoach(_ meal: PlannedMeal) -> Bool { fromCoach.contains(meal.id) }

    func coachName(of meal: PlannedMeal) -> String? { coachNames[meal.id] }

    /// Records that a coach booked this meal. `coach` is the plan's `n`, already
    /// trimmed; nil is a plan that named nobody, which is still a coach's meal.
    mutating func book(_ id: UUID, coach: String?) {
        fromCoach.insert(id)
        if let coach, !coach.isEmpty { coachNames[id] = coach } else { coachNames[id] = nil }
    }
}
