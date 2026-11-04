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

    func updateUIViewController(_ controller: MPVMetalViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: MPVMetalViewController, coordinator: ()) {
        controller.teardownPlayer()
    }
}
