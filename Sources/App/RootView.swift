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
/// won out over the iOS convention here. Swiping the content area pages
/// between tabs the same way tapping a pill does; both drive the same
/// `tab` selection so the highlight always matches what's on screen.
///
/// From 1024pt of window width (an iPad Pro 13", any iPad in landscape, a wide
/// Stage Manager window) the same tabs become a sidebar instead. The decision
/// is the window's width, never the device: an iPad in Split View at phone
/// width keeps the top bar.
struct RootView: View {
    @Environment(\.modelContext) private var context
    @State private var tab: LiftTab = .home
    @State private var showingSettings = false

    var body: some View {
        // Measured, not asked of the device: an iPad window in Split View is
        // phone-width and gets the phone's layout (see AdaptiveLayout).
        GeometryReader { proxy in
            let showsSidebar = proxy.size.width >= AdaptiveLayout.sidebarMinWidth

            // The sidebar and the tab bar are conditional siblings of one
            // TabView, which keeps its identity when a window crosses the
            // breakpoint -- every tab keeps its state (Train's date, Cook's
            // segment) through a rotation or a resize.
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

                    TabView(selection: $tab) {
                        HomeView().tag(LiftTab.home)
                        FoodView().tag(LiftTab.food)
                        CookView().tag(LiftTab.cook)
                        TrainView().tag(LiftTab.train)
                        RoutinesView().tag(LiftTab.routines)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .indexViewStyle(.page(backgroundDisplayMode: .never))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .environment(\.pageWidth, showsSidebar
                                 ? proxy.size.width - AdaptiveLayout.sidebarWidth - 1
                                 : proxy.size.width)
                }
            }
        }
        .background(Theme.background)
        .liftAppearance()
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .liftAppearance()
        }
        .task { FoodEntryGramMigration.run(context: context) }
    }

    /// The tabs as a column, for a window wide enough that a top bar of five
    /// words would be mostly empty space. Same selection, same accent-text
    /// highlight the tab bar uses, with the accent rule on the leading edge
    /// where the tab bar puts it underneath.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(LiftTab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    HStack(spacing: 12) {
                        Rectangle()
                            .fill(tab == item ? Theme.accent : Color.clear)
                            .frame(width: 3, height: 22)
                        Image(systemName: item.systemImage)
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 24)
                        Text(item.rawValue)
                            .font(.system(size: 16, weight: .semibold))
                            .tracking(0.5)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(tab == item ? Theme.accent : Theme.textSecondary)
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
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 24)
                    Text("Settings")
                        .font(.system(size: 16, weight: .semibold))
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
                    withAnimation(.easeOut(duration: 0.18)) { tab = item }
                } label: {
                    // The browser build underlines the selected tab and turns
                    // its text accent; it does not fill the tab. A solid accent
                    // rectangle reads as a button, and was the most visible
                    // difference between this app and the web.
                    VStack(spacing: 0) {
                        Text(item.rawValue)
                            .font(.system(size: 13, weight: .semibold))
                            .tracking(1.0)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .foregroundStyle(tab == item ? Theme.accent : Theme.textSecondary)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                        Rectangle()
                            .fill(tab == item ? Theme.accent : Color.clear)
                            .frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
                .keyboardShortcut(item.shortcut, modifiers: .command)
            }

            // Settings holds the coach card and the backup file. Until this
            // button existed nothing in the app presented SettingsView, so
            // both were unreachable however far you dug.
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(Theme.surface)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .clearOfWindowControls(.leading)
        .background(Theme.background)
    }
}
