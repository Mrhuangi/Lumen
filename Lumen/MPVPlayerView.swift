import SwiftUI
import UIKit

/// mpv 播放视图包装：承载 MPVMetalViewController（Metal 渲染层），
/// 播放控制由 MPVPlayerModel 驱动、自建控制层 MPVControlsView 呈现。
struct MPVPlayerView: UIViewControllerRepresentable {
    @ObservedObject var model: MPVPlayerModel

    func makeUIViewController(context: Context) -> MPVMetalViewController {
        let controller = MPVMetalViewController()
        model.attach(controller)
        return controller
    }

    /// 尺寸必须跟随 SwiftUI 的提议（即全屏区域）实时更新：
    /// UIViewControllerRepresentable 的默认尺寸回报是控制器视图的当前尺寸，
    /// 播放页以竖屏打开时回报竖屏尺寸、旋转后不再变化，视频便被锁在
    /// 竖屏区域里挤成窄条（1.2.1 起横屏窄条的根因，与呈现方式无关）。
    /// 显式返回提议尺寸后，视图帧随每次布局（含旋转）刷新到全屏。
    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiViewController: MPVMetalViewController,
                      context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    func updateUIViewController(_ controller: MPVMetalViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: MPVMetalViewController, coordinator: ()) {
        controller.teardownPlayer()
    }
}
