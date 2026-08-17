import SwiftUI

private enum DouyinTab: Hashable {
    case recommend
    case following
    case live
    case favorites
    case settings
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: DouyinTab = .recommend
    @State private var refreshRevision = 0
    @State private var appEntryRevision = 0
    @State private var lastRefreshTime = Date.distantPast

    var body: some View {
        TabView(selection: $selectedTab) {
            DouyinFeedView(
                feedType: .recommend,
                isActive: selectedTab == .recommend,
                refreshRevision: refreshRevision,
                appEntryRevision: appEntryRevision,
                onRefreshRequested: refreshSelectedTab
            )
                .tabItem {
                    Label("推荐", systemImage: "sparkles")
                }
                .tag(DouyinTab.recommend)
            
            DouyinFeedView(
                feedType: .following,
                isActive: selectedTab == .following,
                refreshRevision: refreshRevision,
                appEntryRevision: appEntryRevision,
                onRefreshRequested: refreshSelectedTab
            )
                .tabItem {
                    Label("关注", systemImage: "person.2.fill")
                }
                .tag(DouyinTab.following)

            LiveLibraryView(
                isActive: selectedTab == .live,
                refreshRevision: refreshRevision,
                onRefreshRequested: refreshSelectedTab
            )
                .tabItem {
                    Label("直播", systemImage: "dot.radiowaves.left.and.right")
                }
                .tag(DouyinTab.live)

            FavoritesLibraryView(
                isActive: selectedTab == .favorites,
                refreshRevision: refreshRevision,
                onRefreshRequested: refreshSelectedTab
            )
                .tabItem {
                    Label("我的喜欢", systemImage: "heart.fill")
                }
                .tag(DouyinTab.favorites)
            
            SettingsView(
                isActive: selectedTab == .settings,
                refreshRevision: refreshRevision
            )
                .tabItem {
                    Label("设置", systemImage: "gearshape.fill")
                }
                .tag(DouyinTab.settings)
        }
        .onPlayPauseCommand(perform: refreshSelectedTab)
        .onAppear {
            PlaybackDiagnostics.shared.event(
                "initial",
                category: "tab",
                fields: ["selected": String(describing: selectedTab)]
            )
        }
        .onChange(of: selectedTab) { previousTab, selectedTab in
            PlaybackDiagnostics.shared.event(
                "changed",
                category: "tab",
                fields: [
                    "from": String(describing: previousTab),
                    "to": String(describing: selectedTab)
                ]
            )
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            appEntryRevision &+= 1
        }
    }

    private func refreshSelectedTab() {
        let now = Date()
        guard now.timeIntervalSince(lastRefreshTime) >= 0.25 else { return }
        lastRefreshTime = now
        refreshRevision &+= 1
        PlaybackDiagnostics.shared.event(
            "remote-refresh",
            category: "tab",
            fields: ["selected": String(describing: selectedTab)]
        )
    }
}
