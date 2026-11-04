import SwiftUI
import UIKit

/// 方向锁：平时锁竖屏，进播放器后解锁，横屏视频自动转横屏全屏
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
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

/// 方向控制：改锁后通知系统重新评估，并可直接请求转到目标方向
@MainActor
enum OrientationHelper {
    static func unlockForPlayback() {
        AppDelegate.orientationLock = .allButUpsideDown
        refresh()
    }

    static func lockToPortrait() {
        AppDelegate.orientationLock = .portrait
        request(.portrait)
    }

    static func requestLandscape() {
        request(.landscape)
    }

    private static func refresh() {
        topViewController()?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    private static func request(_ mask: UIInterfaceOrientationMask) {
        refresh()
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        topViewController()?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
