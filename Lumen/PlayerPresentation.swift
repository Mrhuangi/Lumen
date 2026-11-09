import SwiftUI
import UIKit

/// 播放页呈现控制器：方向的最终裁决权在「呈现出来的视图控制器」手里——
/// 支持方向掩码与系统方向锁定（prefersInterfaceOrientationLocked）都由它
/// 直接向系统声明，播放页的方向行为完全走系统原生通道，
/// 不再靠应用级掩码间接猜测（1.5.4 真机实证：旧锁定按了没反应）。
final class PlayerHostingController: UIHostingController<PlaybackFlow> {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }

    override var prefersInterfaceOrientationLocked: Bool {
        AppDelegate.playerOrientationLocked
    }

    /// 被自身内容关闭（关闭键走 SwiftUI 的 dismiss）后回调一次，
    /// 让呈现方把条目绑定同步回未呈现状态。
    var onDismissedByContent: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed {
            onDismissedByContent?()
        }
    }
}

/// 播放页呈现（替代 .fullScreenCover）：用 UIKit 把 PlaybackFlow 装进
/// PlayerHostingController 全屏呈现，调用方式与 fullScreenCover(item:) 一致。
struct PlayerCover<Item: Identifiable>: UIViewControllerRepresentable {
    @Binding var item: Item?
    let content: (Item) -> PlaybackFlow

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let anchor = UIViewController()
        anchor.view.backgroundColor = .clear
        return anchor
    }

    func updateUIViewController(_ anchor: UIViewController, context: Context) {
        let coordinator = context.coordinator
        if let item {
            if let presented = coordinator.presented {
                // 已呈现同一条目无需动作；换条目时直接换根视图
                if coordinator.presentedItemID != item.id {
                    presented.rootView = content(item)
                    coordinator.presentedItemID = item.id
                }
            } else {
                coordinator.present(item: item, content: content, from: anchor, binding: $item)
            }
        } else if let presented = coordinator.presented {
            coordinator.presented = nil
            coordinator.presentedItemID = nil
            presented.dismiss(animated: true)
        }
    }

    final class Coordinator {
        var presented: PlayerHostingController?
        var presentedItemID: Item.ID?
        private var attempts = 0

        func present(item: Item, content: (Item) -> PlaybackFlow,
                     from anchor: UIViewController, binding: Binding<Item?>) {
            guard presented == nil else { return }
            guard anchor.view.window != nil else {
                // 锚点还没进窗口（刚点开或自动播放与呈现同帧）：稍后重试几次
                attempts += 1
                guard attempts <= 8 else { attempts = 0; return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak anchor] in
                    guard let self, let anchor, self.presented == nil,
                          binding.wrappedValue != nil else { return }
                    self.present(item: item, content: content, from: anchor, binding: binding)
                }
                return
            }
            attempts = 0
            let hosting = PlayerHostingController(rootView: content(item))
            hosting.modalPresentationStyle = .fullScreen
            presented = hosting
            presentedItemID = item.id
            hosting.onDismissedByContent = { [weak self] in
                guard let self else { return }
                self.presented = nil
                self.presentedItemID = nil
                if binding.wrappedValue != nil {
                    DispatchQueue.main.async { binding.wrappedValue = nil }
                }
            }
            DispatchQueue.main.async { [weak self, weak anchor] in
                guard let self, let anchor, self.presented === hosting,
                      binding.wrappedValue != nil else { return }
                anchor.present(hosting, animated: true)
            }
        }
    }
}

extension View {
    /// 播放页全屏呈现：与 .fullScreenCover(item:) 同形替换，
    /// 呈现出的控制器带系统原生方向声明（见 PlayerHostingController）。
    func playerCover<Item: Identifiable>(item: Binding<Item?>,
                                         content: @escaping (Item) -> PlaybackFlow) -> some View {
        background(PlayerCover(item: item, content: content))
    }
}
