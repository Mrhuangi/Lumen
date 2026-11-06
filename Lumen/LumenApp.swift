import SwiftUI
import UIKit

/// 方向锁：平时锁竖屏，进播放器后解锁，横屏视频自动转横屏全屏。
/// 1.3 起方向的唯一权威是播放页的呈现控制器（PlayerHostingController），
/// 这里的全局锁只作兜底：非播放页锁竖屏，播放期间放行到与呈现控制器一致。
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // 字幕字体（随包 Noto Sans CJK SC）在后台先装好，播放器初始化时只做兜底校验
        SubtitleFontInstaller.installAllInBackground()
        return true
    }
}

@main
struct LumenApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - 播放方向上下文（模型判定 → 呈现控制器消费）

/// 播放会话的方向裁决通道：PlaybackFlow 把当前视频的横竖判定写进来，
/// PlayerHostingController 据此动态返回支持方向；判定变化时通知控制器重新评估。
final class PlaybackOrientationContext {
    var aspectLandscape: Bool? {
        didSet {
            guard oldValue != aspectLandscape else { return }
            onAspectChanged?()
        }
    }
    var onAspectChanged: (() -> Void)?
}

// MARK: - 播放页呈现控制器（方向权威）

/// 承载 PlaybackFlow 的托管控制器：覆写方向属性，模态全屏呈现本身即按
/// preferredInterfaceOrientationForPresentation 旋转，不依赖 SwiftUI 边沿事件。
/// 切集等呈现后才到达的判定变化，由 OrientationHelper 的 geometry 请求补位。
final class PlayerHostingController: UIHostingController<PlaybackFlow> {
    let orientationContext: PlaybackOrientationContext
    var onDismissed: (() -> Void)?

    init(rootView: PlaybackFlow, orientationContext: PlaybackOrientationContext) {
        self.orientationContext = orientationContext
        super.init(rootView: rootView)
        modalPresentationStyle = .fullScreen
        orientationContext.onAspectChanged = { [weak self] in
            self?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        switch orientationContext.aspectLandscape {
        case true: return .allButUpsideDown
        case false: return .portrait
        case nil: return .allButUpsideDown
        }
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        orientationContext.aspectLandscape == true ? .landscapeRight : .portrait
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed { onDismissed?() }
    }
}

// MARK: - 播放页呈现桥（替代 .fullScreenCover，使呈现控制器可定制）

/// 用 UIKit 呈现 PlayerHostingController 承载 PlaybackFlow；
/// 关闭（界面内 dismiss 或绑定清空）后把绑定同步回 nil。
private struct PlayerCoverPresenter: UIViewControllerRepresentable {
    @Binding var item: MediaItem?
    let makeContent: (MediaItem, PlaybackOrientationContext) -> PlaybackFlow

    final class Coordinator {
        var presentedID: UUID?
        var hosting: PlayerHostingController?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ anchor: UIViewController, context: Context) {
        let coordinator = context.coordinator
        if let current = item {
            guard coordinator.presentedID != current.id else { return }
            coordinator.presentedID = current.id
            let orientation = PlaybackOrientationContext()
            let host = PlayerHostingController(rootView: makeContent(current, orientation),
                                               orientationContext: orientation)
            coordinator.hosting = host
            let binding = $item
            let presentedID = current.id
            host.onDismissed = {
                DispatchQueue.main.async {
                    if binding.wrappedValue?.id == presentedID {
                        binding.wrappedValue = nil
                    }
                }
            }
            DispatchQueue.main.async {
                guard let presenter = Self.topPresenter(from: anchor) else { return }
                presenter.present(host, animated: true)
            }
        } else if coordinator.presentedID != nil {
            coordinator.presentedID = nil
            let host = coordinator.hosting
            coordinator.hosting = nil
            DispatchQueue.main.async { host?.dismiss(animated: true) }
        }
    }

    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: Coordinator) {
        coordinator.hosting?.dismiss(animated: false)
        coordinator.hosting = nil
        coordinator.presentedID = nil
    }

    private static func topPresenter(from anchor: UIViewController) -> UIViewController? {
        var top = anchor.view.window?.rootViewController
        if top == nil {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let windows = scenes.flatMap { $0.windows }
            top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
        }
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

extension View {
    /// 播放页全屏呈现（呈现控制器持有方向权威），用法与 fullScreenCover(item:) 等价
    func playerCover(item: Binding<MediaItem?>,
                     content: @escaping (MediaItem, PlaybackOrientationContext) -> PlaybackFlow) -> some View {
        background(PlayerCoverPresenter(item: item, makeContent: content))
    }
}

/// 方向控制：改锁后通知系统重新评估，并可直接请求转到目标方向。
/// 1.3 纪律（据 landscape 调研）：请求一律带 errorHandler 并写 AppLog，不再静默；
/// setNeeds 同时打根控制器与顶层呈现控制器，且严格先于 geometry 请求；
/// 横屏请求发出后 0.5 秒回读实际方向，未落定则重发一次。
@MainActor
enum OrientationHelper {
    static func unlockForPlayback() {
        AppDelegate.orientationLock = .allButUpsideDown
        refresh()
    }

    static func lockToPortrait() {
        AppDelegate.orientationLock = .portrait
        request(.portrait, verify: false)
    }

    static func requestLandscape() {
        request(.landscape, verify: true)
    }

    /// 电平触发的当前裁决（每次判定到达/页面出现都可重复调用，结论一致）：
    /// 横屏视频 → 放行并请求横屏；竖屏视频 → 锁收回竖屏；未判定 → 仅放行等判定
    static func setPlaybackAspect(_ isLandscape: Bool?) {
        switch isLandscape {
        case true:
            AppDelegate.orientationLock = .allButUpsideDown
            request(.landscape, verify: true)
        case false:
            AppDelegate.orientationLock = .portrait
            request(.portrait, verify: false)
        case nil:
            AppDelegate.orientationLock = .allButUpsideDown
            refresh()
        }
    }

    private static var verifyRetryPending = false

    private static func request(_ mask: UIInterfaceOrientationMask, verify: Bool) {
        refresh()
        guard let scene = activeScene() else { return }
        let before = scene.interfaceOrientation
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            AppLog.add("播放", "方向请求被系统拒绝（请求前方向 \(before.rawValue)）：\(error.localizedDescription)")
        }
        refresh()
        if verify { scheduleVerify(mask: mask) }
    }

    /// 请求后 0.5 秒回读：转场/评估竞态下请求可能被静默忽略，未落定则重发一次（仅一次）
    private static func scheduleVerify(mask: UIInterfaceOrientationMask) {
        guard !verifyRetryPending else { return }
        verifyRetryPending = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            verifyRetryPending = false
            guard let scene = activeScene() else { return }
            let current = scene.interfaceOrientation
            guard current != .unknown else { return }
            let currentMask = UIInterfaceOrientationMask(rawValue: UInt(1 << current.rawValue))
            if !mask.contains(currentMask) {
                AppLog.add("播放", "方向请求 0.5 秒后仍未落定（当前 \(current.rawValue)），重发一次")
                request(mask, verify: false)
            }
        }
    }

    private static func refresh() {
        let top = topViewController()
        top?.setNeedsUpdateOfSupportedInterfaceOrientations()
        let root = activeScene()?.keyWindow?.rootViewController
        if let root, root !== top {
            root.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }

    private static func activeScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    private static func topViewController() -> UIViewController? {
        var top = activeScene()?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
