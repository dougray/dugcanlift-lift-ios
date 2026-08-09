import SwiftUI

enum LiftTab: String, CaseIterable, Identifiable {
    case home = "Home"
    case food = "Food"
    case train = "Train"

    var id: String { rawValue }
}

/// Top tab bar with an underline indicator, matching the Android build.
/// This is deliberately not a UITabView — the Android information architecture
/// won out over the iOS convention here.
struct RootView: View {
    @State private var tab: LiftTab = .home
    @Namespace private var indicator

    var body: some View {
        VStack(spacing: 0) {
            tabBar

            Group {
                switch tab {
                case .home:  HomeView()
                case .food:  FoodView()
                case .train: TrainView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(LiftTab.allCases) { item in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { tab = item }
                } label: {
                    VStack(spacing: 8) {
                        Text(item.rawValue)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(tab == item ? Theme.accent : Theme.accent.opacity(0.62))
                            .padding(.top, 12)

                        ZStack {
                            Rectangle().fill(.clear).frame(height: 2)
                            if tab == item {
                                Rectangle()
                                    .fill(Theme.accent)
                                    .frame(height: 2)
                                    .matchedGeometryEffect(id: "indicator", in: indicator)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(Theme.background)
    }
}
