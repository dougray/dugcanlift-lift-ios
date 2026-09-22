import SwiftUI
import UIKit

/// Keeps a pushed screen's light or dark in step with its window.
///
/// A view pushed inside Train's `NavigationStack` — itself a page of the
/// root's page-style `TabView` — keeps the colour scheme it was pushed with.
/// Switch the phone to dark with the exercise progression screen open, or
/// open one afterwards, and it went on drawing light until LIFT relaunched,
/// because its `\.colorScheme` never changed (measured: the environment read
/// `light` on a dark window). Train's own page updated; only the pushed
/// screen was stale, and forcing `\.colorScheme` onto the stack from outside
/// did not reach it.
///
/// The window is always right — `AppAppearance`'s override is applied to it
/// — so this reads the window's interface style and hands it to the screen
/// directly: as `\.colorScheme`, for `Theme`'s colours, and as the screen's
/// own controller's `overrideUserInterfaceStyle`, for the system colours a
/// chart's axis labels are drawn in, which read UIKit's trait instead. Apply it to the destination of a `NavigationLink`, not to the
/// stack.
struct FollowsWindowAppearance: ViewModifier {
    @Environment(\.colorScheme) private var inherited
    @State private var style: UIUserInterfaceStyle = .unspecified

    func body(content: Content) -> some View {
        // Until the window has been read, keep what the screen was pushed
        // with rather than guessing.
        content
            .environment(\.colorScheme, scheme(for: style) ?? inherited)
            .background(WindowStyleReader(style: $style))
    }

    private func scheme(for style: UIUserInterfaceStyle) -> ColorScheme? {
        switch style {
        case .dark: .dark
        case .light: .light
        default: nil
        }
    }
}

private struct WindowStyleReader: UIViewRepresentable {
    @Binding var style: UIUserInterfaceStyle

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = { style = $0 }
        return view
    }

    func updateUIView(_ uiView: ReaderView, context: Context) {}

    final class ReaderView: UIView {
        var onChange: ((UIUserInterfaceStyle) -> Void)?
        private weak var observed: UIWindow?
        private weak var pinned: UIViewController?
        private var token: (any UITraitChangeRegistration)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let token { observed?.unregisterForTraitChanges(token) }
            token = nil
            observed = window
            guard let window else {
                // Leaving the screen: hand the style back rather than leave
                // the controller pinned to whatever it last was.
                pinned?.overrideUserInterfaceStyle = .unspecified
                pinned = nil
                return
            }
            token = window.registerForTraitChanges(
                [UITraitUserInterfaceStyle.self]
            ) { [weak self] (window: UIWindow, _: UITraitCollection) in
                self?.report(window.traitCollection.userInterfaceStyle)
            }
            report(window.traitCollection.userInterfaceStyle)
        }

        private func report(_ style: UIUserInterfaceStyle) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // The screen's own controller carries the stale trait too, and
                // system colours — a chart's axis labels, a segmented picker —
                // resolve from it rather than from SwiftUI's environment.
                if let controller = self.hostingController {
                    controller.overrideUserInterfaceStyle = style
                    self.pinned = controller
                }
                self.onChange?(style)
            }
        }

        private var hostingController: UIViewController? {
            var responder: UIResponder? = self
            while let next = responder?.next {
                if let controller = next as? UIViewController { return controller }
                responder = next
            }
            return nil
        }
    }
}

extension View {
    /// See `FollowsWindowAppearance`.
    func followsWindowAppearance() -> some View {
        modifier(FollowsWindowAppearance())
    }
}
