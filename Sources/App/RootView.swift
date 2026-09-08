import SwiftUI

enum LiftTab: String, CaseIterable, Identifiable {
    case home = "Home"
    case food = "Food"
    case cook = "Cook"
    case train = "Train"
    case routines = "Routines"
    case outdoor = "Outdoor"

    var id: String { rawValue }
}

/// Top tab bar of equal-width pill buttons, matching the Android build.
/// This is deliberately not a UITabView — the Android information architecture
/// won out over the iOS convention here.
struct RootView: View {
    @State private var tab: LiftTab = .home
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            tabBar

            Group {
                switch tab {
                case .home:     HomeView()
                case .food:     FoodView()
                case .cook:     CookView()
                case .train:    TrainView()
                case .routines: RoutinesView()
                case .outdoor:  OutdoorActivityListView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .preferredColorScheme(.dark)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(LiftTab.allCases) { item in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { tab = item }
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(tab == item ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(tab == item ? Theme.accent : Theme.surface)
                        .clipShape(Capsule())
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
