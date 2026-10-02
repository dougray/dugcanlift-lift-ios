import SwiftUI

/// The DUGCANLIFT palette, as the Wear OS app's `DclColors` already carries it
/// and `LiftCore.Theme` carries it on the phone.
///
/// This app had none. Every screen used system colours -- `.secondary`,
/// `.red`, `.orange`, black and white -- so a LIFT watch face looked like a
/// stock watchOS app rather than like LIFT, while the Wear OS build beside it
/// was themed. Adding it here is the same correction made to `LiftCore.Theme`
/// for the phone apps.
///
/// Values are the browser build's, from `dugcanlift-site/lift/style.css`. That
/// stylesheet is the definition; if it moves, these follow.
enum DclTheme {
    static let background = Color(red: 0x1C / 255, green: 0x1B / 255, blue: 0x19 / 255)
    static let surface    = Color(red: 0x24 / 255, green: 0x22 / 255, blue: 0x20 / 255)
    static let text       = Color(red: 0xED / 255, green: 0xE7 / 255, blue: 0xDD / 255)
    static let muted      = Color(red: 0xA3 / 255, green: 0x9C / 255, blue: 0x8E / 255)
    static let accent     = Color(red: 0xC1 / 255, green: 0x44 / 255, blue: 0x2C / 255)
    static let accent2    = Color(red: 0x7C / 255, green: 0x8B / 255, blue: 0x7A / 255)
    static let rule       = Color(red: 0x3A / 255, green: 0x37 / 255, blue: 0x33 / 255)
    static let onAccent   = Color(red: 0xF7 / 255, green: 0xF1 / 255, blue: 0xE8 / 255)
}

extension View {
    /// The app's ground: accent tint and the palette's background, applied once
    /// at the root so every screen inherits it rather than each remembering to.
    func liftWatchTheme() -> some View {
        self
            .tint(DclTheme.accent)
            .foregroundStyle(DclTheme.text)
            .background(DclTheme.background)
    }
}
