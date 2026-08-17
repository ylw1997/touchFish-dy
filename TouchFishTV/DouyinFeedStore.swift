import Foundation

enum FeedNavigation {
    static func previousIndex(current: Int, count: Int) -> Int? {
        current > 0 && current < count ? current - 1 : nil
    }

    static func nextIndex(current: Int, count: Int) -> Int? {
        current >= 0 && current + 1 < count ? current + 1 : nil
    }
}

@MainActor
final class DouyinFeedStore: ObservableObject {
    private static let lastRecommendationKey = "douyin_last_recommendation_v1"
    @Published private(set) var items: [Aweme] = []
    @Published private(set) var activeIndex = 0
    @Published private(set) var playbackToken: UInt64 = 0
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let feedType: FeedType
    private let api: DouyinAPI
    private var cursor = 0
    private var hasMore = true
    private var recommendRefreshIndex = 1
    private var recommendViewCount = 0
    private var generation: UInt = 0
    private var paginationTask: Task<Void, Never>?
    private var paginationGeneration: UInt = 0
    private let retainedPreviousItems = 5

    init(feedType: FeedType, api: DouyinAPI? = nil) {
        self.feedType = feedType
        self.api = api ?? .shared
    }

    var activeItem: Aweme? {
        items.indices.contains(activeIndex) ? items[activeIndex] : nil
    }

    var nextItem: Aweme? {
        let index = activeIndex + 1
        return items.indices.contains(index) ? items[index] : nil
    }

    /// 每次进入应用时，推荐页先恢复上次成功获取到的最后一条普通视频，
    /// 同时在后台换取新列表。这样热启动不会停在离开前的播放位置，冷启动
    /// 也不必等待推荐接口返回后才出现画面。
    func prepareForAppEntry() async {
        guard case .recommend = feedType else {
            if items.isEmpty { await refresh() }
            return
        }
        // 重新进入应用时不沿用离开前的翻页请求；当前入口只恢复缓存首帧，
        // 随后请求一份新的推荐列表。
        if paginationTask != nil {
            cancelPagination()
            isLoading = false
        }
        if let cached = Self.loadLastRecommendation() {
            items = [cached]
            activeIndex = 0
            playbackToken &+= 1
        }
        // 前一次进入触发的新列表请求若仍在进行，继续复用它；缓存视频已经
        // 在上面同步恢复，不需要为了同一批数据再发一条请求。
        guard !isLoading else { return }

        generation &+= 1
        cursor = 0
        hasMore = true
        recommendRefreshIndex = 1
        recommendViewCount = 0
        _ = await load(isRefresh: true, preservingCurrentItem: !items.isEmpty)
    }

    func refresh() async {
        cancelPagination()
        generation &+= 1
        cursor = 0
        hasMore = true
        // 手动刷新继续使用递增的推荐刷新序号，让服务端返回下一批最新推荐；
        // 只有重新进入应用时才从一套新的推荐会话上下文开始。
        isLoading = false
        _ = await load(isRefresh: true)
    }

    func previous() {
        guard let index = FeedNavigation.previousIndex(current: activeIndex, count: items.count) else { return }
        select(index)
    }

    func next() async {
        if let index = FeedNavigation.nextIndex(current: activeIndex, count: items.count) {
            select(index)
            trimPlayedHistoryIfNeeded()
            return
        }

        let oldCount = items.count
        if let paginationTask {
            await paginationTask.value
        } else {
            _ = await load(isRefresh: false)
        }
        if activeIndex == oldCount - 1, items.count > oldCount {
            select(oldCount)
            trimPlayedHistoryIfNeeded()
        }
    }

    func activeItemDidStartPlayback() {
        scheduleNextPageIfPlayingLastItem()
    }

    /// 当前页最后一条一开始播放就只请求下一页。列表分页与播放器的
    /// “当前项 + 下一项”媒体队列互不干扰，也不会为了预热视频连拉多页。
    private func scheduleNextPageIfPlayingLastItem() {
        guard activeIndex == items.count - 1,
              hasMore,
              paginationTask == nil else { return }
        paginationGeneration &+= 1
        let requestedPaginationGeneration = paginationGeneration
        paginationTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.load(isRefresh: false)
            if requestedPaginationGeneration == self.paginationGeneration {
                self.paginationTask = nil
            }
        }
    }

    private func cancelPagination() {
        paginationGeneration &+= 1
        paginationTask?.cancel()
        paginationTask = nil
    }

    @discardableResult
    private func load(
        isRefresh: Bool,
        preservingCurrentItem: Bool = false
    ) async -> Bool {
        guard !isLoading, isRefresh || hasMore else { return false }
        let requestGeneration = generation
        isLoading = true
        errorMessage = nil
        defer {
            if requestGeneration == generation { isLoading = false }
        }

        do {
            let result: ([Aweme], Int, Bool)
            switch feedType {
            case .recommend:
                let page = try await api.getFeed(
                    refreshIndex: recommendRefreshIndex,
                    viewCount: recommendViewCount
                )
                result = (page.0, 0, page.1)
            case .following:
                result = try await api.getFollowing(cursor: isRefresh ? 0 : cursor)
            }

            guard requestGeneration == generation else { return false }
            if isRefresh {
                if preservingCurrentItem, let current = activeItem {
                    items = [current] + result.0.filter { $0.aweme_id != current.aweme_id }
                    activeIndex = 0
                } else {
                    items = result.0
                    activeIndex = 0
                    playbackToken &+= 1
                }
            } else {
                items.append(contentsOf: result.0)
            }
            cursor = result.1
            hasMore = result.2
            if case .recommend = feedType {
                recommendRefreshIndex += 1
                recommendViewCount += result.0.count
                Self.saveLastRecommendation(from: result.0)
            }
            if items.isEmpty { errorMessage = "当前没有可播放的视频" }
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard requestGeneration == generation else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func select(_ index: Int) {
        activeIndex = index
        playbackToken &+= 1
    }

    private func trimPlayedHistoryIfNeeded() {
        let removeCount = max(0, activeIndex - retainedPreviousItems)
        guard removeCount > 0 else { return }
        items.removeFirst(removeCount)
        activeIndex -= removeCount
    }

    private static func saveLastRecommendation(from items: [Aweme]) {
        guard let item = items.last(where: { !$0.isLive && $0.video != nil }),
              let data = try? JSONEncoder().encode(item) else { return }
        UserDefaults.standard.set(data, forKey: lastRecommendationKey)
    }

    private static func loadLastRecommendation() -> Aweme? {
        guard let data = UserDefaults.standard.data(forKey: lastRecommendationKey),
              let item = try? JSONDecoder().decode(Aweme.self, from: data),
              !item.isLive,
              item.video != nil else { return nil }
        return item
    }
}
