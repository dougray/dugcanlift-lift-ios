import Foundation

/// The one line a run shows for VO2 max: `VO2 max 46.2 · Nov 8`.
///
/// Tracked and shown, never targeted: no zone, color, threshold or advice, and
/// no placeholder when Health has no estimate (the caller shows nothing).
/// A value type with no Health framework in it, so it compiles into the widget
/// and is tested with plain dates.
enum VO2MaxText {

    /// `VO2 max 46.2 · Nov 8`, or nil for a value that is not a real estimate
    /// (zero, negative, not finite): blank is never a zero.
    ///
    /// One decimal, a trailing `.0` dropped (`46`, `46.2`), rounded half up on
    /// the digits the value is written with -- 46.25 is 46.3 -- not on its
    /// binary expansion. The date is the reader's own short month and day,
    /// in the locale and calendar handed in (`Locale.current`, `Calendar.current`
    /// in the app).
    static func line(value: Double, date: Date,
                     locale: Locale = .current, calendar: Calendar = .current) -> String? {
        guard value.isFinite, value > 0, let number = number(value) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return "VO2 max \(number) · \(formatter.string(from: date))"
    }

    /// "46", "46.2": `Double.description` is the shortest string that reads
    /// back as the same value, which is what a person would have written.
    static func number(_ value: Double) -> String? {
        guard var decimal = Decimal(string: "\(value)", locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &decimal, 1, .plain)
        let text = NSDecimalNumber(decimal: rounded).stringValue
        return text
    }
}
