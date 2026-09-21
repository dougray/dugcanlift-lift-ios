import Foundation
import LiftCore

/// How the shopping list prints an amount: at most two decimals, trailing
/// zeros dropped, a whole number bare -- "416.67 g", "1.67", "3", "2.5".
///
/// LIFT web's `trimNum` and LIFT Android's `cookDisplay` print exactly this.
/// Scaling a recipe by planned servings rarely divides evenly (one serving of
/// a three-serving recipe with five eggs is 1.6666666666666665 of them), and
/// `CookFormat.trimmed`'s `%g` shows six significant figures of it.
///
/// **Display only, and only the shopping list.** `CookFormat.trimmed` is not
/// changed and must not be: it writes numbers back into text that
/// `IngredientParser` reads again, where rounding would alter a recipe. This
/// never writes anything -- the amount it is given is not rounded, so adding
/// lines together stays exact. Nothing but `ShoppingListView.row` calls it.
enum ShoppingAmountFormat {

    /// Rounded half away from zero on the value's shortest decimal form, as
    /// Android's `BigDecimal.valueOf(...).setScale(2, HALF_UP)` does -- so
    /// 1.005 is "1.01", where rounding the binary value would give "1".
    /// Always a `.` decimal and no grouping, like the other two builds.
    static func amount(_ value: Double) -> String {
        guard value.isFinite else { return String(value) }
        var exact = Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX"))
            ?? Decimal(value)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &exact, 2, .plain)
        if rounded.isZero { return "0" }
        return NSDecimalNumber(decimal: rounded).stringValue
    }

    /// `CookFormat.amountsLabel`'s layout with this rounding: units sorted,
    /// joined with " + ", and a count printed bare -- "2", not "2 x banana".
    static func label(_ amounts: [String: Double]) -> String {
        amounts
            .sorted { $0.key < $1.key }
            .map { unit, value in
                unit == IngredientParser.countUnit
                    ? amount(value)
                    : "\(amount(value)) \(unit)"
            }
            .joined(separator: " + ")
    }
}
