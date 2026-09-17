import SwiftUI
import LiftCore

/// How LIFT uses a large screen: an iPad, an iPad window in Split View or
/// Stage Manager, or the biggest iPhones turned sideways.
///
/// Every decision here is made from the **width the view actually has**, never
/// from the device idiom or the size class alone. An iPad app squeezed into a
/// third of the screen is a phone-width window and must look like the phone;
/// an iPhone Pro Max in landscape has more room than an iPad mini in Split View.
///
/// Every threshold is chosen so an iPhone in portrait (402pt at most, less
/// the 16pt page gutters) stays below it. Portrait iPhone is the layout the
/// app was designed for, and below every threshold these helpers lay out
/// exactly as the plain `VStack` they replace.
enum AdaptiveLayout {
    /// The sidebar replaces the top tab bar from here. iPad Pro 13" in either
    /// orientation, an 11" or mini iPad in landscape, a wide Stage Manager
    /// window. Matches Coach web's sidebar breakpoint.
    static let sidebarMinWidth: CGFloat = 1024
    static let sidebarWidth: CGFloat = 220

    /// The narrowest a card column may get before a grid drops a column.
    /// Two columns of it (plus the gap) is 640pt, Coach web's two-column
    /// breakpoint.
    static let cardMinWidth: CGFloat = 314

    /// A week plan lays its seven days side by side from this content width.
    static let weekColumnsMinWidth: CGFloat = 1000

    /// Forms, editors and single-column lists never stretch past this.
    static let readableWidth: CGFloat = 700

    /// Nothing stretches past this, however wide the window gets.
    static let maxContentWidth: CGFloat = 1600

    /// The page gutter every screen already uses on the phone.
    static let pageGutter: CGFloat = 16

    /// How many columns of at least `minWidth` fit in `width`, from 1 to
    /// `maxColumns`.
    static func columns(for width: CGFloat, minWidth: CGFloat = cardMinWidth,
                        spacing: CGFloat = Theme.cardSpacing, maxColumns: Int = 2) -> Int {
        guard width.isFinite, width > 0 else { return 1 }
        let fit = Int(((width + spacing) / (minWidth + spacing)).rounded(.down))
        return min(max(fit, 1), maxColumns)
    }

    /// The width inside a page's gutters, capped at `maxContentWidth`.
    static func contentWidth(forPage width: CGFloat) -> CGFloat {
        min(width - pageGutter * 2, maxContentWidth)
    }
}

// MARK: - Page width

private struct PageWidthKey: EnvironmentKey {
    /// Zero means "not measured": every helper treats it as one column.
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// The width of the area a top-level tab is drawn in — the window, less
    /// the sidebar when there is one. `RootView` measures it.
    var pageWidth: CGFloat {
        get { self[PageWidthKey.self] }
        set { self[PageWidthKey.self] = newValue }
    }
}

// MARK: - Modifiers

extension View {
    /// Caps a page's content at `maxContentWidth` and centres it.
    ///
    /// Apply outside the page's own padding. A flexible frame takes the width
    /// it is offered up to its maximum, so on a phone this is the width the
    /// content already had.
    func adaptivePageWidth() -> some View {
        frame(maxWidth: AdaptiveLayout.maxContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
    }

    /// Caps a form or editor at a readable width and centres it.
    func readableContentWidth() -> some View {
        frame(maxWidth: AdaptiveLayout.readableWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
    }

    /// Moves content clear of an iPad window's controls (the close / minimise
    /// / tile buttons iPadOS 26 draws in a window's top-leading corner) when
    /// the window has them. The app's own top bars are not navigation bars,
    /// so the system does not do this for them. Where there are no window
    /// controls the insets are zero and nothing moves.
    @ViewBuilder
    func clearOfWindowControls(_ edges: Edge.Set) -> some View {
        if #available(iOS 26.0, *) {
            containerCornerOffset(edges, sizeToFit: true)
        } else {
            self
        }
    }

    /// The `List`/`Form` counterpart of `readableContentWidth()`: centres the
    /// rows in a readable column by widening the list's margins, so the list
    /// itself (and its scroll indicator, swipe actions and background) still
    /// spans the screen. Below the readable width the system margins are left
    /// exactly as they were.
    func readableListMargins() -> some View {
        modifier(ReadableListMargins())
    }
}

private struct ReadableListMargins: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { proxy in
            let spare = proxy.size.width - AdaptiveLayout.readableWidth
            content.contentMargins(.horizontal, spare > 40 ? spare / 2 : nil, for: .scrollContent)
        }
    }
}

// MARK: - Columns

/// Cards in columns, each card placed under the shortest column so far —
/// cards of very different heights (a macro card beside a steps card) leave
/// no holes. With one column it is a leading-aligned `VStack`, so a phone gets
/// the stack it always had.
///
/// One `AnyLayout`, not an `if`: crossing a breakpoint (rotating, resizing a
/// window) re-lays out the same views rather than rebuilding them, so a text
/// field keeps its focus and a card keeps its state.
struct AdaptiveColumns<Content: View>: View {
    let columns: Int
    var spacing: CGFloat = Theme.cardSpacing
    @ViewBuilder var content: Content

    var body: some View {
        let layout = columns > 1
            ? AnyLayout(MasonryColumnsLayout(columns: columns, spacing: spacing))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
        layout { content }
    }
}

/// Cards in rows, reading order left to right, each row top-aligned. For lists
/// of like items (recipes, shopping lines) where reading order matters more
/// than packing. With one column it is a leading-aligned `VStack`.
struct AdaptiveGrid<Content: View>: View {
    let columns: Int
    var spacing: CGFloat = Theme.cardSpacing
    @ViewBuilder var content: Content

    var body: some View {
        let layout = columns > 1
            ? AnyLayout(RowGridLayout(columns: columns, spacing: spacing))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
        layout { content }
    }
}

/// Equal-width columns; each subview goes to the currently shortest one.
/// A subview with no height (a section with nothing to show) takes no slot
/// and no spacing.
struct MasonryColumnsLayout: Layout {
    var columns: Int
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions(by: CGSize(width: 800, height: 0)).width
        let placements = arrange(width: width, subviews: subviews)
        return CGSize(width: width, height: placements.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placements = arrange(width: bounds.width, subviews: subviews)
        for (index, frame) in placements.frames {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [Int: CGRect], height: CGFloat) {
        let count = max(columns, 1)
        let columnWidth = max((width - spacing * CGFloat(count - 1)) / CGFloat(count), 0)
        var heights = Array(repeating: CGFloat(0), count: count)
        var frames: [Int: CGRect] = [:]

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
            guard size.height > 0 else { continue }
            let column = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let y = heights[column] == 0 ? 0 : heights[column] + spacing
            frames[index] = CGRect(x: CGFloat(column) * (columnWidth + spacing), y: y,
                                   width: columnWidth, height: size.height)
            heights[column] = y + size.height
        }
        return (frames, heights.max() ?? 0)
    }
}

/// Equal-width columns filled row by row; each row is as tall as its tallest
/// item and items are top-aligned in it.
struct RowGridLayout: Layout {
    var columns: Int
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions(by: CGSize(width: 800, height: 0)).width
        return CGSize(width: width, height: arrange(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placements = arrange(width: bounds.width, subviews: subviews)
        for (index, frame) in placements.frames {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [Int: CGRect], height: CGFloat) {
        let count = max(columns, 1)
        let columnWidth = max((width - spacing * CGFloat(count - 1)) / CGFloat(count), 0)
        var frames: [Int: CGRect] = [:]
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var column = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
            guard size.height > 0 else { continue }
            if column == count {
                y += rowHeight + spacing
                rowHeight = 0
                column = 0
            }
            frames[index] = CGRect(x: CGFloat(column) * (columnWidth + spacing), y: y,
                                   width: columnWidth, height: size.height)
            rowHeight = max(rowHeight, size.height)
            column += 1
        }
        return (frames, frames.isEmpty ? 0 : y + rowHeight)
    }
}
