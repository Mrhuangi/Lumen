import AVFoundation
import Foundation

/// 一条 mpv 轨道（音轨/字幕轨菜单用）
struct MPVTrack: Identifiable, Equatable {
    let id: Int
    let type: String
    let lang: String?
    let title: String?
    let codec: String?
    let isExternal: Bool

    /// 菜单显示名：语言译名优先，其次轨道标题，最后回退到轨道号
    var displayName: String {
        var parts: [String] = []
        if let label = Self.languageLabel(lang) { parts.append(label) }
        if let title, !title.isEmpty, title != lang { parts.append(title) }
        if parts.isEmpty { parts.append("轨道 \(id)") }
        if isExternal { parts.append("外挂") }
        return parts.joined(separator: " · ")
    }

    static func languageLabel(_ lang: String?) -> String? {
        guard let raw = lang?.lowercased(), !raw.isEmpty else { return nil }
        if raw.hasPrefix("zh") || raw.hasPrefix("cmn") || raw.hasPrefix("yue")
            || raw == "chi" || raw == "zho" { return "中文" }
        if raw.hasPrefix("ja") || raw == "jpn" { return "日语" }
        if raw.hasPrefix("en") || raw == "eng" { return "英语" }
        if raw.hasPrefix("ko") || raw == "kor" { return "韩语" }
        if raw == "und" { return nil }
        return raw.uppercased()
    }

    /// 是否中文轨（默认字幕选择策略，与系统播放器路径保持一致）
    var isChinese: Bool {
        if let lang {
            let l = lang.lowercased()
            if l.hasPrefix("zh") || l.hasPrefix("cmn") || l.hasPrefix("yue")
                || l == "chi" || l == "zho" { return true }
        }
        if let title {
            return title.contains("中文") || title.contains("Chinese")
                || title.contains("简体") || title.contains("繁体") || title.contains("国语")
        }
        return false
    }

    /// 简体优先排序分（默认选中时用）
    var chinesePreferenceScore: Int {
        guard isChinese else { return 0 }
        var score = 10
        if let title {
            if title.contains("简体") || title.contains("简中") || title.uppercased().contains("CHS") { score += 3 }
            if title.contains("繁体") || title.contains("繁中") || title.uppercased().contains("CHT") { score += 2 }
        }
        return score
    }
}

/// mpv 播放适配层（兼容/兜底引擎）：对外接口与 PlayerModel 同形——
/// load / 续播写入 ResumeStore / 倍速记忆 player.lastRate / 结束回调 / 横竖屏信号 / 错误上报。
@MainActor
final class MPVPlayerModel: ObservableObject {
    @Published var title: String = ""
    @Published var errorMessage: String?
    @Published var videoIsLandscape: Bool?

    @Published private(set) var isPaused = true
    @Published private(set) var isBuffering = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var audioTracks: [MPVTrack] = []
    @Published private(set) var subtitleTracks: [MPVTrack] = []
    @Published private(set) var selectedAudioID: Int?
    @Published private(set) var selectedSubtitleID: Int?
    @Published private(set) var rate: Double = 1.0
    /// 快进/快退提示（控制层据此闪现 gobackward.10 / goforward.10 指示）
    @Published private(set) var seekFlash: (forward: Bool, counter: Int)?

    /// 播放结束回调（用于自动连播下一集）
    var onPlaybackEnded: (() -> Void)?

    private weak var controller: MPVMetalViewController?
    private var currentKey = ""
    private var pendingExternalSubtitle: URL?
    private var fileLoaded = false
    private var endFired = false
    private var lastSavedSecond = -1
    private var lastPublishedPosition = -1.0
    private var seekFlashCounter = 0

    init() {
        // mpv 不管理 iOS 音频会话，由 App 侧统一设置（与系统播放路径一致）
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    // MARK: - 装配与加载

    func attach(_ vc: MPVMetalViewController) {
        controller = vc
        vc.playDelegate = self
    }

    func load(url: URL, title: String, resumeKey: String = "", externalSubtitleURL: URL? = nil) {
        self.title = title
        currentKey = resumeKey
        errorMessage = nil
        videoIsLandscape = nil
        isBuffering = false
        position = 0
        duration = 0
        audioTracks = []
        subtitleTracks = []
        selectedAudioID = nil
        selectedSubtitleID = nil
        fileLoaded = false
        endFired = false
        lastSavedSecond = -1
        lastPublishedPosition = -1
        pendingExternalSubtitle = externalSubtitleURL

        // 自动续播：与系统播放路径同一策略（设置关闭或不足片段尾部时不跳）
        var startAt: Double?
        if UserDefaults.standard.object(forKey: "settings.autoResume") as? Bool != false {
            let saved = ResumeStore.position(forKey: resumeKey) ?? 0
            if saved > 3 { startAt = saved }
        }
        controller?.loadFile(url, startAt: startAt)
    }

    func stop() {
        saveResume(force: true)
        controller?.stopPlayback()
    }

    // MARK: - 控制（控制层调用）

    func togglePlayPause() { controller?.togglePause() }
    func play() { controller?.play() }
    func pause() { controller?.pause() }

    func seek(to seconds: Double) {
        controller?.seekAbsolute(seconds)
        position = seconds
        lastPublishedPosition = seconds
    }

    func seekBy(_ delta: Double) {
        controller?.seekRelative(delta)
        seekFlashCounter += 1
        seekFlash = (forward: delta >= 0, counter: seekFlashCounter)
    }

    func setRate(_ newRate: Double) {
        rate = newRate
        controller?.setRate(newRate)
        if UserDefaults.standard.object(forKey: "settings.rememberRate") as? Bool != false {
            UserDefaults.standard.set(newRate, forKey: "player.lastRate")
        }
    }

    func selectAudioTrack(_ id: Int) {
        selectedAudioID = id
        controller?.setAudioTrack(id)
    }

    func selectSubtitleTrack(_ id: Int?) {
        selectedSubtitleID = id
        controller?.setSubtitleTrack(id)
    }

    // MARK: - 续播

    private func saveResume(force: Bool = false) {
        guard !currentKey.isEmpty, duration > 0 else { return }
        let second = Int(position)
        guard force || second != lastSavedSecond else { return }
        lastSavedSecond = second
        if position > 3 {
            ResumeStore.save(key: currentKey, seconds: position, duration: duration)
        }
    }

    // MARK: - 文件加载后的默认策略

    private func handleFileLoaded() {
        fileLoaded = true
        guard let vc = controller else { return }

        let w = vc.getDouble(MPVProperty.width)
        let h = vc.getDouble(MPVProperty.height)
        if w > 0, h > 0 { videoIsLandscape = w > h }
        let d = vc.getDouble(MPVProperty.duration)
        if d > 0 { duration = d }

        refreshTracks()

        // 沿用上次倍速（设置可关），与系统播放路径一致
        if UserDefaults.standard.object(forKey: "settings.rememberRate") as? Bool != false,
           let saved = UserDefaults.standard.object(forKey: "player.lastRate") as? Double,
           saved > 0, abs(saved - 1.0) > 0.01 {
            rate = saved
            vc.setRate(saved)
        }

        // 外挂字幕优先：挂上并启用；否则默认选内封中文字幕（与系统播放路径同一策略）
        if let external = pendingExternalSubtitle {
            vc.addExternalSubtitle(external)
            AppLog.add("播放", "兼容播放已加载外挂字幕：\(external.lastPathComponent)")
            // sub-add 是异步命令，稍后刷新轨道列表以反映外挂轨的选中状态
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.refreshTracks()
            }
        } else if let zh = subtitleTracks.filter(\.isChinese)
            .max(by: { $0.chinesePreferenceScore < $1.chinesePreferenceScore }) {
            selectSubtitleTrack(zh.id)
            AppLog.add("播放", "兼容播放已默认选中内封字幕：\(zh.displayName)")
        }
    }

    private func refreshTracks() {
        guard let vc = controller else { return }
        let raw = vc.readTracks()
        audioTracks = raw.filter { $0.type == "audio" }.map {
            MPVTrack(id: $0.id, type: $0.type, lang: $0.lang, title: $0.title,
                     codec: $0.codec, isExternal: $0.isExternal)
        }
        subtitleTracks = raw.filter { $0.type == "sub" }.map {
            MPVTrack(id: $0.id, type: $0.type, lang: $0.lang, title: $0.title,
                     codec: $0.codec, isExternal: $0.isExternal)
        }
        if let selected = raw.first(where: { $0.type == "audio" && $0.isSelected }) {
            selectedAudioID = selected.id
        }
        if let selected = raw.first(where: { $0.type == "sub" && $0.isSelected }) {
            selectedSubtitleID = selected.id
        }
    }
}

// MARK: - MPVPlayerDelegate

extension MPVPlayerModel: MPVPlayerDelegate {
    func propertyChange(mpv: OpaquePointer, propertyName: String, data: Any?) {
        switch propertyName {
        case MPVProperty.timePos:
            guard let value = data as? Double, value.isFinite else { return }
            // 发布节流：位置每 0.25s 最多刷新一次，避免逐帧冲击 SwiftUI；续播保存按整秒
            if abs(value - lastPublishedPosition) >= 0.25 || isPaused {
                lastPublishedPosition = value
                position = value
            }
            saveResume()
        case MPVProperty.duration:
            if let value = data as? Double, value.isFinite, value > 0 { duration = value }
        case MPVProperty.pause:
            if let value = data as? Bool { isPaused = value }
            saveResume(force: true)
        case MPVProperty.pausedForCache:
            if let value = data as? Bool { isBuffering = value }
        case MPVProperty.trackList:
            if fileLoaded { refreshTracks() }
        default:
            break
        }
    }

    func mpvFileLoaded(mpv: OpaquePointer) {
        handleFileLoaded()
    }

    func mpvEndFile(mpv: OpaquePointer, reason: Int32, error: String?) {
        // reason: 0=EOF 自然播完，2=被 stop 中断，3=退出，4=出错，5=重定向
        saveResume(force: true)
        switch reason {
        case 0:
            guard !endFired else { return }
            endFired = true
            onPlaybackEnded?()
        case 4:
            errorMessage = "兼容播放失败：\(error ?? "未知错误")"
            AppLog.add("播放", "兼容播放结束（出错）：\(error ?? "-")")
        default:
            break
        }
    }
}
