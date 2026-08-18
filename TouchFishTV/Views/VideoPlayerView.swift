import AVKit
import SwiftUI
import UIKit

@MainActor
struct VideoPlayerView: View {
    @ObservedObject var coordinator: PlaybackCoordinator

    let aweme: Aweme
    let cookie: String
    let playbackToken: UInt64
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onRefresh: (() -> Void)?
    let onShowAuthor: (() -> Void)?

    init(
        aweme: Aweme,
        cookie: String,
        playbackToken: UInt64,
        coordinator: PlaybackCoordinator,
        onPrevious: @escaping () -> Void,
        onNext: @escaping () -> Void,
        onRefresh: (() -> Void)? = nil,
        onShowAuthor: (() -> Void)? = nil
    ) {
        self.aweme = aweme
        self.cookie = cookie
        self.playbackToken = playbackToken
        self.coordinator = coordinator
        self.onPrevious = onPrevious
        self.onNext = onNext
        self.onRefresh = onRefresh
        self.onShowAuthor = onShowAuthor
    }

    var body: some View {
        ZStack {
            NativePlayerController(
                controller: coordinator.playerViewController,
                isTransitioning: coordinator.isTransitioning,
                allowsNavigationWhileStopped: coordinator.isTransitioning
                    || coordinator.playbackError != nil,
                onPrevious: onPrevious,
                onNext: onNext,
                onRefresh: onRefresh,
                authorName: aweme.displayAuthor?.nickname,
                onShowAuthor: aweme.displayAuthor?.uid.isEmpty == false ? onShowAuthor : nil,
                isLive: aweme.isLive,
                danmakuAvailable: true,
                qualityOptions: coordinator.qualityOptions,
                selectedQualityID: coordinator.selectedQualityID,
                onSelectQuality: { [weak coordinator] qualityID in
                    coordinator?.selectQuality(qualityID)
                },
                onVisible: { [weak coordinator] in coordinator?.resume() }
            )

            if let playbackError = coordinator.playbackError {
                VStack(spacing: 18) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 54, weight: .light))
                        .foregroundStyle(.orange)
                    Text(playbackError)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("使用遥控器上键或下键切换视频")
                        .foregroundStyle(Color.white.opacity(0.7))
                }
                .allowsHitTesting(false)
            }
        }
        .opacity(coordinator.presentationOpacity)
        .animation(.easeOut(duration: 0.18), value: coordinator.presentationOpacity)
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard let item = notification.object as? AVPlayerItem,
                  coordinator.shouldAdvanceAfterFinishing(item) else { return }
            onNext()
        }
    }
}

final class DouyinPlayerContainerViewController: UIViewController {
    let diagnosticsID = String(UUID().uuidString.prefix(6))
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onRefresh: (() -> Void)? {
        didSet { refreshPressRecognizer?.isEnabled = onRefresh != nil }
    }
    var onShowAuthor: (() -> Void)?
    var onSelectQuality: ((String) -> Void)?
    var onVisible: (() -> Void)?
    var isTransitioning = false
    var allowsNavigationWhileStopped = false
    let danmakuController = DanmakuOverlayController()

    private let playbackController = AVPlayerViewController()
    private var refreshPressRecognizer: UITapGestureRecognizer?

    private var navigationLocked = false
    private var configuredAuthorName: String?
    private var configuredHasAuthorAction = false
    private var configuredIsLive: Bool?
    private var configuredDanmakuEnabled: Bool?
    private var configuredDanmakuAvailable = true
    private var configuredQualityOptions: [PlaybackQualityOption] = []
    private var configuredSelectedQualityID = "auto"

    private enum NavigationDirection {
        case previous
        case next
    }

    var player: AVPlayer? {
        get { playbackController.player }
        set { playbackController.player = newValue }
    }

    var requiresLinearPlayback: Bool {
        get { playbackController.requiresLinearPlayback }
        set { playbackController.requiresLinearPlayback = newValue }
    }

    var transportBarCustomMenuItems: [UIMenuElement] {
        get { playbackController.transportBarCustomMenuItems }
        set { playbackController.transportBarCustomMenuItems = newValue }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        PlaybackDiagnostics.shared.event(
            "deinit",
            category: "controller",
            fields: ["controller": diagnosticsID]
        )
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [playbackController]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        PlaybackDiagnostics.shared.event(
            "view-did-load",
            category: "controller",
            fields: ["controller": diagnosticsID]
        )

        addChild(playbackController)
        playbackController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(playbackController.view)
        NSLayoutConstraint.activate([
            playbackController.view.topAnchor.constraint(equalTo: view.topAnchor),
            playbackController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playbackController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playbackController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        playbackController.didMove(toParent: self)
        playbackController.showsPlaybackControls = true
        playbackController.transportBarIncludesTitleView = true

        let refreshPress = UITapGestureRecognizer(
            target: self,
            action: #selector(handleRefreshPress)
        )
        refreshPress.allowedPressTypes = [NSNumber(value: UIPress.PressType.playPause.rawValue)]
        refreshPress.cancelsTouchesInView = true
        refreshPress.isEnabled = onRefresh != nil
        // AVPlayerViewController 会优先消费播放/暂停按键。识别器必须直接
        // 安装在它的视图上，放在外层容器时部分焦点状态收不到该按键。
        playbackController.view.addGestureRecognizer(refreshPress)
        refreshPressRecognizer = refreshPress

        danmakuController.install(in: playbackController)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(focusMovementDidFail(_:)),
            name: UIFocusSystem.movementDidFailNotification,
            object: nil
        )
    }

    func configureAuthorAction(
        name: String?,
        action: (() -> Void)?,
        isLive: Bool,
        danmakuAvailable: Bool,
        qualityOptions: [PlaybackQualityOption],
        selectedQualityID: String,
        onSelectQuality: ((String) -> Void)?
    ) {
        onShowAuthor = action
        self.onSelectQuality = onSelectQuality
        if isLive {
            // 部分直播 HLS 自带字幕轨，AVKit 会额外生成气泡按钮。
            // 关闭系统字幕轨；直播弹幕由 WebSocket 覆盖层提供。
            playbackController.allowedSubtitleOptionLanguages = []
        } else {
            playbackController.allowedSubtitleOptionLanguages = nil
        }
        if danmakuAvailable { danmakuController.synchronizePreference() }
        let normalizedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAuthorAction = action != nil
        let danmakuEnabled = danmakuController.isEnabled
        guard configuredAuthorName != normalizedName
                || configuredHasAuthorAction != hasAuthorAction
                || configuredIsLive != isLive
                || configuredDanmakuEnabled != danmakuEnabled
                || configuredDanmakuAvailable != danmakuAvailable
                || configuredQualityOptions != qualityOptions
                || configuredSelectedQualityID != selectedQualityID
                || transportBarCustomMenuItems.isEmpty else {
            return
        }

        configuredAuthorName = normalizedName
        configuredHasAuthorAction = hasAuthorAction
        configuredIsLive = isLive
        configuredDanmakuEnabled = danmakuEnabled
        configuredDanmakuAvailable = danmakuAvailable
        configuredQualityOptions = qualityOptions
        configuredSelectedQualityID = selectedQualityID
        rebuildTransportBarActions()
    }

    private func rebuildTransportBarActions() {
        var actions: [UIMenuElement] = []
        if onShowAuthor != nil {
            let userAction = UIAction(
                title: "用户",
                image: UIImage(systemName: "person.crop.circle")
            ) { [weak self] _ in
                self?.onShowAuthor?()
            }
            actions.append(userAction)
        }

        if configuredDanmakuAvailable {
            let danmakuEnabled = danmakuController.isEnabled
            configuredDanmakuEnabled = danmakuEnabled
            let danmakuAction = UIAction(
                title: danmakuEnabled ? "关闭弹幕" : "开启弹幕",
                image: UIImage(systemName: danmakuEnabled ? "captions.bubble.fill" : "captions.bubble")
            ) { [weak self] _ in
                guard let self else { return }
                self.danmakuController.setEnabled(!self.danmakuController.isEnabled)
                self.rebuildTransportBarActions()
            }
            actions.append(danmakuAction)
        }
        if configuredQualityOptions.count > 1 {
            let qualityActions = configuredQualityOptions.map { option in
                UIAction(
                    title: option.title,
                    state: option.id == configuredSelectedQualityID ? .on : .off
                ) { [weak self] _ in
                    guard let self else { return }
                    self.configuredSelectedQualityID = option.id
                    self.rebuildTransportBarActions()
                    self.onSelectQuality?(option.id)
                }
            }
            let qualitySubmenu = UIMenu(
                title: "清晰度",
                options: [.displayInline, .singleSelection],
                children: qualityActions
            )
            actions.append(
                UIMenu(
                    title: "清晰度",
                    image: UIImage(systemName: "gearshape"),
                    children: [qualitySubmenu]
                )
            )
        }
        transportBarCustomMenuItems = actions
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        PlaybackDiagnostics.shared.event(
            "view-did-appear",
            category: "controller",
            fields: ["controller": diagnosticsID, "hasPlayer": player != nil]
        )
        onVisible?()
        DispatchQueue.main.async { [weak self] in self?.requestPlayerFocus() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        PlaybackDiagnostics.shared.event(
            "view-did-disappear",
            category: "controller",
            fields: ["controller": diagnosticsID, "hasPlayer": player != nil]
        )
    }

    @objc private func handleRefreshPress() {
        guard let onRefresh else { return }
        PlaybackDiagnostics.shared.event(
            "remote-refresh",
            category: "controller",
            fields: ["controller": diagnosticsID]
        )
        onRefresh()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // 非 AVKit 焦点落在容器自身时的兜底；与手势同时触发也会被根视图的
        // 250ms 防抖合并成一次刷新请求。
        if presses.contains(where: { $0.type == .playPause }), onRefresh != nil {
            handleRefreshPress()
            return
        }
        super.pressesBegan(presses, with: event)
    }

    func requestPlayerFocus() {
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    @objc private func focusMovementDidFail(_ notification: Notification) {
        guard let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey]
                as? UIFocusUpdateContext,
              let focusedView = context.previouslyFocusedView,
              isInsidePlayer(focusedView) else { return }

        let isPlaybackSurface = isPlayerSurface(focusedView)

        PlaybackDiagnostics.shared.event(
            "focus-movement-failed",
            category: "controller",
            fields: [
                "controller": diagnosticsID,
                "heading": String(describing: context.focusHeading),
                "surface": isPlaybackSurface,
                "canNavigate": canNavigateVideos
            ]
        )
        guard canNavigateVideos else { return }

        if context.focusHeading.contains(.up) {
            // 播放画面上的第一次上键应交给原生播放器显示控制栏；只有焦点
            // 已经处于控制栏最上方时，再按上才切换上一条。
            guard !isPlaybackSurface else { return }
            performNavigation(.previous)
        } else if context.focusHeading.contains(.down) {
            performNavigation(.next)
        }
    }

    private func performNavigation(_ direction: NavigationDirection) {
        let event: String
        switch direction {
        case .previous: event = "navigate-previous"
        case .next: event = "navigate-next"
        }
        PlaybackDiagnostics.shared.event(
            event,
            category: "controller",
            fields: ["controller": diagnosticsID, "focusStayed": true]
        )
        lockNavigationBriefly()
        switch direction {
        case .previous: onPrevious?()
        case .next: onNext?()
        }
    }

    private func lockNavigationBriefly() {
        navigationLocked = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.navigationLocked = false
        }
    }

    private var canNavigateVideos: Bool {
        guard !navigationLocked, let player else { return false }
        // 暂停或当前媒体仍在加载时都允许继续切换。慢直播不能把用户锁在
        // 黑屏里；新请求会通过 generation 取消旧请求并只接管最后一次选择。
        return player.currentItem != nil || allowsNavigationWhileStopped
    }

    private func isInsidePlayer(_ focusedView: UIView) -> Bool {
        return focusedView === playbackController.view
            || focusedView.isDescendant(of: playbackController.view)
    }

    private func isPlayerSurface(_ focusedView: UIView) -> Bool {
        let frame = focusedView.convert(focusedView.bounds, to: playbackController.view)
        let playerBounds = playbackController.view.bounds
        guard playerBounds.width > 0, playerBounds.height > 0 else { return false }
        return frame.width >= playerBounds.width * 0.75
            && frame.height >= playerBounds.height * 0.5
    }
}

struct NativePlayerController: UIViewControllerRepresentable {
    let controller: DouyinPlayerContainerViewController
    let isTransitioning: Bool
    let allowsNavigationWhileStopped: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onRefresh: (() -> Void)?
    let authorName: String?
    let onShowAuthor: (() -> Void)?
    let isLive: Bool
    let danmakuAvailable: Bool
    let qualityOptions: [PlaybackQualityOption]
    let selectedQualityID: String
    let onSelectQuality: (String) -> Void
    let onVisible: () -> Void

    func makeUIViewController(context: Context) -> DouyinPlayerContainerViewController {
        configure(controller)
        return controller
    }

    func updateUIViewController(_ controller: DouyinPlayerContainerViewController, context: Context) {
        configure(controller)
    }

    private func configure(_ controller: DouyinPlayerContainerViewController) {
        controller.onPrevious = onPrevious
        controller.onNext = onNext
        controller.onRefresh = onRefresh
        controller.onVisible = onVisible
        controller.configureAuthorAction(
            name: authorName,
            action: onShowAuthor,
            isLive: isLive,
            danmakuAvailable: danmakuAvailable,
            qualityOptions: qualityOptions,
            selectedQualityID: selectedQualityID,
            onSelectQuality: onSelectQuality
        )
        controller.isTransitioning = isTransitioning
        controller.allowsNavigationWhileStopped = allowsNavigationWhileStopped
    }

    static func dismantleUIViewController(
        _ controller: DouyinPlayerContainerViewController,
        coordinator: ()
    ) {
        controller.onPrevious = nil
        controller.onNext = nil
        controller.onRefresh = nil
        controller.onShowAuthor = nil
        controller.onSelectQuality = nil
        controller.onVisible = nil
        controller.transportBarCustomMenuItems = []
        controller.danmakuController.stop()
        PlaybackDiagnostics.shared.event(
            "dismantle",
            category: "controller",
            fields: [
                "controller": controller.diagnosticsID,
                "hasPlayer": controller.player != nil
            ]
        )
    }
}
