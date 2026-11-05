import AVFoundation
import Foundation

/// 播放核心：加载、续播位置记忆、格式徽章（高动态范围 / HDR / 编码）识别
@MainActor
final class PlayerModel: ObservableObject {
    let player = AVPlayer()

    @Published var title: String = ""
    @Published var formatBadge: String = ""
    @Published var errorMessage: String?
    /// 视频是否为横屏（nil = 还没读到尺寸），播放器据此自动转横屏全屏
    @Published var videoIsLandscape: Bool?

    // 外挂字幕（叠加显示）：主字幕条目 + 当前时刻应显示的文本
    @Published private(set) var externalCues: [SubtitleCue] = []
    @Published var currentSubtitleText: String = ""
    // 副字幕（双字幕的第二条，叠加在主字幕上方一行）
    @Published private(set) var secondaryCues: [SubtitleCue] = []
    @Published var currentSecondarySubtitleText: String = ""

    /// 是否暂停（由 timeControlStatus 同步，供外壳统一控件显隐判断）
    @Published private(set) var isPaused = true
    /// 片尾窗口已到达（界面据此显示「跳过片尾」按钮）
    @Published private(set) var outroPromptVisible = false

    private var timeObserver: Any?
    private var currentKey: String = ""
    private var didSeekToResume = false
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var outroFired = false

    /// 播放结束回调（用于自动连播下一集）
    var onPlaybackEnded: (() -> Void)?
    /// 到达片尾窗口且存在下一集时的回调（由播放流程决定是否切集）
    var onOutroReached: (() -> Void)?
    /// 用户点「跳过片尾」按钮的回调（明确意图，播放流程直接切集，不受自动连播开关约束）
    var onSkipOutroRequested: (() -> Void)?
    /// 是否存在可切的下一集（播放流程设置）
    var outroAdvanceAvailable = false

    init() {
        // 允许画中画 / 后台继续播放（需配合 Info.plist 的 UIBackgroundModes=audio 与音频会话）
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        rateObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let paused = player.timeControlStatus != .playing
            Task { @MainActor in self?.isPaused = paused }
        }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self, !self.currentKey.isEmpty else { return }
            let seconds = time.seconds
            if seconds.isFinite, seconds > 3 {
                let duration = self.player.currentItem?.duration.seconds ?? 0
                ResumeStore.save(key: self.currentKey, seconds: seconds,
                                 duration: duration.isFinite ? duration : 0)
            }
            if seconds.isFinite {
                self.updateCurrentSubtitle(at: seconds)
                self.checkOutro(at: seconds)
            }
            // 记住播放速度（用户在系统界面改了倍速就存下来，下次自动沿用）
            let rate = Double(self.player.rate)
            if rate > 0 {
                UserDefaults.standard.set(rate, forKey: "player.lastRate")
            }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    func load(url: URL, title: String, resumeKey: String = "") {
        self.title = title
        currentKey = resumeKey
        didSeekToResume = false
        formatBadge = ""
        errorMessage = nil
        videoIsLandscape = nil
        outroPromptVisible = false
        outroFired = false
        isPaused = true

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)

        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.onPlaybackEnded?() }
        }

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor in
                switch item.status {
                case .readyToPlay:
                    self.detectFormat(asset: asset)
                    self.detectOrientation(asset: asset)
                    self.resumeIfNeeded(item: item)
                    self.skipIntroIfNeeded(item: item)
                    if let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
                        if !self.externalCues.isEmpty {
                            item.select(nil, in: group) // 有外挂字幕时不叠内封字幕
                        } else if let zh = group.options.first(where: { option in
                            let tag = (option.extendedLanguageTag ?? "").lowercased()
                            return tag.hasPrefix("zh") || tag.hasPrefix("cmn") || tag.hasPrefix("yue")
                                || tag == "chi" || tag == "zho"
                                || option.displayName.contains("中文")
                                || option.displayName.contains("Chinese")
                        }) {
                            // 有内封中文字幕就默认选上；用户可在系统播放菜单里换轨或关闭
                            item.select(zh, in: group)
                            AppLog.add("播放", "已默认选中内封字幕：\(zh.displayName)")
                        }
                    }
                    self.player.play()
                    // 沿用上次的播放速度（设置里可关）
                    if UserDefaults.standard.object(forKey: "settings.rememberRate") as? Bool != false,
                       let saved = UserDefaults.standard.object(forKey: "player.lastRate") as? Double,
                       saved > 0, abs(saved - 1.0) > 0.01 {
                        self.player.rate = Float(saved)
                    }
                case .failed:
                    self.errorMessage = item.error?.localizedDescription
                        ?? String(localized: "无法播放这个文件")
                default:
                    break
                }
            }
        }
    }

    /// 跳过片头：续播定位后若仍落在片头范围内，直接跳到片头结束（与直读路同一策略）
    private func skipIntroIfNeeded(item: AVPlayerItem) {
        guard PlayerSettings.skipIntroOutro else { return }
        let intro = PlayerSettings.introSeconds
        let duration = item.duration.seconds
        guard intro > 0, duration.isFinite,
              duration > intro + PlayerSettings.outroSeconds + 30 else { return }
        // 续播 seek 是异步的，稍等一拍再读实际位置决定是否跳
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            let pos = self.player.currentTime().seconds
            if pos.isFinite, pos < intro {
                self.player.seek(to: CMTime(seconds: intro, preferredTimescale: 600),
                                 toleranceBefore: .zero, toleranceAfter: .zero)
                AppLog.add("播放", "已跳过片头（\(Int(intro)) 秒）")
            }
        }
    }

    /// 片尾窗口检测：进入窗口显示跳过按钮；有下一集时自动切集一次
    private func checkOutro(at seconds: Double) {
        guard PlayerSettings.skipIntroOutro else {
            if outroPromptVisible { outroPromptVisible = false }
            return
        }
        let outro = PlayerSettings.outroSeconds
        let duration = player.currentItem?.duration.seconds ?? 0
        guard outro > 0, duration.isFinite, duration > 0 else { return }
        if duration - seconds <= outro, seconds > 3 {
            outroPromptVisible = true
            if outroAdvanceAvailable, !outroFired {
                outroFired = true
                onOutroReached?()
            }
        } else if outroPromptVisible, duration - seconds > outro + 5 {
            outroPromptVisible = false
        }
    }

    /// 「跳过片尾」按钮：有下一集则切集，否则跳到结尾
    func skipOutro() {
        outroPromptVisible = false
        if outroAdvanceAvailable {
            outroFired = true
            (onSkipOutroRequested ?? onOutroReached)?()
        } else {
            let duration = player.currentItem?.duration.seconds ?? 0
            if duration.isFinite, duration > 0 {
                player.seek(to: CMTime(seconds: max(duration - 0.5, 0), preferredTimescale: 600))
            }
        }
    }

    private func resumeIfNeeded(item: AVPlayerItem) {
        guard !didSeekToResume else { return }
        didSeekToResume = true
        // 设置里关掉「自动续播」时不跳转
        if UserDefaults.standard.object(forKey: "settings.autoResume") as? Bool == false { return }
        let saved = ResumeStore.position(forKey: currentKey) ?? 0
        guard saved > 3 else { return }
        let duration = item.duration.seconds
        if duration.isFinite, saved < duration - 10 {
            player.seek(to: CMTime(seconds: saved, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    /// 读视频轨的实际显示尺寸（应用旋转矩阵后），判断横屏还是竖屏
    private func detectOrientation(asset: AVAsset) {
        Task {
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let size = try? await track.load(.naturalSize),
                  let transform = try? await track.load(.preferredTransform) else { return }
            let rect = CGRect(origin: .zero, size: size).applying(transform)
            self.videoIsLandscape = abs(rect.width) > abs(rect.height)
        }
    }

    /// 读视频轨的编码子类型，给界面显示一个格式徽章
    private func detectFormat(asset: AVAsset) {
        Task {
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let descriptions = try? await track.load(.formatDescriptions),
                  let description = descriptions.first else { return }
            let subtype = CMFormatDescriptionGetMediaSubType(description)
            let code = Self.fourCC(subtype)
            let badge: String
            switch code {
            case "dvh1", "dvhe", "dvh5", "dvvt": // 高动态范围（动态元数据）常见子类型
                badge = String(localized: "高动态范围")
            case "hvc1", "hev1":
                badge = "HEVC"
            case "avc1":
                badge = "H.264"
            default:
                badge = code
            }
            self.formatBadge = badge
        }
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusObservation = nil
    }

    // MARK: - 叠加字幕（主＋副双字幕）

    /// 设置叠加字幕（主/副两条）：来源是外挂文件或重封装提取的内封字幕 cues。
    /// 任一条非空时关掉系统内封字幕的默认选中，避免与叠加层重叠。
    func setOverlaySubtitles(primary: [SubtitleCue], secondary: [SubtitleCue]) {
        externalCues = primary
        secondaryCues = secondary
        currentSubtitleText = ""
        currentSecondarySubtitleText = ""
        guard !primary.isEmpty || !secondary.isEmpty,
              let item = player.currentItem,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else { return }
        item.select(nil, in: group)
    }

    private func updateCurrentSubtitle(at seconds: Double) {
        let primary = Self.cueText(in: externalCues, at: seconds)
        if primary != currentSubtitleText { currentSubtitleText = primary }
        let secondary = Self.cueText(in: secondaryCues, at: seconds)
        if secondary != currentSecondarySubtitleText { currentSecondarySubtitleText = secondary }
    }

    /// 条目按开始时间排序，做一次线性扫描（0.5 秒一跳，量级足够）
    private static func cueText(in cues: [SubtitleCue], at seconds: Double) -> String {
        guard !cues.isEmpty else { return "" }
        for cue in cues {
            if seconds < cue.start { break }
            if seconds >= cue.start && seconds < cue.end { return cue.text }
        }
        return ""
    }
}
