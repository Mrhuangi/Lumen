import AVFoundation
import Foundation

// MARK: - 播放设置中心（键名集中定义，设置页 / 播放器「更多设置」/ 两条播放路共用）

enum PlayerSettings {
    static let nativeModeKey = "settings.nativeMode"
    static let skipKey = "settings.skipIntroOutro"
    static let introSecondsKey = "settings.skipIntroSeconds"
    static let outroSecondsKey = "settings.skipOutroSeconds"
    static let showPrevNextKey = "settings.showPrevNextButtons"
    static let showSeekButtonsKey = "settings.showSeekButtons"
    static let mpvSubtitleFontSizeKey = "settings.mpvSubtitleFontSize"

    private static var defaults: UserDefaults { .standard }

    /// 原生模式：先无损重封装再用系统播放器。默认关（默认直读直放，点开即播）。
    static var nativeMode: Bool { defaults.bool(forKey: nativeModeKey) }
    /// 跳过片头片尾总开关，默认关（在播放器更多设置或设置页开启）
    static var skipIntroOutro: Bool { defaults.bool(forKey: skipKey) }
    static var introSeconds: Double {
        (defaults.object(forKey: introSecondsKey) as? NSNumber)?.doubleValue ?? 90
    }
    static var outroSeconds: Double {
        (defaults.object(forKey: outroSecondsKey) as? NSNumber)?.doubleValue ?? 120
    }
    static var showPrevNextButtons: Bool {
        defaults.object(forKey: showPrevNextKey) as? Bool != false
    }
    static var showSeekButtons: Bool {
        defaults.object(forKey: showSeekButtonsKey) as? Bool != false
    }
    /// 直读字幕字号（mpv sub-font-size 的原始数值）
    static var mpvSubtitleFontSize: Int {
        (defaults.object(forKey: mpvSubtitleFontSizeKey) as? NSNumber)?.intValue ?? 55
    }
}

// MARK: - 轨道选择记忆（全局一份＋每部剧一份，选剧优先）

enum TrackPreferenceStore {
    private static let globalKey = "player.trackPrefs.global.v1"
    private static let perShowKey = "player.trackPrefs.show.v1"
    /// 用户手动关闭字幕的记录值（区别于「没有记录」）
    static let offValue = "off"

    static func save(kind: String, value: String, scope: String) {
        var global = defaults(kind: globalKey)
        global[kind] = value
        UserDefaults.standard.set(global, forKey: globalKey)
        guard !scope.isEmpty else { return }
        var perShow = defaults(kind: perShowKey)
        perShow["\(scope)#\(kind)"] = value
        UserDefaults.standard.set(perShow, forKey: perShowKey)
    }

    static func value(kind: String, scope: String) -> String? {
        if !scope.isEmpty,
           let perShow = UserDefaults.standard.dictionary(forKey: perShowKey) as? [String: String],
           let v = perShow["\(scope)#\(kind)"] {
            return v
        }
        let global = UserDefaults.standard.dictionary(forKey: globalKey) as? [String: String]
        return global?[kind]
    }

    private static func defaults(kind key: String) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}

// MARK: - 轨道

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
        if parts.isEmpty { parts.append(String(localized: "轨道 \(id)")) }
        if isExternal { parts.append(String(localized: "外挂")) }
        return parts.joined(separator: " · ")
    }

    static func languageLabel(_ lang: String?) -> String? {
        guard let raw = lang?.lowercased(), !raw.isEmpty else { return nil }
        if raw.hasPrefix("zh") || raw.hasPrefix("cmn") || raw.hasPrefix("yue")
            || raw == "chi" || raw == "zho" { return String(localized: "中文") }
        if raw.hasPrefix("ja") || raw == "jpn" { return String(localized: "日语") }
        if raw.hasPrefix("en") || raw == "eng" { return String(localized: "英语") }
        if raw.hasPrefix("ko") || raw == "kor" { return String(localized: "韩语") }
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

    var isEnglish: Bool {
        if let lang {
            let l = lang.lowercased()
            if l.hasPrefix("en") || l == "eng" { return true }
        }
        if let title {
            return title.contains("英语") || title.lowercased().contains("english")
        }
        return false
    }

    var isSimplifiedChinese: Bool {
        guard isChinese else { return false }
        let t = (title ?? "").uppercased()
        if t.contains("简体") || t.contains("简中") || t.contains("CHS") { return true }
        let l = (lang ?? "").lowercased()
        return l.contains("hans") || l == "zh-cn"
    }

    var isTraditionalChinese: Bool {
        guard isChinese, !isSimplifiedChinese else { return false }
        let t = (title ?? "").uppercased()
        if t.contains("繁体") || t.contains("繁中") || t.contains("CHT") || t.contains("BIG5") { return true }
        let l = (lang ?? "").lowercased()
        return l.contains("hant") || l == "zh-tw" || l == "zh-hk"
    }

    /// 默认主字幕优先级分：简体中文 ＞ 未标明中文 ＞ 繁体中文 ＞ 英文 ＞ 其他（同分取首轨）
    var subtitleDefaultScore: Int {
        if isSimplifiedChinese { return 50 }
        if isTraditionalChinese { return 40 }
        if isChinese { return 45 }
        if isEnglish { return 30 }
        return 0
    }

    /// 简体优先排序分（重封装旁路字幕的默认挑选沿用）
    var chinesePreferenceScore: Int {
        guard isChinese else { return 0 }
        var score = 10
        if let title {
            if title.contains("简体") || title.contains("简中") || title.uppercased().contains("CHS") { score += 3 }
            if title.contains("繁体") || title.contains("繁中") || title.uppercased().contains("CHT") { score += 2 }
        }
        return score
    }

    /// 字幕轨形态：文本（可渲染为文字）或图形（PGS/VobSub 等位图字幕）
    var subtitleIsText: Bool {
        guard let codec, !codec.isEmpty else { return true }
        switch codec.lowercased() {
        case "subrip", "srt", "ass", "ssa", "webvtt", "mov_text", "text", "tx3g", "eia_608":
            return true
        default:
            return false
        }
    }

    var subtitleKindLabel: String {
        String(localized: subtitleIsText ? "文本" : "图形")
    }

    /// 音轨编码的事实标注（元数据直读，不做品牌宣传加工）
    var codecLabel: String {
        switch (codec ?? "").lowercased() {
        case "eac3": return "E-AC3"
        case "ac3": return "AC3"
        case "aac": return "AAC"
        case "dts": return "DTS"
        case "truehd": return "TrueHD"
        case "flac": return "FLAC"
        case "mp3": return "MP3"
        case "opus": return "Opus"
        case "alac": return "ALAC"
        case "": return ""
        case let c where c.hasPrefix("pcm"): return "PCM"
        case let c: return c.uppercased()
        }
    }

    /// 轨道签名：跨文件/跨版本稳定地认出「同一条轨」，用于选择记忆
    var signature: String {
        [lang ?? "", title ?? "", codec ?? ""].joined(separator: "\u{01}")
    }

    /// 按签名找轨：先精确匹配，标题变化时退按语言＋编码匹配
    static func match(signature: String, in tracks: [MPVTrack]) -> MPVTrack? {
        if let exact = tracks.first(where: { $0.signature == signature }) { return exact }
        let parts = signature.split(separator: "\u{01}", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, !parts[0].isEmpty else { return nil }
        return tracks.first { ($0.lang ?? "") == parts[0] && ($0.codec ?? "") == parts[2] }
    }
}

// MARK: - 章节

struct MPVChapter: Identifiable, Equatable {
    let index: Int
    let title: String?
    let time: Double
    var id: Int { index }
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return String(localized: "章节 \(index + 1)")
    }
}

// MARK: - mpv 播放适配层（默认引擎：直读直放）

/// 对外接口：load / 续播写入 ResumeStore / 倍速记忆 player.lastRate / 结束回调 /
/// 横竖屏信号 / 错误上报；另含双字幕、章节、跳过片头片尾、轨道选择记忆。
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
    @Published private(set) var chapters: [MPVChapter] = []
    @Published private(set) var selectedAudioID: Int?
    @Published private(set) var selectedSubtitleID: Int?
    @Published private(set) var selectedSecondarySubtitleID: Int?
    @Published private(set) var rate: Double = 1.0
    /// 片尾窗口已到达（界面据此显示「跳过片尾」按钮）
    @Published private(set) var outroPromptVisible = false
    /// 快进/快退提示（控制层据此闪现 gobackward.10 / goforward.10 指示）
    @Published private(set) var seekFlash: (forward: Bool, counter: Int)?

    /// 播放结束回调（用于自动连播下一集）
    var onPlaybackEnded: (() -> Void)?
    /// 到达片尾窗口且存在下一集时的回调（由播放流程决定是否切集）
    var onOutroReached: (() -> Void)?
    /// 用户点「跳过片尾」按钮的回调（明确意图，播放流程直接切集，不受自动连播开关约束）
    var onSkipOutroRequested: (() -> Void)?
    /// 是否存在可切的下一集（播放流程设置，决定片尾是自动切集还是跳到结尾）
    var outroAdvanceAvailable = false
    /// 当前播放文件（供拖动进度时本地抽帧预览用）
    private(set) var currentURL: URL?

    private weak var controller: MPVMetalViewController?
    private var currentKey = ""
    private var preferenceScope = ""
    private var pendingExternalSubtitle: URL?
    private var fileLoaded = false
    private var endFired = false
    private var outroFired = false
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

    /// preferenceScope：轨道选择记忆的归属（剧名；单片传片名即可）
    func load(url: URL, title: String, resumeKey: String = "",
              externalSubtitleURL: URL? = nil, preferenceScope: String = "") {
        self.title = title
        currentKey = resumeKey
        self.preferenceScope = preferenceScope
        currentURL = url
        errorMessage = nil
        videoIsLandscape = nil
        isBuffering = false
        position = 0
        duration = 0
        audioTracks = []
        subtitleTracks = []
        chapters = []
        selectedAudioID = nil
        selectedSubtitleID = nil
        selectedSecondarySubtitleID = nil
        outroPromptVisible = false
        fileLoaded = false
        endFired = false
        outroFired = false
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

    func selectAudioTrack(_ id: Int) { selectAudio(id, record: true) }
    func selectSubtitleTrack(_ id: Int?) { selectSubtitle(id, record: true) }
    func selectSecondarySubtitleTrack(_ id: Int?) { selectSecondarySubtitle(id, record: true) }

    private func selectAudio(_ id: Int, record: Bool) {
        selectedAudioID = id
        controller?.setAudioTrack(id)
        if record, let track = audioTracks.first(where: { $0.id == id }) {
            TrackPreferenceStore.save(kind: "audio", value: track.signature, scope: preferenceScope)
        }
    }

    private func selectSubtitle(_ id: Int?, record: Bool) {
        selectedSubtitleID = id
        controller?.setSubtitleTrack(id)
        if record {
            if let id, let track = subtitleTracks.first(where: { $0.id == id }) {
                TrackPreferenceStore.save(kind: "sub", value: track.signature, scope: preferenceScope)
            } else if id == nil {
                TrackPreferenceStore.save(kind: "sub", value: TrackPreferenceStore.offValue,
                                          scope: preferenceScope)
            }
        }
    }

    private func selectSecondarySubtitle(_ id: Int?, record: Bool) {
        selectedSecondarySubtitleID = id
        controller?.setSecondarySubtitleTrack(id)
        if record {
            if let id, let track = subtitleTracks.first(where: { $0.id == id }) {
                TrackPreferenceStore.save(kind: "sub2", value: track.signature, scope: preferenceScope)
            } else if id == nil {
                TrackPreferenceStore.save(kind: "sub2", value: TrackPreferenceStore.offValue,
                                          scope: preferenceScope)
            }
        }
    }

    /// 播放中临时加载本地外挂字幕（sub-add 并立即启用为主字幕）
    func addExternalSubtitleFile(_ url: URL) {
        controller?.addExternalSubtitle(url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.refreshTracks()
        }
    }

    /// 把设置里的字幕字号应用到引擎（加载后与面板调整时调用）
    func applySubtitleFontSize() {
        controller?.setSubtitleFontSize(PlayerSettings.mpvSubtitleFontSize)
    }

    /// 「跳过片尾」按钮：有下一集则切集，否则跳到结尾
    func skipOutro() {
        outroPromptVisible = false
        if outroAdvanceAvailable {
            outroFired = true
            (onSkipOutroRequested ?? onOutroReached)?()
        } else if duration > 0 {
            seek(to: max(duration - 0.5, 0))
        }
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
        refreshChapters()
        applySubtitleFontSize()

        // 沿用上次倍速（设置可关），与系统播放路径一致
        if UserDefaults.standard.object(forKey: "settings.rememberRate") as? Bool != false,
           let saved = UserDefaults.standard.object(forKey: "player.lastRate") as? Double,
           saved > 0, abs(saved - 1.0) > 0.01 {
            rate = saved
            vc.setRate(saved)
        }

        // 跳过片头：从片头范围内起播（新片或续播位置仍在片头里）时直接跳到片头结束
        if PlayerSettings.skipIntroOutro {
            let intro = PlayerSettings.introSeconds
            let pos = vc.getDouble(MPVProperty.timePos)
            if intro > 0, pos < intro,
               duration > intro + PlayerSettings.outroSeconds + 30 {
                vc.seekAbsolute(intro)
                position = intro
                AppLog.add("播放", "已跳过片头（\(Int(intro)) 秒）")
            }
        }

        // 外挂字幕优先：挂上并启用；否则按「记忆 → 默认优先级」选轨
        if let external = pendingExternalSubtitle {
            vc.addExternalSubtitle(external)
            AppLog.add("播放", "已加载外挂字幕：\(external.lastPathComponent)")
            // sub-add 是异步命令，稍后刷新轨道列表以反映外挂轨的选中状态
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.refreshTracks()
            }
            applyAudioPreference()
        } else {
            applyTrackPreferences()
        }
    }

    /// 音轨＋主字幕＋副字幕：先按记忆（单剧优先于全局），无记忆时用默认策略
    private func applyTrackPreferences() {
        applyAudioPreference()

        if let saved = TrackPreferenceStore.value(kind: "sub", scope: preferenceScope) {
            if saved == TrackPreferenceStore.offValue {
                selectSubtitle(nil, record: false)
            } else if let track = MPVTrack.match(signature: saved, in: subtitleTracks) {
                selectSubtitle(track.id, record: false)
            } else {
                applyDefaultSubtitle()
            }
        } else {
            applyDefaultSubtitle()
        }

        if let saved = TrackPreferenceStore.value(kind: "sub2", scope: preferenceScope),
           saved != TrackPreferenceStore.offValue,
           let track = MPVTrack.match(signature: saved, in: subtitleTracks),
           track.id != selectedSubtitleID {
            selectSecondarySubtitle(track.id, record: false)
        }
    }

    private func applyAudioPreference() {
        guard let saved = TrackPreferenceStore.value(kind: "audio", scope: preferenceScope),
              let track = MPVTrack.match(signature: saved, in: audioTracks) else { return }
        selectAudio(track.id, record: false)
    }

    /// 默认主字幕：简体中文 ＞ 未标明中文 ＞ 繁体中文 ＞ 英文 ＞ 首轨
    private func applyDefaultSubtitle() {
        guard !subtitleTracks.isEmpty else { return }
        let best = subtitleTracks.enumerated().max { a, b in
            a.element.subtitleDefaultScore != b.element.subtitleDefaultScore
                ? a.element.subtitleDefaultScore < b.element.subtitleDefaultScore
                : a.offset > b.offset
        }?.element
        if let best {
            selectSubtitle(best.id, record: false)
            AppLog.add("播放", "已默认选中内封字幕：\(best.displayName)")
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

    private func refreshChapters() {
        guard let vc = controller else { return }
        chapters = vc.readChapters().enumerated().map {
            MPVChapter(index: $0.offset, title: $0.element.title, time: $0.element.time)
        }
    }

    /// 片尾窗口检测（time-pos 驱动）：进入窗口显示跳过按钮；有下一集时自动切集一次
    private func checkOutro(at value: Double) {
        guard PlayerSettings.skipIntroOutro else {
            if outroPromptVisible { outroPromptVisible = false }
            return
        }
        let outro = PlayerSettings.outroSeconds
        guard outro > 0, duration > 0 else { return }
        if duration - value <= outro, value > 3 {
            outroPromptVisible = true
            if outroAdvanceAvailable, !outroFired {
                outroFired = true
                onOutroReached?()
            }
        } else if outroPromptVisible, duration - value > outro + 5 {
            outroPromptVisible = false
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
            checkOutro(at: value)
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
        case MPVProperty.chapterList:
            if fileLoaded { refreshChapters() }
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
            let detail = error ?? String(localized: "未知错误")
            errorMessage = String(localized: "播放失败：\(detail)")
            AppLog.add("播放", "播放结束（出错）：\(error ?? "-")")
        default:
            break
        }
    }
}
