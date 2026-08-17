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
    @State private var refreshNotice: String?
    @State private var refreshNoticeTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .top) {
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

            if let refreshNotice {
                Label(refreshNotice, systemImage: "arrow.clockwise")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .background(.black.opacity(0.78), in: Capsule())
                    .padding(.top, 34)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
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
        refreshNoticeTask?.cancel()
        withAnimation(.easeOut(duration: 0.18)) {
            refreshNotice = "正在刷新\(selectedTab.title)最新内容"
        }
        refreshNoticeTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.18)) {
                refreshNotice = nil
            }
        }
        PlaybackDiagnostics.shared.event(
            "remote-refresh",
            category: "tab",
            fields: ["selected": String(describing: selectedTab)]
        )
    }
}

private extension DouyinTab {
    var title: String {
        switch self {
        case .recommend: "推荐"
        case .following: "关注"
        case .live: "直播"
        case .favorites: "我的喜欢"
        case .settings: "设置"
        }
    }
}
