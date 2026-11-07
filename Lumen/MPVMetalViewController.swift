import Foundation
import UIKit
import Libmpv

// 移植自 MPVKit 官方 Demo 的 Metal 播放层（LGPL），按 Lumen 需要与前人踩坑记录改造：
// - EDR 显示层（pixelFormat / colorspace / edrMetadata）在 mpv 初始化之前一次性配好，
//   会话内绝不修改（MoltenVK swapchain 按初始格式创建，中途改格式会黑屏/花屏）。
// - wakeup 回调使用显式 C 函数指针（Swift 6 下闭包会被推断隔离而触发 trap），
//   且回调里只投递「去排空事件」，不在回调线程里调 mpv API。
// - 每个 setOption 都检查返回值，失败写 AppLog（mpv 的选项失败默认静默）。
// - 全屏/旋转只改 layer 尺寸（由 SwiftUI 的 fullScreenCover 承载），wid 只在初始化时设一次。
//
// 注意：播放 HDR 内容时需在 Scheme 里关闭 Metal API Validation（云端构建无此开关，
// 仅影响调试校验，不影响产物）——https://github.com/KhronosGroup/MoltenVK/issues/2226

/// wakeup  trampoline：mpv 任意内部线程调用，只把排空动作投递到控制器自己的队列
private func mpvWakeupTrampoline(_ ctx: UnsafeMutableRawPointer?) {
    guard let ctx else { return }
    let vc = Unmanaged<MPVMetalViewController>.fromOpaque(ctx).takeUnretainedValue()
    vc.notifyEvents()
}

final class MPVMetalViewController: UIViewController {
    let metalLayer = MetalLayer()
    private(set) var mpv: OpaquePointer!
    var playDelegate: MPVPlayerDelegate?
    /// 初始化级失败（mpv_create / mpv_initialize）的上报通道：模型据此点亮报错条，
    /// 不再出现「黑屏 00:00 且无任何提示」（S4）
    var onInitFailed: ((String) -> Void)?

    private lazy var queue = DispatchQueue(label: "lumen.mpv.events", qos: .userInitiated)
    private var pendingLoad: URL?
    private var wasPlayingBeforeBackground = false
    private var eventsStopped = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // EDR 显示层：必须在 mpv 初始化之前定死，整个播放会话不再改动
        metalLayer.frame = view.bounds
        metalLayer.contentsScale = UIScreen.main.nativeScale
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        metalLayer.wantsExtendedDynamicRangeContent = true
        metalLayer.pixelFormat = .rgba16Float
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
        metalLayer.edrMetadata = CAEDRMetadata.hdr10(minLuminance: 0.005,
                                                     maxLuminance: 1000,
                                                     opticalOutputScale: 203)
        view.layer.addSublayer(metalLayer)

        setupMpv()
        setupNotifications()

        if let pending = pendingLoad {
            pendingLoad = nil
            loadFile(pending)
        }
    }

    private var lastLoggedBounds: CGRect = .zero

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        metalLayer.frame = view.bounds
        if view.bounds != lastLoggedBounds {
            lastLoggedBounds = view.bounds
            AppLog.add("播放", "播放视图布局 bounds \(Int(view.bounds.width))×\(Int(view.bounds.height))，drawable \(Int(metalLayer.drawableSize.width))×\(Int(metalLayer.drawableSize.height))")
        }
    }

    /// 旋转转场期间同步 layer 尺寸：等布局回调之外再补一手，
    /// 保证转场动画的每一帧 layer 都贴合目标尺寸（转场结束以实际 bounds 收尾）
    override func viewWillTransition(to size: CGSize,
                                     with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        AppLog.add("播放", "播放视图转场到 \(Int(size.width))×\(Int(size.height))")
        coordinator.animate(alongsideTransition: { _ in
            self.metalLayer.frame = CGRect(origin: .zero, size: size)
        }, completion: { _ in
            self.metalLayer.frame = self.view.bounds
        })
    }

    // MARK: - mpv 初始化

    @discardableResult
    private func setupMpv() -> Bool {
        guard let created = mpv_create() else {
            AppLog.add("播放", "mpv 初始化失败：mpv_create 返回空")
            onInitFailed?(String(localized: "播放引擎初始化失败"))
            return false
        }
        mpv = created

#if DEBUG
        checkError(mpv_request_log_messages(mpv, "warn"), "request_log_messages")
#else
        checkError(mpv_request_log_messages(mpv, "no"), "request_log_messages")
#endif
        // wid 只设这一次：把 CAMetalLayer 裸指针交给 mpv（Demo 同款做法）
        var layer = metalLayer
        checkError(mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &layer), "wid")
        setOption("vo", "gpu-next")
        setOption("gpu-api", "vulkan")
        setOption("gpu-context", "moltenvk")
        // 明确启用 VideoToolbox 硬解（H.6 功耗要求），禁止掉到软件解码
        setOption("hwdec", "videotoolbox")
        // 必须在 initialize 之前设置：把源色彩空间提示透传给显示层（HDR 点亮的前提）
        setOption("target-colorspace-hint", "yes")
        setOption("subs-match-os-language", "yes")
        setOption("subs-fallback", "yes")
        // 注意：不要设置 target-peak（整型选项传浮点字符串会被静默拒绝并压暗画面）

        // 字幕字体（1.3）：iOS 上 libass 的 CoreText 回退拿到的中文字体在私有框架里、
        // 沙盒读不到，中文字幕会全灭成方框（详见 research_notes/lumen-v1.3-research/subtitle-font.md）。
        // 解法是随包字体三件叠加，全部在 initialize 前设好：
        // config-dir 落沙盒受控目录（其 fonts/ 是 libass 默认字体库，subfont.ttf 是无条件兜底），
        // sub-fonts-dir 直指包内目录，sub-font 写字体内部 family 名（不是文件名）。
        SubtitleFontInstaller.ensureSubfontFallback()
        SubtitleFontInstaller.installAllInBackground()
        setOption("config-dir", SubtitleFontInstaller.configDirectory.path)
        if let bundleFonts = SubtitleFontInstaller.bundleFontsDirectory {
            setOption("sub-fonts-dir", bundleFonts.path)
            setOption("osd-fonts-dir", bundleFonts.path)
        }
        setOption("sub-font", "Noto Sans CJK SC")

        // 解码性能与发热（1.3，据 performance.md 的 A/B 组）：
        // allow-delayed-peak-detect 是纯赚项——省掉峰值检测引入的一整遍全屏 FBO 间接拷贝；
        // 其余四项把 mpv 默认值显式写死，防升版漂移把省电基线带走。
        // hwdec / vo / hdr-compute-peak 经调研维持现状，不动。
        setOption("allow-delayed-peak-detect", "yes")
        setOption("framedrop", "vo")
        setOption("video-sync", "audio")
        setOption("interpolation", "no")
        setOption("deband", "no")

        let initStatus = mpv_initialize(mpv)
        guard initStatus >= 0 else {
            checkError(initStatus, "mpv_initialize")
            onInitFailed?(String(localized: "播放引擎初始化失败"))
            return false
        }

        mpv_observe_property(mpv, 0, MPVProperty.timePos, MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, MPVProperty.duration, MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, MPVProperty.pause, MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, MPVProperty.pausedForCache, MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, MPVProperty.trackList, MPV_FORMAT_NONE)
        mpv_observe_property(mpv, 0, MPVProperty.chapterList, MPV_FORMAT_NONE)
        mpv_observe_property(mpv, 0, MPVProperty.videoParamsSigPeak, MPV_FORMAT_DOUBLE)
        mpv_set_wakeup_callback(mpv, mpvWakeupTrampoline,
                                UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
        return true
    }

    private func setOption(_ name: String, _ value: String) {
        guard mpv != nil else { return }
        checkError(mpv_set_option_string(mpv, name, value), "set \(name)=\(value)")
    }

    /// 销毁 mpv 实例（Representable 拆卸时调用）：先在事件队列上置停止标志并排空，
    /// 再摘回调、terminate，避免事件排空与销毁并发造成 use-after-free（M11）
    func teardownPlayer() {
        guard mpv != nil else { return }
        queue.sync { eventsStopped = true }
        mpv_set_wakeup_callback(mpv, nil, nil)
        mpv_terminate_destroy(mpv)
        mpv = nil
    }

    // MARK: - 后台处理（C7：进后台必须停渲染，回前台恢复到后台前状态）

    private func setupNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(enterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(enterForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    @objc private func enterBackground() {
        guard mpv != nil else { return }
        wasPlayingBeforeBackground = !getFlag(MPVProperty.pause)
        pause()
        // 进后台关掉视频输出，避免 Metal 命令缓冲被系统拒绝。
        // vid 在 initialize 后必须走属性 API，选项 API 会被引擎拒绝（M10）
        checkError(mpv_set_property_string(mpv, "vid", "no"), "vid=no")
    }

    @objc private func enterForeground() {
        guard mpv != nil else { return }
        checkError(mpv_set_property_string(mpv, "vid", "auto"), "vid=auto")
        if wasPlayingBeforeBackground { play() }
    }

    // MARK: - 播放控制（供 MPVPlayerModel 调用）

    /// 只传两个参数。mpv 0.38 起 loadfile 的语法是 loadfile <url> [<flags> [<index> [<options>]]]，
    /// 第三位是播放列表 index（整数）：把 "start=…" 塞进第三位会被引擎直接拒为
    /// MPV_ERROR_INVALID_PARAMETER，文件根本不加载、界面只剩黑屏 00:00（1.2.1 修复的回归根因，
    /// 依据：mpv 官方手册 loadfile 条目对 0.38 参数位变更的警告）。
    /// 续播位置改由模型在 MPV_EVENT_FILE_LOADED 后用 seek 落位，不再走 loadfile 参数。
    /// 本地文件传裸路径（与 sub-add 的用法一致，避免百分号编码干扰）；网络直链才传完整 URL 串。
    /// 命令被拒时除记日志（带实际传入的目标串）外，还经 delegate 通知模型点亮界面报错。
    func loadFile(_ url: URL) {
        guard mpv != nil else {
            pendingLoad = url
            return
        }
        let target = url.isFileURL ? url.path : url.absoluteString
        let status = command("loadfile", args: [target, "replace"])
        if status < 0 {
            let message = String(cString: mpv_error_string(status))
            AppLog.add("播放", "直读加载失败（loadfile 返回 \(message)），目标：\(Self.sanitizedTarget(url))")
            forwardToDelegate { delegate, handle in
                delegate.mpvLoadFailed(mpv: handle, error: message)
            }
        }
    }

    /// 日志用的脱敏目标（L4）：本地文件只记文件名，直链只记 scheme＋host＋末段，
    /// 不把完整路径或带签名参数的完整 URL 落进可外发的日志
    private static func sanitizedTarget(_ url: URL) -> String {
        if url.isFileURL { return url.lastPathComponent }
        let scheme = url.scheme ?? "http"
        let host = url.host ?? ""
        return "\(scheme)://\(host)/…/\(url.lastPathComponent)"
    }

    func stopPlayback() {
        command("stop")
    }

    func togglePause() {
        getFlag(MPVProperty.pause) ? play() : pause()
    }

    func play() { setFlag(MPVProperty.pause, false) }
    func pause() { setFlag(MPVProperty.pause, true) }

    func seekAbsolute(_ seconds: Double) {
        command("seek", args: [String(format: "%.3f", seconds), "absolute"])
    }

    func seekRelative(_ delta: Double) {
        command("seek", args: [String(format: "%.3f", delta), "relative"])
    }

    func setRate(_ rate: Double) {
        guard mpv != nil else { return }
        var value = rate
        checkError(mpv_set_property(mpv, MPVProperty.speed, MPV_FORMAT_DOUBLE, &value), "speed")
    }

    func setAudioTrack(_ id: Int) {
        setIntProperty("aid", Int64(id))
    }

    func setSubtitleTrack(_ id: Int?) {
        guard mpv != nil else { return }
        if let id {
            setIntProperty("sid", Int64(id))
        } else {
            checkError(mpv_set_property_string(mpv, "sid", "no"), "sid=no")
        }
    }

    /// 副字幕轨（双字幕的第二条）：mpv 的 secondary-sid 与 sid 独立，可同时渲染
    func setSecondarySubtitleTrack(_ id: Int?) {
        guard mpv != nil else { return }
        if let id {
            setIntProperty("secondary-sid", Int64(id))
        } else {
            checkError(mpv_set_property_string(mpv, "secondary-sid", "no"), "secondary-sid=no")
        }
    }

    /// 字幕字号（mpv 的 sub-font-size，运行时可改，立即生效）
    func setSubtitleFontSize(_ size: Int) {
        setIntProperty("sub-font-size", Int64(size))
    }

    func addExternalSubtitle(_ url: URL) {
        // select：外挂字幕一旦挂上就直接启用（用户长按添加字幕即为明确意图）
        command("sub-add", args: [url.path, "select"])
    }

    /// 读取容器章节列表（标题可缺失）；没有章节返回空数组
    func readChapters() -> [(title: String?, time: Double)] {
        guard mpv != nil else { return [] }
        let count = Int(getInt("chapter-list/count"))
        guard count > 0 else { return [] }
        return (0..<count).map { i in
            (title: getString("chapter-list/\(i)/title"),
             time: getDouble("chapter-list/\(i)/time"))
        }
    }

    // MARK: - 属性读取

    func getDouble(_ name: String) -> Double {
        guard mpv != nil else { return 0 }
        var data = Double()
        mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
        return data
    }

    func getFlag(_ name: String) -> Bool {
        guard mpv != nil else { return false }
        var data = Int64()
        mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &data)
        return data > 0
    }

    private func setFlag(_ name: String, _ flag: Bool) {
        guard mpv != nil else { return }
        var data: Int32 = flag ? 1 : 0
        checkError(mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &data), "set \(name)")
    }

    private func setIntProperty(_ name: String, _ value: Int64) {
        guard mpv != nil else { return }
        var v = value
        checkError(mpv_set_property(mpv, name, MPV_FORMAT_INT64, &v), "set \(name)")
    }

    private func getInt(_ name: String) -> Int64 {
        guard mpv != nil else { return 0 }
        var data = Int64()
        mpv_get_property(mpv, name, MPV_FORMAT_INT64, &data)
        return data
    }

    private func getString(_ name: String) -> String? {
        guard mpv != nil else { return nil }
        let cstr = mpv_get_property_string(mpv, name)
        defer { mpv_free(cstr) }
        return cstr.map { String(cString: $0) }
    }

    /// 读取当前轨道列表（用逐项属性查询，避免解析 mpv_node 联合体）
    func readTracks() -> [MPVTrackInfo] {
        guard mpv != nil else { return [] }
        let count = Int(getInt("track-list/count"))
        guard count > 0 else { return [] }
        var tracks: [MPVTrackInfo] = []
        for i in 0..<count {
            let prefix = "track-list/\(i)"
            guard let type = getString("\(prefix)/type") else { continue }
            tracks.append(MPVTrackInfo(
                id: Int(getInt("\(prefix)/id")),
                type: type,
                lang: getString("\(prefix)/lang"),
                title: getString("\(prefix)/title"),
                codec: getString("\(prefix)/codec"),
                codecProfile: getString("\(prefix)/codec-profile"),
                channelCount: Int(getInt("\(prefix)/demux-channel-count")),
                ffIndex: Int(getInt("\(prefix)/ff-index")),
                isExternal: getFlag("\(prefix)/external"),
                isSelected: getFlag("\(prefix)/selected"),
                isForced: getFlag("\(prefix)/forced"),
                isDefault: getFlag("\(prefix)/default"),
                isHearingImpaired: getFlag("\(prefix)/hearing-impaired")
            ))
        }
        return tracks
    }

    /// 整数属性读取（供模型读旋转元数据等）
    func getIntValue(_ name: String) -> Int64 { getInt(name) }

    /// 视频实际显示宽高：width/height 是编码尺寸，竖拍视频带 rotate 元数据时要互换，
    /// 否则横竖判定会反（审查补充：原生路用 preferredTransform 是对的，直读路此前没处理）
    func videoDisplaySize() -> (width: Double, height: Double) {
        let w = getDouble(MPVProperty.width)
        let h = getDouble(MPVProperty.height)
        let rotate = getInt("video-params/rotate")
        if rotate == 90 || rotate == 270 { return (h, w) }
        return (w, h)
    }

    // MARK: - 命令

    /// 返回 mpv_command 的原始状态码（负数即错误码），调用方需要区分成败时可据此处理
    @discardableResult
    func command(_ command: String, args: [String?] = [], checkForErrors: Bool = true) -> CInt {
        guard mpv != nil else { return -1 }
        var cargs = makeCArgs(command, args).map { $0.flatMap { UnsafePointer<CChar>(strdup($0)) } }
        defer {
            for ptr in cargs where ptr != nil {
                free(UnsafeMutablePointer(mutating: ptr!))
            }
        }
        let returnValue = mpv_command(mpv, &cargs)
        if checkForErrors {
            checkError(returnValue, command)
        }
        return returnValue
    }

    private func makeCArgs(_ command: String, _ args: [String?]) -> [String?] {
        var strArgs = args
        strArgs.insert(command, at: 0)
        strArgs.append(nil)
        return strArgs
    }

    // MARK: - 事件排空（在 mpv 专用队列上执行，结果切回主线程给 delegate）

    func notifyEvents() {
        queue.async { [weak self] in
            self?.readEvents()
        }
    }

    private func readEvents() {
        while !eventsStopped, mpv != nil {
            let event = mpv_wait_event(mpv, 0)
            guard let event else { break }
            if event.pointee.event_id == MPV_EVENT_NONE { break }

            switch event.pointee.event_id {
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let dataPtr = event.pointee.data,
                      let property = UnsafePointer<mpv_event_property>(OpaquePointer(dataPtr))?.pointee,
                      let namePtr = property.name else { continue }
                let propertyName = String(cString: namePtr)
                let value: Any?
                switch property.format {
                case MPV_FORMAT_DOUBLE:
                    value = property.data.map { UnsafePointer<Double>(OpaquePointer($0))?.pointee }
                case MPV_FORMAT_FLAG:
                    value = property.data.map { (UnsafePointer<Int32>(OpaquePointer($0))?.pointee ?? 0) > 0 }
                default:
                    value = nil
                }
                forwardToDelegate { delegate, handle in
                    delegate.propertyChange(mpv: handle, propertyName: propertyName, data: value)
                }
            case MPV_EVENT_FILE_LOADED:
                forwardToDelegate { delegate, handle in delegate.mpvFileLoaded(mpv: handle) }
            case MPV_EVENT_END_FILE:
                var reason: Int32 = 0
                var errorText: String?
                if let dataPtr = event.pointee.data,
                   let endFile = UnsafePointer<mpv_event_end_file>(OpaquePointer(dataPtr))?.pointee {
                    reason = Int32(endFile.reason.rawValue)
                    if endFile.error < 0 {
                        errorText = String(cString: mpv_error_string(endFile.error))
                    }
                }
                forwardToDelegate { delegate, handle in
                    delegate.mpvEndFile(mpv: handle, reason: reason, error: errorText)
                }
            case MPV_EVENT_SHUTDOWN:
                // teardownPlayer 已负责 terminate；这里只停止排空
                return
            case MPV_EVENT_LOG_MESSAGE:
                break // 发布版已关日志；调试版也不转发，避免噪音
            default:
                break
            }
        }
    }

    private func forwardToDelegate(_ body: @escaping (MPVPlayerDelegate, OpaquePointer) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let delegate = self.playDelegate, self.mpv != nil else { return }
            body(delegate, self.mpv)
        }
    }

    private func checkError(_ status: CInt, _ context: String) {
        if status < 0 {
            AppLog.add("播放", "mpv \(context) 失败：\(String(cString: mpv_error_string(status)))")
        }
    }
}

/// mpv 轨道信息（控制器从 track-list 逐项读出的快照）
struct MPVTrackInfo {
    var id: Int
    var type: String        // "video" / "audio" / "sub"
    var lang: String?
    var title: String?
    var codec: String?
    /// 编码 profile 原文（如 "Dolby Digital Plus + Dolby Atmos"）；只有该轨已被解码后才有值
    var codecProfile: String?
    /// 容器声道数（demux-channel-count，不一定准，仅作标注参考）
    var channelCount: Int
    /// lavf 流索引（非 lavf demuxer 时可能不准，供 FFmpeg probe 对位时二次校验）
    var ffIndex: Int
    var isExternal: Bool
    var isSelected: Bool
    var isForced: Bool
    var isDefault: Bool
    var isHearingImpaired: Bool
}

// MARK: - 字幕字体安装（随包 Noto Sans CJK SC，全字重）

/// libass 在 iOS 上靠 CoreText 回退拿字体名、再用 FreeType 打开字体文件本体；
/// 中文回退字体 PingFang 只在 PrivateFrameworks 里，沙盒 App 打不开，中文字幕必然全灭成方框。
/// 已验证的解法是随包带完整字体并装进 mpv 的 config-dir 体系（见 subtitle-font.md）：
/// fonts/ 是 libass 的默认字体库目录，根下的 subfont.ttf 是 libass 无条件兜底，
/// 另由 setupMpv 显式设 sub-fonts-dir（包内目录）＋ sub-font（family 名）双保险。
enum SubtitleFontInstaller {
    /// mpv 的 config-dir：App 沙盒内受控目录（Application Support/LumenMPV）
    static var configDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LumenMPV", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 包内字体目录（工程 SubtitleFonts 文件夹引用，内含全字重 OTF 与 OFL.txt）
    static var bundleFontsDirectory: URL? {
        Bundle.main.url(forResource: "SubtitleFonts", withExtension: nil)
    }

    private static let installLock = NSLock()
    private static var installStarted = false

    /// 全量安装走后台（7 份 OTF 约 115MB 的拷贝不压主线程）；App 启动时与播放器初始化时都会触发，只跑一次
    static func installAllInBackground() {
        installLock.lock()
        guard !installStarted else { installLock.unlock(); return }
        installStarted = true
        installLock.unlock()
        DispatchQueue.global(qos: .utility).async { installAll() }
    }

    static func installAll() {
        guard let bundleDir = bundleFontsDirectory else {
            AppLog.add("播放", "字幕字体：包内 SubtitleFonts 目录缺失，无法安装")
            return
        }
        let fm = FileManager.default
        let fontsDir = configDirectory.appendingPathComponent("fonts", isDirectory: true)
        try? fm.createDirectory(at: fontsDir, withIntermediateDirectories: true)
        let names = (try? fm.contentsOfDirectory(atPath: bundleDir.path)) ?? []
        var copied = 0
        for name in names where name.hasSuffix(".otf") {
            if copyIfNeeded(from: bundleDir.appendingPathComponent(name),
                            to: fontsDir.appendingPathComponent(name)) {
                copied += 1
            }
        }
        ensureSubfontFallback()
        AppLog.add("播放", "字幕字体安装完成：config-dir=\(configDirectory.path)，本次复制 \(copied) 份，sub-fonts-dir=\(bundleDir.path)")
    }

    /// initialize 前的最小同步兜底：只保证 subfont.ttf 在位（单份拷贝，很快），全量安装随后台完成
    static func ensureSubfontFallback() {
        guard let bundleDir = bundleFontsDirectory else { return }
        let src = bundleDir.appendingPathComponent("NotoSansCJKsc-Regular.otf")
        let dst = configDirectory.appendingPathComponent("subfont.ttf")
        _ = copyIfNeeded(from: src, to: dst)
    }

    @discardableResult
    private static func copyIfNeeded(from src: URL, to dst: URL) -> Bool {
        let fm = FileManager.default
        let srcSize = (try? src.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        let dstSize = (try? dst.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        if let srcSize, srcSize == dstSize, fm.fileExists(atPath: dst.path) { return false }
        try? fm.removeItem(at: dst)
        do {
            try fm.copyItem(at: src, to: dst)
            return true
        } catch {
            return false
        }
    }
}
