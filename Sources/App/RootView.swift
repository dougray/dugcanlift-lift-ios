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
}

/// Top tab bar of equal-width pill buttons, matching the Android build.
/// This is deliberately not a UITabView — the Android information architecture
/// won out over the iOS convention here. Swiping the content area pages
/// between tabs the same way tapping a pill does; both drive the same
/// `tab` selection so the highlight always matches what's on screen.
struct RootView: View {
    @Environment(\.modelContext) private var context
    @State private var tab: LiftTab = .home
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            tabBar

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
        }
        .background(Theme.background)
        .liftAppearance()
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .liftAppearance()
        }
        .task { FoodEntryGramMigration.run(context: context) }
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
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(Theme.background)
    }
}
