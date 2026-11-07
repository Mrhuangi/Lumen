import AVKit
import SwiftUI
import UIKit

/// AVPlayerViewController 包装：使用系统播放界面
/// 系统界面自带：字幕/音轨选择、播放速度、画中画按钮、AirPlay
/// 外挂字幕通过 contentOverlayView 上的标签叠加显示（系统界面没有外挂字幕通道）
struct PlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    var subtitleText: String = ""
    /// 副字幕（双字幕的第二条）：叠加在主字幕上方一行显示
    var secondarySubtitleText: String = ""

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// 与 MPVPlayerView 同规：尺寸跟随提议实时更新，避免旋转后视图帧停留在旧尺寸
    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiViewController: AVPlayerViewController,
                      context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.videoGravity = .resizeAspect

        func makeSubtitleLabel() -> UILabel {
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
            return label
        }
        let label = makeSubtitleLabel()
        let secondaryLabel = makeSubtitleLabel()
        secondaryLabel.alpha = 0.92
        if let overlay = controller.contentOverlayView {
            overlay.addSubview(label)
            overlay.addSubview(secondaryLabel)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                label.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -52),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 32),
                label.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -32),
                secondaryLabel.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                secondaryLabel.bottomAnchor.constraint(equalTo: label.topAnchor, constant: -6),
                secondaryLabel.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 32),
                secondaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -32)
            ])
        }
        context.coordinator.label = label
        context.coordinator.secondaryLabel = secondaryLabel
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
        let secondaryLabel = context.coordinator.secondaryLabel
        secondaryLabel?.text = secondarySubtitleText.isEmpty ? nil : " \(secondarySubtitleText) "
        secondaryLabel?.isHidden = secondarySubtitleText.isEmpty
        // 叠加字幕字号跟随设置（默认 17，主副同号）
        let size = UserDefaults.standard.object(forKey: "settings.subFontSize") as? Double ?? 17
        if let label, label.font.pointSize != CGFloat(size) {
            label.font = .systemFont(ofSize: CGFloat(size), weight: .semibold)
        }
        if let secondaryLabel, secondaryLabel.font.pointSize != CGFloat(size) {
            secondaryLabel.font = .systemFont(ofSize: CGFloat(size), weight: .semibold)
        }
    }

    final class Coordinator {
        weak var label: UILabel?
        weak var secondaryLabel: UILabel?
    }
}
