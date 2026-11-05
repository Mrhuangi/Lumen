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

    private lazy var queue = DispatchQueue(label: "lumen.mpv.events", qos: .userInitiated)
    private var pendingLoad: (url: URL, startAt: Double?)?
    private var wasPlayingBeforeBackground = false

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
            loadFile(pending.url, startAt: pending.startAt)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        metalLayer.frame = view.bounds
    }

    // MARK: - mpv 初始化

    private func setupMpv() {
        guard let created = mpv_create() else {
            AppLog.add("播放", "mpv 初始化失败：mpv_create 返回空")
            return
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

        checkError(mpv_initialize(mpv), "mpv_initialize")

        mpv_observe_property(mpv, 0, MPVProperty.timePos, MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, MPVProperty.duration, MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, MPVProperty.pause, MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, MPVProperty.pausedForCache, MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, MPVProperty.trackList, MPV_FORMAT_NONE)
        mpv_observe_property(mpv, 0, MPVProperty.chapterList, MPV_FORMAT_NONE)
        mpv_observe_property(mpv, 0, MPVProperty.videoParamsSigPeak, MPV_FORMAT_DOUBLE)
        mpv_set_wakeup_callback(mpv, mpvWakeupTrampoline,
                                UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
    }

    private func setOption(_ name: String, _ value: String) {
        guard mpv != nil else { return }
        checkError(mpv_set_option_string(mpv, name, value), "set \(name)=\(value)")
    }

    /// 销毁 mpv 实例（Representable 拆卸时调用）：先摘回调再 terminate，避免事件排空时访问已释放对象
    func teardownPlayer() {
        guard mpv != nil else { return }
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
        // 进后台关掉视频输出，避免 Metal 命令缓冲被系统拒绝
        checkError(mpv_set_option_string(mpv, "vid", "no"), "vid=no")
    }

    @objc private func enterForeground() {
        guard mpv != nil else { return }
        checkError(mpv_set_option_string(mpv, "vid", "auto"), "vid=auto")
        if wasPlayingBeforeBackground { play() }
    }

    // MARK: - 播放控制（供 MPVPlayerModel 调用）

    func loadFile(_ url: URL, startAt: Double? = nil) {
        guard mpv != nil else {
            pendingLoad = (url, startAt)
            return
        }
        var args: [String?] = [url.absoluteString, "replace"]
        if let startAt, startAt > 3 {
            args.append("start=\(String(format: "%.2f", startAt))")
        }
        command("loadfile", args: args)
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
                isExternal: getFlag("\(prefix)/external"),
                isSelected: getFlag("\(prefix)/selected")
            ))
        }
        return tracks
    }

    // MARK: - 命令

    func command(_ command: String, args: [String?] = [], checkForErrors: Bool = true) {
        guard mpv != nil else { return }
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
        while mpv != nil {
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
    var isExternal: Bool
    var isSelected: Bool
}
