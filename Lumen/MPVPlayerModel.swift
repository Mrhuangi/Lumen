import AVFoundation
import Foundation

// MARK: - 播放设置中心（键名集中定义，设置页 / 播放器「更多设置」/ 两条播放路共用）

enum PlayerSettings {
    static let nativeModeKey = "settings.nativeMode"
    static let liquidGlassKey = "settings.liquidGlass"
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
    private static let pairKey = "player.trackPrefs.pair.v1"
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

    /// 双字幕组合记忆（B3）：主＋副签名存进同一条记录，恢复时整对校验，
    /// 不再让两条独立记录漂移拼出用户从未选过的组合
    static func savePair(main: String, secondary: String, scope: String) {
        var pairs = UserDefaults.standard.dictionary(forKey: pairKey) as? [String: String] ?? [:]
        pairs[scope.isEmpty ? "*" : scope] = main + "\u{02}" + secondary
        UserDefaults.standard.set(pairs, forKey: pairKey)
    }

    static func pair(scope: String) -> (main: String, secondary: String)? {
        let pairs = UserDefaults.standard.dictionary(forKey: pairKey) as? [String: String] ?? [:]
        guard let raw = pairs[scope.isEmpty ? "*" : scope] ?? pairs["*"] else { return nil }
        let parts = raw.split(separator: "\u{02}", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
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
    /// 编码 profile 原文（mpv codec-profile）：只有该轨已被解码后才有值，未回填为 nil
    var codecProfile: String?
    /// 声道数（mpv demux-channel-count）
    var channelCount: Int = 0
    /// lavf 流索引（与 FFmpeg probe 对位用）
    var ffIndex: Int = -1
    let isExternal: Bool
    /// mpv track-list 的 forced 标记（强制字幕：招牌/提示类，B 线面板与默认选轨都用）
    var isForced: Bool = false
    /// mpv track-list 的 default 标记（容器标注的默认轨）
    var isDefault: Bool = false
    /// mpv track-list 的 hearing-impaired 标记（听障轨）
    var isHearingImpaired: Bool = false
    /// FFmpeg 旁路 probe 回填：源轨带全景声数据（仅音频轨，codecProfile 缺位时的 demux 层证据）
    var probeAtmos: Bool = false

    /// 菜单显示名：语言译名优先，其次轨道标题，最后回退到轨道号
    var displayName: String {
        var parts: [String] = []
        if let label = Self.languageLabel(lang, title: title) { parts.append(label) }
        if let title, !title.isEmpty, title != lang { parts.append(title) }
        if parts.isEmpty { parts.append(String(localized: "轨道 \(id)")) }
        if isExternal { parts.append(String(localized: "外挂")) }
        return parts.joined(separator: " · ")
    }

    /// 语言译名。中文必须分简繁（菜单里两条都只写「中文」用户无法区分）：
    /// 判定链——lang 的 BCP47（Hans 系 → 简体、Hant 系 → 繁体）→ 轨道标题关键词 → 回退「中文」
    static func languageLabel(_ lang: String?, title: String? = nil) -> String? {
        guard let raw = lang?.lowercased(), !raw.isEmpty else { return nil }
        if raw.hasPrefix("zh") || raw.hasPrefix("cmn") || raw.hasPrefix("yue")
            || raw == "chi" || raw == "zho" {
            return chineseVariantLabel(lang: raw, title: title)
        }
        if raw.hasPrefix("ja") || raw == "jpn" { return String(localized: "日语") }
        if raw.hasPrefix("en") || raw == "eng" { return String(localized: "英语") }
        if raw.hasPrefix("ko") || raw == "kor" { return String(localized: "韩语") }
        if raw == "und" { return nil }
        // 其余语言用系统本地化名称（如「法语」），认不出的再回退到大写代码
        return Locale.current.localizedString(forLanguageCode: raw) ?? raw.uppercased()
    }

    private static func chineseVariantLabel(lang: String, title: String?) -> String {
        if lang.contains("hans") || lang == "zh-cn" || lang == "zh-sg" {
            return String(localized: "简体中文")
        }
        if lang.contains("hant") || lang == "zh-tw" || lang == "zh-hk" || lang == "zh-mo" {
            return String(localized: "繁体中文")
        }
        if let t = title?.uppercased() {
            if t.contains("CHS") || t.contains("简体") || t.contains("简中") || t.contains("SIMPLIFIED") {
                return String(localized: "简体中文")
            }
            if t.contains("CHT") || t.contains("繁体") || t.contains("繁體") || t.contains("繁中") || t.contains("TRADITIONAL") {
                return String(localized: "繁体中文")
            }
        }
        return String(localized: "中文")
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
        if t.contains("简体") || t.contains("简中") || t.contains("CHS") || t.contains("SIMPLIFIED")
            || t.contains("[SC]") { return true }
        let l = (lang ?? "").lowercased()
        return l.contains("hans") || l == "zh-cn"
    }

    var isTraditionalChinese: Bool {
        guard isChinese, !isSimplifiedChinese else { return false }
        let t = (title ?? "").uppercased()
        if t.contains("繁体") || t.contains("繁體") || t.contains("繁中") || t.contains("CHT")
            || t.contains("BIG5") || t.contains("TRADITIONAL") { return true }
        let l = (lang ?? "").lowercased()
        return l.contains("hant") || l == "zh-tw" || l == "zh-hk"
    }

    /// 特效/招牌/注释类轨道（只有招牌翻译、歌曲或制作注释，不是完整对白字幕）
    var isEffectsOrCommentaryTrack: Bool {
        let t = (title ?? "").lowercased()
        return ["特效", "招牌", "signs", "注释", "commentary", "songs", "歌曲"].contains { t.contains($0) }
    }

    /// 默认主字幕优先级分：简体中文 ＞ 未标明中文 ＞ 繁体中文 ＞ 英文 ＞ 其他。
    /// 1.3 规则：强制轨不进默认池（-100）；特效/注释轨降权（-50，只在别无选择时才可能被别处逻辑考虑）；
    /// 最高分 ≤ 0 时调用方不自动选轨，宁可无字幕也不开错轨
    var subtitleDefaultScore: Int {
        if isForced { return -100 }
        if isEffectsOrCommentaryTrack { return -50 }
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
        if let codec, !codec.isEmpty {
            switch codec.lowercased() {
            case "subrip", "srt", "ass", "ssa", "webvtt", "mov_text", "text", "tx3g", "eia_608":
                return true
            default:
                return false
            }
        }
        // codec 读不到时不再一律当文本：外挂 .sup 是位图字幕，标题带 .sup 的按图形处理
        let t = (title ?? "").lowercased()
        return !t.hasSuffix(".sup") && !t.contains(".sup ")
    }

    var subtitleKindLabel: String {
        String(localized: subtitleIsText ? "文本" : "图形")
    }

    /// 字幕格式标签（细化到具体格式，供字幕面板呈现）：ASS / SSA / SRT / VTT / PGS 等
    var subtitleFormatLabel: String {
        switch (codec ?? "").lowercased() {
        case "ass": return "ASS"
        case "ssa": return "SSA"
        case "subrip", "srt": return "SRT"
        case "webvtt": return "VTT"
        case "hdmv_pgs_subtitle", "pgssub": return "PGS"
        case "dvd_subtitle", "vobsub": return "VobSub"
        default: return subtitleIsText ? String(localized: "文本") : String(localized: "图形")
        }
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

    /// 源轨带全景声数据：唯一可靠判据是 codec profile（选中轨解码后由 mpv 回填），
    /// 未回填时用 FFmpeg probe 的 demux 层结果；codec 名、声道数、文件名、轨道标题都不是判据
    var isAtmosAudio: Bool {
        guard type == "audio" else { return false }
        if let codecProfile, !codecProfile.isEmpty {
            return codecProfile.lowercased().contains("atmos")
        }
        return probeAtmos
    }

    /// DTS:X 同理以 profile 为准
    var isDTSXAudio: Bool {
        guard type == "audio" else { return false }
        return codecProfile?.contains("DTS:X") ?? false
    }

    /// 音轨徽标：编码 · 声道 · 全景声，如「E-AC3 · 5.1 · Atmos」（音轨面板行直接用）
    var codecBadgeLabel: String {
        var parts: [String] = []
        let base = codecLabel
        if !base.isEmpty { parts.append(base) }
        switch channelCount {
        case 8: parts.append("7.1")
        case 6: parts.append("5.1")
        case 2: parts.append("2.0")
        case 1: parts.append("1.0")
        default: break
        }
        if isAtmosAudio {
            parts.append("Atmos")
        } else if isDTSXAudio {
            parts.append("DTS:X")
        }
        return parts.joined(separator: " · ")
    }

    /// 轨道签名 v2：语言＋标题＋编码＋轨 id——同名同语言同编码的多条轨靠 id 区分，防撞车选错轨。
    /// id 只在同一文件内稳定，跨集匹配时 match 会逐级放宽，不依赖它
    var signature: String {
        [lang ?? "", title ?? "", codec ?? "", String(id)].joined(separator: "\u{01}")
    }

    /// 按签名找轨：v2 精确 → 三段对位（语言＋标题＋编码，兼容 1.2.x 的旧三段签名）
    /// → 语言＋标题 → 语言＋编码
    static func match(signature: String, in tracks: [MPVTrack]) -> MPVTrack? {
        if let exact = tracks.first(where: { $0.signature == signature }) { return exact }
        let parts = signature.split(separator: "\u{01}", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 || parts.count == 4 else { return nil }
        if let byTriple = tracks.first(where: {
            ($0.lang ?? "") == parts[0] && ($0.title ?? "") == parts[1] && ($0.codec ?? "") == parts[2]
        }) { return byTriple }
        guard !parts[0].isEmpty else { return nil }
        if !parts[1].isEmpty,
           let byTitle = tracks.first(where: { ($0.lang ?? "") == parts[0] && ($0.title ?? "") == parts[1] }) {
            return byTitle
        }
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
    /// 续播落位（秒）：loadfile 不再带 start 参数，文件加载完成后由本模型 seek 过去，只用一次
    private var pendingResumePosition: Double?
    private var fileLoaded = false
    private var endFired = false
    private var outroFired = false
    private var lastSavedSecond = -1
    private var lastPublishedPosition = -1.0
    private var seekFlashCounter = 0
    /// 控制器未 attach 时暂存的加载请求，attach 后补发（L7，不再静默丢 load）
    private var pendingLoadURL: URL?
    /// 轨道刷新合并去抖标记（A1）
    private var trackRefreshScheduled = false
    /// 选轨策略是否已在有轨道的情况下结算过（A6 晚到轨道补跑的闸门）
    private var preferencesSettled = false
    /// 用户本次播放是否手动动过轨道（动过就不再补跑自动选轨）
    private var userTouchedTracks = false
    /// 选中音轨的 codec-profile 是否已在解码开始后回读过（只做一次）
    private var profileRefillDone = false

    init() {
        // mpv 不管理 iOS 音频会话，由 App 侧统一设置（与系统播放路径一致）
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    // MARK: - 装配与加载

    func attach(_ vc: MPVMetalViewController) {
        controller = vc
        vc.playDelegate = self
        vc.onInitFailed = { [weak self] message in
            Task { @MainActor in self?.errorMessage = message }
        }
        if let pending = pendingLoadURL {
            pendingLoadURL = nil
            vc.loadFile(pending)
        }
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
        // 加载即进入缓冲态，由 FILE_LOADED / 加载失败事件清掉，不留「静止的 00:00」（M3）
        isBuffering = true
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
        trackRefreshScheduled = false
        preferencesSettled = false
        userTouchedTracks = false
        profileRefillDone = false
        pendingExternalSubtitle = externalSubtitleURL

        // 记忆倍速关着时，每次加载复位 1.0×（引擎侧在 handleFileLoaded 同步落地，B4）
        if UserDefaults.standard.object(forKey: "settings.rememberRate") as? Bool == false {
            rate = 1.0
        }

        // 自动续播：与系统播放路径同一策略（设置关闭或不足片段尾部时不跳）。
        // 位置先记在本模型，文件加载完成（handleFileLoaded）后用 seek 落位：
        // loadfile 的第三位参数自 mpv 0.38 起是播放列表 index，把 start= 塞进去会被直接拒绝。
        pendingResumePosition = nil
        if UserDefaults.standard.object(forKey: "settings.autoResume") as? Bool != false {
            let saved = ResumeStore.position(forKey: resumeKey) ?? 0
            if saved > 3 { pendingResumePosition = saved }
        }
        if let controller {
            controller.loadFile(url)
        } else {
            // 控制器还没 attach：暂存，attach 时补发，不静默丢掉这次加载（L7）
            pendingLoadURL = url
            AppLog.add("播放", "播放控制器未就绪，加载已暂存")
        }
    }

    func stop() {
        saveResume(force: true)
        controller?.stopPlayback()
        // 方向/缓冲状态随停播复位：残留的横屏判定会让下一个竖屏视频被误推横屏
        videoIsLandscape = nil
        isBuffering = false
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

    func selectAudioTrack(_ id: Int) { userTouchedTracks = true; selectAudio(id, record: true) }
    func selectSubtitleTrack(_ id: Int?) { userTouchedTracks = true; selectSubtitle(id, record: true) }
    func selectSecondarySubtitleTrack(_ id: Int?) { userTouchedTracks = true; selectSecondarySubtitle(id, record: true) }

    private func selectAudio(_ id: Int, record: Bool) {
        selectedAudioID = id
        controller?.setAudioTrack(id)
        profileRefillDone = false   // 切轨后，新选中轨的 codec-profile 要重新延后回读
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
            saveSubtitlePair()
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
            saveSubtitlePair()
        }
    }

    /// 双字幕成对存档：主、副任一变化都把当下组合整对写入（B3）
    private func saveSubtitlePair() {
        let main = selectedSubtitleID.flatMap { id in subtitleTracks.first { $0.id == id }?.signature }
            ?? TrackPreferenceStore.offValue
        let secondary = selectedSecondarySubtitleID.flatMap { id in subtitleTracks.first { $0.id == id }?.signature }
            ?? TrackPreferenceStore.offValue
        TrackPreferenceStore.savePair(main: main, secondary: secondary, scope: preferenceScope)
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
        // 只存「3 秒之后、离片尾至少 10 秒」的位置：停在最后几秒的续播点会让下次打开
        // 直接落进片尾窗口、甚至立刻播完（S1）；播完时该点的清除在 EOF 处理里做
        if position > 3, position < duration - 10 {
            ResumeStore.save(key: currentKey, seconds: position, duration: duration)
        }
    }

    // MARK: - 文件加载后的默认策略

    private func handleFileLoaded() {
        fileLoaded = true
        isBuffering = false
        guard let vc = controller else { return }

        // 显示宽高要计入旋转元数据（竖拍视频 rotate=90 时编码宽高是反的）
        let displaySize = vc.videoDisplaySize()
        if displaySize.width > 0, displaySize.height > 0 {
            videoIsLandscape = displaySize.width > displaySize.height
        }
        let d = vc.getDouble(MPVProperty.duration)
        if d > 0 { duration = d }

        performTrackRefresh()
        refreshChapters()
        applySubtitleFontSize()

        // 续播落位：文件已加载，seek 到上次的位置（只落一次；位置已过片尾则不跳）
        var startPosition = vc.getDouble(MPVProperty.timePos)
        if let resume = pendingResumePosition {
            pendingResumePosition = nil
            // 落位也要离片尾至少 10 秒（与 saveResume 同口径，S1）：更靠后的点不续，
            // 宁可从头播，也不能一打开就落进片尾窗口立刻播完
            if resume > 3, duration <= 0 || resume < duration - 10 {
                vc.seekAbsolute(resume)
                position = resume
                startPosition = resume
                AppLog.add("播放", "已续播到 \(Int(resume)) 秒")
            }
        }

        // 倍速与两条播放路同一口径（B4）：记忆开 → 按记忆恢复；记忆关 → 强制 1.0×。
        // 引擎的 speed 跨文件保留，不显式落定会把上一个文件的倍速漂进新文件
        if UserDefaults.standard.object(forKey: "settings.rememberRate") as? Bool != false,
           let saved = UserDefaults.standard.object(forKey: "player.lastRate") as? Double,
           saved > 0, abs(saved - 1.0) > 0.01 {
            rate = saved
        } else {
            rate = 1.0
        }
        vc.setRate(rate)

        // 跳过片头：从片头范围内起播（新片或续播位置仍在片头里）时直接跳到片头结束；
        // 判断位置用续播落位后的有效起点（seek 是异步命令，立即回读 time-pos 仍是旧值）
        if PlayerSettings.skipIntroOutro {
            let intro = PlayerSettings.introSeconds
            if intro > 0, startPosition < intro,
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
        if !subtitleTracks.isEmpty { preferencesSettled = true }

        // 全景声旁路 probe：后台 demux 一遍，把每条音轨的全景声标注回填（未选中轨 mpv 读不到 profile）
        startAtmosProbe()
    }

    /// FFmpeg 旁路 probe：按 ff-index 对位、codec 名二次校验后回填 probeAtmos；
    /// 对位对不上就弃用，宁可不标也不错标（MKV 内置 demuxer 时 ff-index 无硬保证）
    private func startAtmosProbe() {
        guard let url = currentURL, url.isFileURL else { return }
        let key = currentKey
        Task.detached(priority: .utility) {
            let streams = FFmpegAudioProbe.audioStreams(for: url)
            guard !streams.isEmpty else { return }
            await MainActor.run { [weak self] in
                guard let self, self.currentKey == key else { return }
                var changed = false
                for index in self.audioTracks.indices {
                    let track = self.audioTracks[index]
                    guard let hit = streams.first(where: { $0.streamIndex == track.ffIndex }) else { continue }
                    if let codec = track.codec, !codec.isEmpty,
                       hit.codecName != codec.lowercased() { continue }
                    if hit.isAtmos != track.probeAtmos {
                        self.audioTracks[index].probeAtmos = hit.isAtmos
                        changed = true
                    }
                }
                if changed {
                    AppLog.add("播放", "音轨全景声标注已由 FFmpeg 旁路 probe 回填")
                }
            }
        }
    }

    /// 音轨＋主字幕＋副字幕：先按记忆（单剧优先于全局），无记忆时用默认策略
    private func applyTrackPreferences() {
        applyAudioPreference()

        // 双字幕先整对恢复（B3）：成对记录命中且主轨还在 → 副轨只按记录恢复；
        // 主轨对不上则整对作废、回落单条逻辑，绝不拼出「默认主轨＋记忆副轨」的变形组合
        if let pair = TrackPreferenceStore.pair(scope: preferenceScope) {
            var mainOK = false
            if pair.main == TrackPreferenceStore.offValue {
                selectSubtitle(nil, record: false)
                mainOK = true
            } else if let track = MPVTrack.match(signature: pair.main, in: subtitleTracks) {
                selectSubtitle(track.id, record: false)
                mainOK = true
            }
            if mainOK {
                if pair.secondary == TrackPreferenceStore.offValue {
                    selectSecondarySubtitle(nil, record: false)
                } else if let track = MPVTrack.match(signature: pair.secondary, in: subtitleTracks),
                          track.id != selectedSubtitleID {
                    selectSecondarySubtitle(track.id, record: false)
                } else {
                    selectSecondarySubtitle(nil, record: false)
                    AppLog.add("播放", "记忆的副字幕轨在本文件不可用，已跳过副字幕恢复")
                }
                return
            }
            AppLog.add("播放", "记忆的双字幕组合主轨在本文件不可用，改走单条记忆/默认选轨")
        }

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
        // 最高分 ≤ 0：只有强制/特效/其他语言轨，宁可不开字幕也不自动选错轨
        if let best, best.subtitleDefaultScore > 0 {
            selectSubtitle(best.id, record: false)
            AppLog.add("播放", "已默认选中内封字幕：\(best.displayName)")
        }
    }

    /// 轨道刷新入口（合并去抖）：track-list 观察、sub-add 完成会接连触发全量重读，
    /// 100ms 内的重复触发合并成一次（A1）
    private func refreshTracks() {
        guard !trackRefreshScheduled else { return }
        trackRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.trackRefreshScheduled = false
            self.performTrackRefresh()
        }
    }

    /// 打开音轨/字幕面板前调用：选中轨的 codec-profile 这时多半已可读，刷一次让全景声标注追上
    func refreshTrackInfoForMenu() {
        refreshTracks()
    }

    private func performTrackRefresh() {
        guard let vc = controller else { return }
        let raw = vc.readTracks()
        // 播完后引擎已卸片，轨道查询为空：保留上一次的列表，不让面板变空。
        // load() 时已先清过数组，所以真正无轨的文件这里仍为空，不会残留旧片轨道。
        guard !raw.isEmpty else { return }
        let oldAudio = audioTracks
        audioTracks = raw.filter { $0.type == "audio" }.map { info in
            var track = MPVTrack(id: info.id, type: info.type, lang: info.lang, title: info.title,
                                 codec: info.codec, isExternal: info.isExternal)
            track.codecProfile = info.codecProfile
            track.channelCount = info.channelCount
            track.ffIndex = info.ffIndex
            track.isForced = info.isForced
            track.isDefault = info.isDefault
            track.isHearingImpaired = info.isHearingImpaired
            // probe 的标注粘性保留：重读轨道不能把 FFmpeg 旁路证据冲掉（profile 在位时以 profile 为准）
            track.probeAtmos = oldAudio.first { $0.id == info.id }?.probeAtmos ?? false
            return track
        }
        subtitleTracks = raw.filter { $0.type == "sub" }.map { info in
            var track = MPVTrack(id: info.id, type: info.type, lang: info.lang, title: info.title,
                                 codec: info.codec, isExternal: info.isExternal)
            track.codecProfile = info.codecProfile
            track.isForced = info.isForced
            track.isDefault = info.isDefault
            track.isHearingImpaired = info.isHearingImpaired
            return track
        }
        if let selected = raw.first(where: { $0.type == "audio" && $0.isSelected }) {
            selectedAudioID = selected.id
        }
        if let selected = raw.first(where: { $0.type == "sub" && $0.isSelected }) {
            selectedSubtitleID = selected.id
        }
        // 对账日志：选中轨 profile 的实际返回值，方便真机核对全景声判定字符串
        if let selected = audioTracks.first(where: { $0.id == selectedAudioID }) {
            AppLog.add("播放", "选中音轨对账：codec=\(selected.codec ?? "-")，profile=\(selected.codecProfile ?? "nil")，probeAtmos=\(selected.probeAtmos)，徽标=\(selected.codecBadgeLabel)")
        }
        // A6：FILE_LOADED 之后才枚举出来的轨道（慢 demux / 后加外挂），
        // 在选轨还没结算、用户也没手动动过时补跑一次记忆/默认选轨
        if fileLoaded, !preferencesSettled, !userTouchedTracks,
           !subtitleTracks.isEmpty, pendingExternalSubtitle == nil {
            preferencesSettled = true
            applyTrackPreferences()
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
        // 短内容防线：总时长不足「片头＋片尾＋30 秒」的内容不设片尾窗口，
        // 否则整段都落在窗口里、一开播就弹跳过按钮甚至自动切集（M1）
        guard duration > PlayerSettings.introSeconds + outro + 30 else { return }
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
            // 选中音轨的 codec-profile 只有开始解码后才有值：播过 0.5 秒回读一次回填全景声标注
            if value > 0.5, !profileRefillDone {
                profileRefillDone = true
                refreshTracks()
            }
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

    /// loadfile 被引擎当场拒绝：没有 END_FILE 事件可等，必须直接点亮报错条，
    /// 不许再出现「黑屏 00:00 且无任何提示」
    func mpvLoadFailed(mpv: OpaquePointer, error: String) {
        isBuffering = false
        errorMessage = String(localized: "无法播放这个文件")
        AppLog.add("播放", "直读加载被引擎拒绝：\(error)")
    }

    func mpvEndFile(mpv: OpaquePointer, reason: Int32, error: String?) {
        // reason: 0=EOF 自然播完，2=被 stop 中断，3=退出，4=出错，5=重定向
        saveResume(force: true)
        switch reason {
        case 0:
            // 自然播完：清掉这一集的续播点，下次从头开始（S1）
            if !currentKey.isEmpty { ResumeStore.remove(key: currentKey) }
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
