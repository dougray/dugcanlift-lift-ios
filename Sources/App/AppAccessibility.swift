import SwiftUI
import UIKit
import LiftCore

// App-local accessibility helpers the kit does not provide.
//
// Kit 1.12.0 supplies the text-safe rust (`Theme.accentText`), Dynamic Type
// type tokens, and the selected/header traits on its own components; use
// those. What stays here is app-only: a Dynamic Type font for sizes that are
// not a kit token, the text-safe screen tint, the keyboard Done button, the
// delete glyph and the undo toast.

// MARK: - Dynamic Type

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

    /// The kit's `liftScreen()`, tinted with `Theme.accentText` rather than
    /// the kit's `Theme.accent`. Every plain `Button` and toolbar item takes
    /// its text colour from the tint, so this is where most small rust text
    /// comes from. The inner tint wins over the kit's.
    func appScreen() -> some View {
        self
            .tint(Theme.accentText)
            .liftScreen()
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
                .foregroundStyle(Theme.accentText)
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
                .font(Theme.body)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("Undo") { center.performUndo() }
                .font(Theme.body.weight(.bold))
                .foregroundStyle(Theme.accentText)
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
