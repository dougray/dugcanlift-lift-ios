import SwiftUI
import UIKit
import LiftCore

// App-local accessibility shims over kit 1.10.0.
//
// The kit pinned in project.yml has fixed-size type tokens, and its rust fails
// AA as small text in dark mode. Both belong in the kit, and a kit bump is a
// deliberate, schema-affecting edit (see CLAUDE.md), so until it happens the
// fixes live here. When the kit gains a text-safe accent and Dynamic-Type
// tokens, delete this file's colour and font helpers and switch call sites back.

// MARK: - Colour

enum AppColor {
    /// Rust that passes WCAG AA as small text on both grounds, in both
    /// appearances. Dark: #E0684F is 5.13:1 on `Theme.background` (#1C1B19)
    /// and 4.73:1 on `Theme.surface` (#242220), where `Theme.accent`
    /// (#C1442C) is only 3.39 / 3.12:1. Light: the kit's own light rust
    /// (#B23C25, 5.14 / 5.75:1) already passes, so it is reused unchanged.
    ///
    /// Use this for accent-coloured *text and glyphs*. Keep `Theme.accent`
    /// for fills, rules, progress bars and display-size text.
    static let accentText = Color(light: 0xB23C25, dark: 0xE0684F)
}

// MARK: - Dynamic Type

/// The kit's type tokens, re-expressed so they follow the reader's text size.
/// Same base sizes and weights as kit 1.10.0 `Theme`, so the default-size look
/// is unchanged.
enum LiftTextStyle {
    case cardTitle, figure, body, detail, sectionLabel

    var size: CGFloat {
        switch self {
        case .cardTitle: 17
        case .figure: 26
        case .body: 16
        case .detail: 14
        case .sectionLabel: 15
        }
    }

    var weight: Font.Weight {
        switch self {
        case .cardTitle, .figure, .sectionLabel: .bold
        case .body, .detail: .regular
        }
    }
}

/// Scales a fixed base size with Dynamic Type, relative to the system text
/// style nearest that size, so 16pt grows the way Callout does.
private struct ScaledSystemFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: Self.textStyle(near: size))
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }

    static func textStyle(near size: CGFloat) -> Font.TextStyle {
        switch size {
        case ..<12.5: .caption
        case ..<13.5: .footnote
        case ..<15.5: .subheadline
        case ..<16.5: .callout
        case ..<17.5: .body
        case ..<21: .title3
        case ..<24: .title2
        case ..<30: .title
        default: .largeTitle
        }
    }
}

extension View {
    /// `.font(.system(size:weight:))`, but scaled with Dynamic Type.
    func scaledFont(size: CGFloat, weight: Font.Weight = .regular,
                    design: Font.Design = .default) -> some View {
        modifier(ScaledSystemFont(size: size, weight: weight, design: design))
    }

    /// A kit type token (`Theme.body` etc.) that follows Dynamic Type.
    func liftFont(_ style: LiftTextStyle, weight: Font.Weight? = nil) -> some View {
        scaledFont(size: style.size, weight: weight ?? style.weight)
    }

    /// The kit's `liftScreen()`, with a text-safe tint. Every plain `Button`
    /// and toolbar item takes its text colour from the tint, so this is where
    /// most small rust text comes from. The inner tint wins over the kit's.
    func appScreen() -> some View {
        self
            .tint(AppColor.accentText)
            .liftScreen()
    }

    /// `.isSelected` for a hand-built selectable control, so VoiceOver says
    /// "selected" for the active tab or chip.
    func accessibilitySelected(_ isSelected: Bool) -> some View {
        accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Number and decimal pads have no return key. One Done button above the
    /// keyboard, plus drag-to-dismiss on the scroll view. Apply once per
    /// presentation (inside its NavigationStack): declaring keyboard toolbar
    /// items at two levels of one hierarchy shows the button twice.
    func keyboardDoneButton() -> some View {
        self
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { dismissKeyboard() }
                        .fontWeight(.semibold)
                }
            }
    }
}

@MainActor
func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                    to: nil, from: nil, for: nil)
}

// MARK: - Delete control

/// The trailing delete glyph on a food entry, set or planned meal: an SF
/// Symbol with a 44pt hit area and a spoken name, replacing a bare Text("x")
/// whose hit area was the glyph itself.
struct DeleteGlyphButton: View {
    let accessibilityName: String
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var glyph: CGFloat = 14

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: glyph, weight: .bold))
                .foregroundStyle(AppColor.accentText)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Delete \(accessibilityName)")
    }
}

// MARK: - Undo toast

/// A transient "Deleted X · Undo" bar, shown by RootView above everything.
///
/// The delete has already happened when this shows; Undo re-creates the
/// object from a snapshot the caller captured. That is more robust with
/// SwiftData than deferring the delete: nothing has to hide a row that
/// `@Query` still returns, and an app kill mid-toast leaves the store in the
/// state the user saw.
@MainActor
@Observable
final class UndoToastCenter {
    static let shared = UndoToastCenter()

    struct Toast: Identifiable {
        let id = UUID()
        let message: String
        let undo: () -> Void
    }

    private(set) var current: Toast?
    private var expiry: Task<Void, Never>?

    func show(_ message: String, undo: @escaping () -> Void) {
        let toast = Toast(message: message, undo: undo)
        current = toast
        UIAccessibility.post(notification: .announcement,
                             argument: "\(message). Undo available.")
        expiry?.cancel()
        // Longer under VoiceOver: reaching the button takes several swipes.
        let seconds: Double = UIAccessibility.isVoiceOverRunning ? 12 : 5
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            if self?.current?.id == toast.id { self?.current = nil }
        }
    }

    func performUndo() {
        guard let toast = current else { return }
        expiry?.cancel()
        current = nil
        toast.undo()
    }

    func dismiss() {
        expiry?.cancel()
        current = nil
    }
}

struct UndoToastBar: View {
    let toast: UndoToastCenter.Toast
    let center: UndoToastCenter

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.message)
                .liftFont(.body)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("Undo") { center.performUndo() }
                .liftFont(.body, weight: .bold)
                .foregroundStyle(AppColor.accentText)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .stroke(Theme.textSecondary.opacity(0.5), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Kit components, text-safe

// Kit 1.10.0's LiftCard, MacroProgressRow and StatRow draw their text with
// the fixed-size tokens, and LiftCard's title and MacroProgressRow's value in
// `Theme.accent`, which fails AA in dark. These are the same layouts with the
// app's scaled fonts and text-safe rust. Delete them and switch back once the
// kit's own components do this.

/// `LiftCard`, with a title that scales and passes contrast, and is a
/// VoiceOver heading.
struct AppCard<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .liftFont(.cardTitle)
                    .foregroundStyle(AppColor.accentText)
                    .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.cardPadding)
        .liftCardBackground()
    }
}

/// `MacroProgressRow`: label left, value right, a progress rule beneath.
struct AppMacroProgressRow: View {
    let label: String
    let current: Double
    let goal: Double
    let unit: String

    private var fraction: Double {
        guard goal > 0 else { return 0 }
        return min(current / goal, 1)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(label)
                    .liftFont(.body)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(Int(current)) / \(Int(goal)) \(unit)")
                    .liftFont(.body)
                    .foregroundStyle(AppColor.accentText)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hairline.opacity(0.5))
                    Capsule().fill(Theme.accent).frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 3)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// `StatRow`: plain label and value.
struct AppStatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).liftFont(.body).foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(value).liftFont(.body).foregroundStyle(Theme.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }
}
