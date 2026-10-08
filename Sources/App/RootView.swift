import SwiftUI
import SwiftData
import LiftCore

enum LiftTab: String, CaseIterable, Identifiable, Hashable {
    case home = "Home"
    case food = "Food"
    case cook = "Cook"
    case train = "Train"
    case routines = "Routines"

    var id: String { rawValue }

    /// The sidebar's icon. The phone's top bar is words only.
    var systemImage: String {
        switch self {
        case .home:     return "house"
        case .food:     return "fork.knife"
        case .cook:     return "frying.pan"
        case .train:    return "dumbbell"
        case .routines: return "list.bullet.rectangle"
        }
    }

    /// Command-1 to Command-5, in tab order, for a hardware keyboard.
    var shortcut: KeyEquivalent {
        KeyEquivalent(Character(String((LiftTab.allCases.firstIndex(of: self) ?? 0) + 1)))
    }
}

/// Top tab bar of equal-width pill buttons, matching the Android build.
/// This is deliberately not a UITabView — the Android information architecture
/// won out over the iOS convention here. Tapping a tab switches to it.
///
/// No paging swipe. A `.page` TabView used to sit under the strip, and its
/// horizontal swipe competed with the chip rows (Focus, Activity, category)
/// and with swipe actions in lists, and slid regardless of Reduce Motion. The
/// web-parity look is the brief; the paging gesture never was.
///
/// Tabs are built the first time they are opened and then kept alive
/// (hidden, not destroyed), so a tab's state -- Train's selected day, Cook's
/// segment, a scroll position -- survives switching away, as it did under the
/// TabView.
///
/// From 1024pt of window width (an iPad Pro 13", any iPad in landscape, a wide
/// Stage Manager window) the same tabs become a sidebar instead. The decision
/// is the window's width, never the device: an iPad in Split View at phone
/// width keeps the top bar.
struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tab: LiftTab = .home
    @State private var visited: Set<LiftTab> = [.home]
    @State private var showingSettings = false
    @State private var undo = UndoToastCenter.shared

    var body: some View {
        // Measured, not asked of the device: an iPad window in Split View is
        // phone-width and gets the phone's layout (see AdaptiveLayout).
        GeometryReader { proxy in
            let showsSidebar = proxy.size.width >= AdaptiveLayout.sidebarMinWidth

            // The sidebar and the tab bar are conditional siblings of one
            // page container, which keeps its identity when a window crosses
            // the breakpoint -- every tab keeps its state (Train's date,
            // Cook's segment) through a rotation or a resize.
            HStack(spacing: 0) {
                if showsSidebar {
                    sidebar
                    Rectangle()
                        .fill(Theme.hairline)
                        .frame(width: 1)
                        .ignoresSafeArea(edges: .vertical)
                }

                VStack(spacing: 0) {
                    if !showsSidebar {
                        tabBar
                    }

                    ZStack {
                        ForEach(LiftTab.allCases) { item in
                            if visited.contains(item) {
                                page(item)
                                    .opacity(tab == item ? 1 : 0)
                                    .allowsHitTesting(tab == item)
                                    .accessibilityHidden(tab != item)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .environment(\.pageWidth, showsSidebar
                                 ? proxy.size.width - AdaptiveLayout.sidebarWidth - 1
                                 : proxy.size.width)
                }
            }
        }
        .background(Theme.background)
        .tint(Theme.accentText)
        .overlay(alignment: .bottom) {
            if let toast = undo.current {
                UndoToastBar(toast: toast, center: undo)
                    .frame(maxWidth: AdaptiveLayout.readableWidth)
                    .id(toast.id)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: undo.current?.id)
        .liftAppearance()
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .tint(Theme.accentText)
                .liftAppearance()
        }
        .task { FoodEntryGramMigration.run(context: context) }
    }

    @ViewBuilder
    private func page(_ item: LiftTab) -> some View {
        switch item {
        case .home: HomeView()
        case .food: FoodView()
        case .cook: CookView()
        case .train: TrainView()
        case .routines: RoutinesView()
        }
    }

    /// A crossfade, and none at all under Reduce Motion.
    private func select(_ item: LiftTab) {
        visited.insert(item)
        if reduceMotion {
            tab = item
        } else {
            withAnimation(.easeOut(duration: 0.18)) { tab = item }
        }
    }

    /// The tabs as a column, for a window wide enough that a top bar of five
    /// words would be mostly empty space. Same selection, same accent-text
    /// highlight the tab bar uses, with the accent rule on the leading edge
    /// where the tab bar puts it underneath.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(LiftTab.allCases) { item in
                Button {
                    select(item)
                } label: {
                    HStack(spacing: 12) {
                        Rectangle()
                            .fill(tab == item ? Theme.accent : Color.clear)
                            .frame(width: 3, height: 22)
                        Image(systemName: item.systemImage)
                            .scaledFont(size: 16, weight: .semibold)
                            .frame(width: 24)
                        Text(item.rawValue)
                            .scaledFont(size: 16, weight: .semibold)
                            .tracking(0.5)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(tab == item ? Theme.accentText : Theme.textSecondary)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(item.shortcut, modifiers: .command)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }

            Spacer(minLength: 0)

            Button {
                showingSettings = true
            } label: {
                HStack(spacing: 12) {
                    Color.clear.frame(width: 3, height: 22)
                    Image(systemName: "gearshape")
                        .scaledFont(size: 16, weight: .semibold)
                        .frame(width: 24)
                    Text("Settings")
                        .scaledFont(size: 16, weight: .semibold)
                        .tracking(0.5)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
        }
        .padding(.top, 16)
        .padding(.bottom, 12)
        .padding(.trailing, 12)
        .clearOfWindowControls(.top)
        .frame(width: AdaptiveLayout.sidebarWidth)
        .background(Theme.background)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(LiftTab.allCases) { item in
                Button {
                    select(item)
                } label: {
                    // The browser build underlines the selected tab and turns
                    // its text accent; it does not fill the tab. A solid accent
                    // rectangle reads as a button, and was the most visible
                    // difference between this app and the web.
                    VStack(spacing: 0) {
                        Text(item.rawValue)
                            .scaledFont(size: 13, weight: .semibold)
                            .tracking(1.0)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .foregroundStyle(tab == item ? Theme.accentText : Theme.textSecondary)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                        Rectangle()
                            .fill(tab == item ? Theme.accent : Color.clear)
                            .frame(height: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(item.shortcut, modifiers: .command)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
                .accessibilityShowsLargeContentViewer()
            }

            // Settings holds the coach card and the backup file. Until this
            // button existed nothing in the app presented SettingsView, so
            // both were unreachable however far you dug.
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(Theme.surface)
                    .clipShape(Capsule())
                    // 32pt to look at, 44pt to hit.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .clearOfWindowControls(.leading)
        .background(Theme.background)
        // Five labels share one row; past this size they would shrink to
        // illegibility. The Large Content Viewer (long-press) covers the rest.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}
