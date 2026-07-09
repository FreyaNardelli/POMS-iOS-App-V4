import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }

            LiveSensorsView()
                .tabItem { Label("Live", systemImage: "waveform.path.ecg") }

            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }

            RewardsView()
                .tabItem { Label("Rewards", systemImage: "star.fill") }
        }
        .tint(Theme.orange)
        .onAppear {
            // Light tab bar to match the kid-facing Home / Rewards screens.
            let appearance = UITabBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = UIColor.white
            UITabBar.appearance().standardAppearance = appearance
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
    }
}
