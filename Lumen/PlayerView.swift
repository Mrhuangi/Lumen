import AVKit
import SwiftUI
import UIKit

/// AVPlayerViewController 包装：使用系统播放界面
/// 系统界面自带：字幕/音轨选择、播放速度、画中画按钮、AirPlay
/// 外挂字幕通过 contentOverlayView 上的标签叠加显示（系统界面没有外挂字幕通道）
struct PlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    var subtitleText: String = ""

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.videoGravity = .resizeAspect

        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.textColor = .white
        label.shadowColor = UIColor.black.withAlphaComponent(0.9)
        label.shadowOffset = CGSize(width: 0, height: 1)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        label.layer.cornerRadius = 6
        label.layer.masksToBounds = true
        label.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false
        if let overlay = controller.contentOverlayView {
            overlay.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                label.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -52),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 32),
                label.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -32)
            ])
        }
        context.coordinator.label = label
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
        // 「退出时自动画中画」设置（默认开）
        let autoPiP = UserDefaults.standard.object(forKey: "settings.autoPiP") as? Bool != false
        controller.canStartPictureInPictureAutomaticallyFromInline = autoPiP
        let label = context.coordinator.label
        label?.text = subtitleText.isEmpty ? nil : " \(subtitleText) "
        label?.isHidden = subtitleText.isEmpty
        // 外挂字幕字号跟随设置（默认 17）
        let size = UserDefaults.standard.object(forKey: "settings.subFontSize") as? Double ?? 17
        if let label, label.font.pointSize != CGFloat(size) {
            label.font = .systemFont(ofSize: CGFloat(size), weight: .semibold)
        }
    }

    final class Coordinator {
        weak var label: UILabel?
    }
}
