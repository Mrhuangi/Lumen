import SwiftUI
import UIKit

/// 方向锁：平时锁竖屏，进播放器后解锁，横屏视频自动转横屏全屏。
/// 1.4 起播放页回到系统 .fullScreenCover 呈现，方向只由 OrientationHelper
/// 的 geometry 请求与这里的全局锁驱动：非播放页锁竖屏，播放期间按判定放行。
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

// MARK: - 播放方向上下文（保留作参数兼容）

/// 播放会话的方向裁决通道：PlaybackFlow 把当前视频的横竖判定写进来。
/// 1.4 起呈现层不再消费此上下文，PlaybackFlow 的参数仅保留兼容、写入无副作用；
/// 方向改由 OrientationHelper 的 geometry 请求＋AppDelegate 全局锁驱动。
final class PlaybackOrientationContext {
    var aspectLandscape: Bool? {
        didSet {
            guard oldValue != aspectLandscape else { return }
            onAspectChanged?()
        }
    }
    var onAspectChanged: (() -> Void)?
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
        let verdict = isLandscape.map { $0 ? "横屏" : "竖屏" } ?? "未判定"
        let before = activeScene()?.interfaceOrientation.rawValue ?? -1
        AppLog.add("播放", "方向裁决 \(verdict)（请求前界面方向 \(before)）")
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
