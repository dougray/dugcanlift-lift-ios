import Foundation

/// Convenience type over `FoodLogPayload.meal`'s plain wire string — the
/// schema doesn't constrain `meal` to an enum, but a `CaseIterable` type
/// gives `FoodAmountEntryView`'s picker something real to bind to.
public enum FoodLogMeal: String, Codable, CaseIterable, Sendable {
    case breakfast = "BREAKFAST"
    case lunch = "LUNCH"
    case dinner = "DINNER"
    case snack = "SNACK"

    public var displayName: String { rawValue.capitalized }

    /// Best-effort default so the picker doesn't open on an arbitrary case —
    /// the user can always override before confirming. Boundaries are an
    /// approximation, not a contract; nothing on the wire depends on them.
    public static func forHour(_ hour: Int) -> FoodLogMeal {
        switch hour {
        case 5..<11: return .breakfast
        case 11..<16: return .lunch
        case 16..<22: return .dinner
        default: return .snack
        }
    }
}
