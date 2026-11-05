import Foundation
import Libavcodec
import Libavformat
import Libavutil

// MARK: - 错误与结果

enum FFmpegRemuxError: LocalizedError, Equatable {
    case openInputFailed(String)
    case findStreamInfoFailed(String)
    case noVideoStream
    case unsupportedVideoCodec(String)
    case dolbyVisionProfile7
    case noCompatibleAudio
    case cannotCreateOutput(String)
    case writeHeaderFailed(String)
    case writeFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .openInputFailed(let detail): return String(localized: "无法打开源文件：\(detail)")
        case .findStreamInfoFailed(let detail): return String(localized: "无法读取源文件信息：\(detail)")
        case .noVideoStream: return String(localized: "文件里没有视频轨")
        case .unsupportedVideoCodec(let codec): return String(localized: "视频编码 \(codec) 无法用系统播放器播放")
        case .dolbyVisionProfile7: return String(localized: "Profile 7（双层高动态范围）暂不支持系统原生播放")
        case .noCompatibleAudio: return String(localized: "没有系统播放器可解码的音轨")
        case .cannotCreateOutput(let detail): return String(localized: "无法创建输出文件：\(detail)")
        case .writeHeaderFailed(let detail): return String(localized: "写入 MP4 文件头失败：\(detail)")
        case .writeFailed(let detail): return String(localized: "写入 MP4 失败：\(detail)")
        case .cancelled: return String(localized: "重封装已取消")
        }
    }
}

/// 重封装时从内封文本字幕流提取出的字幕（旁路：由系统播放路径的叠加层渲染，不进 MP4）
struct FFmpegEmbeddedSubtitle: Codable {
    var lang: String
    var title: String
    var cues: [SubtitleCue]
}

struct FFmpegRemuxResult {
    var outputURL: URL
    /// 源文件是否带杜比视界配置记录（DOVI side data）
    var isDolbyVision: Bool
    var dvProfile: Int?
    /// 自检结论：回读输出文件确认 dvvC/dvcC 盒（或 dvh1/dvhe 入口）实际存在
    var outputVerifiedDolbyVision: Bool
    var durationSeconds: Double
    var warnings: [String]
    var embeddedSubtitles: [FFmpegEmbeddedSubtitle]

    /// 按与直读播放相同的策略挑内封中文字幕（外挂字幕文件优先的判断在调用方）
    func chineseSubtitleCues() -> [SubtitleCue]? {
        let candidates = embeddedSubtitles.map { sub in
            (sub, MPVTrack(id: 0, type: "sub", lang: sub.lang.isEmpty ? nil : sub.lang,
                           title: sub.title.isEmpty ? nil : sub.title, codec: nil, isExternal: false))
        }
        guard let best = candidates.filter({ $0.1.isChinese })
            .max(by: { $0.1.chinesePreferenceScore < $1.1.chinesePreferenceScore }) else { return nil }
        return best.0.cues.isEmpty ? nil : best.0.cues
    }
}

// MARK: - 重封装服务

/// FFmpeg 无损重封装（stream copy）：MKV 等容器 → MP4，只搬运压缩包、不解码。
/// 按前人实测结论落实的关键点（详见 research_notes/lumen-v1.1-prior-art-20261104）：
/// - 输出上下文 strict_std_compliance = -2（CLI 的 -strict -2），否则 movenc 静默拒写 dvvC；
/// - codec_tag 分工：DV Profile 5 → dvh1；Profile 8 等 → hvc1，由 muxer 连同 dvvC 一起生成；
/// - 逐流挑拣：只收 HEVC/H.264 视频＋AAC/AC3/E-AC3 音轨；TrueHD/DTS 等系统不解的音轨整片降级；
///   Profile 7 双层 DV 降级；PGS 等图形字幕剔除、文本字幕提取为旁路 cues（不进 MP4）；
/// - 输入开 AVFMT_FLAG_GENPTS 应对 MKV 时间戳毛病；不做 faststart（本地文件播放不需要）；
/// - 完成后回读输出文件自检（sample entry / dvvC / 音轨盒），结论写日志并体现在结果里。
/// 全程 av_read_frame 主循环，任何错误即退出——不存在手写解析器那种原地打转的可能。
final class FFmpegRemuxer {

    private let cancelLock = NSLock()
    private var cancelRequested = false

    func cancel() {
        cancelLock.lock()
        cancelRequested = true
        cancelLock.unlock()
    }

    private var isCancelled: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelRequested
    }

    // MARK: 主流程（同步执行，调用方负责调度到后台线程）

    func remux(input: URL, progress: @escaping (Double) -> Void) throws -> FFmpegRemuxResult {
        av_log_set_level(16) // AV_LOG_ERROR：只留错误级日志，避免控制台噪音

        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let outName = input.deletingPathExtension().lastPathComponent + ".mp4"
        let outURL = cachesDir.appendingPathComponent(outName)
        let sidecarURL = cachesDir.appendingPathComponent(outName + ".subs.json")

        // 指纹缓存命中：产物与字幕旁路都还在 → 直接复用
        if let fingerprint = Self.sourceFingerprint(input),
           let saved = Self.stampIndex()[outName],
           saved.hasPrefix(fingerprint + "|"),
           FileManager.default.fileExists(atPath: outURL.path) {
            let parts = saved.split(separator: "|", omittingEmptySubsequences: false)
            if parts.count == 6 {
                let subs = (try? Data(contentsOf: sidecarURL))
                    .flatMap { try? JSONDecoder().decode([FFmpegEmbeddedSubtitle].self, from: $0) } ?? []
                AppLog.add("播放", "重封装缓存命中，跳过重封装：\(outName)")
                progress(1.0)
                return FFmpegRemuxResult(outputURL: outURL,
                                         isDolbyVision: parts[3] == "1",
                                         dvProfile: Int(parts[4]).flatMap { $0 >= 0 ? $0 : nil },
                                         outputVerifiedDolbyVision: parts[5] == "1",
                                         durationSeconds: Double(parts[2]) ?? 0,
                                         warnings: [],
                                         embeddedSubtitles: subs)
            }
        }

        let result = try performRemux(input: input, output: outURL, progress: progress)

        // 字幕旁路落盘（与缓存 MP4 同生命周期），再写指纹索引并修剪旧产物
        if !result.embeddedSubtitles.isEmpty,
           let data = try? JSONEncoder().encode(result.embeddedSubtitles) {
            try? data.write(to: sidecarURL)
        }
        if let fingerprint = Self.sourceFingerprint(input) {
            var index = Self.stampIndex()
            let counter = (index.values.compactMap { Int($0.split(separator: "|").first ?? "") }.max() ?? 0) + 1
            let stamp = [String(counter), fingerprint,
                         String(result.durationSeconds),
                         result.isDolbyVision ? "1" : "0",
                         String(result.dvProfile ?? -1),
                         result.outputVerifiedDolbyVision ? "1" : "0"].joined(separator: "|")
            index[outName] = stamp
            Self.pruneCache(cachesDir: cachesDir, index: &index, keep: 2)
            UserDefaults.standard.set(index, forKey: Self.stampKey)
        }
        return result
    }

    // MARK: - 实际重封装

    private func performRemux(input: URL, output: URL, progress: @escaping (Double) -> Void) throws -> FFmpegRemuxResult {
        var warnings: [String] = []

        var inCtx: UnsafeMutablePointer<AVFormatContext>?
        let inputPath = input.isFileURL ? input.path : input.absoluteString
        var ret = avformat_open_input(&inCtx, inputPath, nil, nil)
        guard ret >= 0, let inFmt = inCtx else {
            throw FFmpegRemuxError.openInputFailed(Self.errorString(ret))
        }
        defer { avformat_close_input(&inCtx) }

        // MKV 时间戳靠 demuxer 推算 DTS，打开生成标志应对缺失/回退（前人实战组合）
        inFmt.pointee.flags |= 0x0400 // AVFMT_FLAG_GENPTS
        ret = avformat_find_stream_info(inFmt, nil)
        guard ret >= 0 else { throw FFmpegRemuxError.findStreamInfoFailed(Self.errorString(ret)) }

        let inputSize = (try? FileManager.default.attributesOfItem(atPath: input.path))?[.size] as? Int64 ?? 0
        let durationSeconds = inFmt.pointee.duration >= 0 ? Double(inFmt.pointee.duration) / 1_000_000.0 : 0

        // ---- 逐流分类 ----
        let streamCount = Int(inFmt.pointee.nb_streams)
        var inStreams: [UnsafeMutablePointer<AVStream>] = []
        for i in 0..<streamCount {
            if let s = inFmt.pointee.streams.advanced(by: i).pointee { inStreams.append(s) }
        }

        var videoIndex: Int?
        var audioIndices: [Int] = []
        var subtitleIndices: [Int] = []
        var hasAudioStream = false
        var skippedAudioNames: [String] = []
        var hasGraphicSubtitle = false
        var dvInfo: (profile: Int, elPresent: Bool, compatID: Int)?

        for (i, stream) in inStreams.enumerated() {
            guard let par = stream.pointee.codecpar else { continue }
            let codecID = par.pointee.codec_id
            switch par.pointee.codec_type.rawValue {
            case 0: // AVMEDIA_TYPE_VIDEO
                if stream.pointee.disposition & 0x0400 != 0 { continue } // AV_DISPOSITION_ATTACHED_PIC：封面图跳过
                if videoIndex == nil {
                    if codecID == Self.codecID("hevc") || codecID == Self.codecID("h264") {
                        videoIndex = i
                        if let dovi = Self.doviConfiguration(par) { dvInfo = dovi }
                    } else {
                        throw FFmpegRemuxError.unsupportedVideoCodec(Self.codecName(codecID))
                    }
                } else {
                    warnings.append(String(localized: "多余的视频轨已跳过"))
                }
            case 1: // AVMEDIA_TYPE_AUDIO
                hasAudioStream = true
                if codecID == Self.codecID("aac") || codecID == Self.codecID("ac3") || codecID == Self.codecID("eac3") {
                    audioIndices.append(i)
                    if codecID == Self.codecID("eac3"), par.pointee.profile == 30 {
                        AppLog.add("播放", "音轨 \(i)：E-AC3 带 Atmos（JOC profile=30）")
                    }
                } else {
                    skippedAudioNames.append(Self.codecName(codecID))
                }
            case 3: // AVMEDIA_TYPE_SUBTITLE
                if Self.textSubtitleCodecs.contains(codecID) {
                    subtitleIndices.append(i)
                } else {
                    hasGraphicSubtitle = true
                }
            default:
                break // data / attachment 等一概不进 MP4（对应 -map_chapters -1 的挑拣原则）
            }
        }

        guard let videoIdx = videoIndex else { throw FFmpegRemuxError.noVideoStream }

        // Profile 7（BL+EL 双层）AVPlayer 不能直通 → 整片降级直读播放（前人坑 7）
        if let dv = dvInfo, dv.profile == 7 {
            AppLog.add("播放", "高动态范围 Profile 7（双层）→ 降级直读播放")
            throw FFmpegRemuxError.dolbyVisionProfile7
        }
        // 有音轨却一条都进不了 MP4（如只有 TrueHD/DTS）→ 整片降级，避免无声播放（前人坑 4）
        if hasAudioStream, audioIndices.isEmpty {
            AppLog.add("播放", "音轨均为系统不解码格式（\(skippedAudioNames.joined(separator: "/"))）→ 降级直读播放")
            throw FFmpegRemuxError.noCompatibleAudio
        }
        if !skippedAudioNames.isEmpty {
            warnings.append(String(localized: "部分音轨格式系统不支持，已跳过：\(Set(skippedAudioNames).joined(separator: "、"))"))
        }
        if hasGraphicSubtitle {
            warnings.append(String(localized: "内封图形字幕（PGS 等）无法在系统播放中显示，可切换直读播放查看"))
        }

        // ---- 建输出 ----
        var outCtx: UnsafeMutablePointer<AVFormatContext>?
        ret = avformat_alloc_output_context2(&outCtx, nil, "mp4", output.path)
        guard ret >= 0, let outFmt = outCtx else {
            throw FFmpegRemuxError.cannotCreateOutput(Self.errorString(ret))
        }
        defer { avformat_free_context(outFmt) }
        // 命门：不设这个，movenc 会静默拒写 dvcC/dvvC，DV 悄悄退化成 HDR10（前人坑 1）
        outFmt.pointee.strict_std_compliance = -2 // FF_COMPLIANCE_EXPERIMENTAL（CLI 的 -strict -2）

        var outStreamByInIndex: [Int: UnsafeMutablePointer<AVStream>] = [:]
        var subtitleBuilders: [Int: SubtitleCueBuilder] = [:]

        func makeOutputStream(from inStream: UnsafeMutablePointer<AVStream>) -> UnsafeMutablePointer<AVStream>? {
            guard let outStream = avformat_new_stream(outFmt, nil),
                  let inPar = inStream.pointee.codecpar,
                  let outPar = outStream.pointee.codecpar else { return nil }
            guard avcodec_parameters_copy(outPar, inPar) >= 0 else { return nil }
            outStream.pointee.time_base = inStream.pointee.time_base
            // 语言/标题元数据带过去，系统播放器的轨道菜单能显示正确名称
            for key in ["language", "title"] {
                if let value = Self.metadataValue(inStream, key) {
                    var dict = outStream.pointee.metadata
                    av_dict_set(&dict, key, value, 0)
                    outStream.pointee.metadata = dict
                }
            }
            return outStream
        }

        // 视频流
        let inVideo = inStreams[videoIdx]
        guard let outVideo = makeOutputStream(from: inVideo),
              let outVideoPar = outVideo.pointee.codecpar else {
            throw FFmpegRemuxError.cannotCreateOutput(String(localized: "视频流创建失败"))
        }
        // DOVI side data 搬运自检（V2）：parameters_copy 理应带过来，缺失时手动从输入 codecpar 搬
        if let doviData = Self.doviSideData(inVideo.pointee.codecpar) {
            if Self.doviSideData(outVideoPar) == nil {
                Self.copyDoviSideData(from: inVideo.pointee.codecpar, to: outVideoPar)
                AppLog.add("播放", "动态元数据配置已手动搬运到输出流")
            }
            _ = doviData
        }
        // codec_tag 分工（前人 A4，Jellyfin 生产验证）：P5 → dvh1；其余 DV → hvc1；普通 HEVC 也用 hvc1
        if inVideo.pointee.codecpar?.pointee.codec_id == Self.codecID("hevc") {
            if let dv = dvInfo, dv.profile == 5 {
                outVideoPar.pointee.codec_tag = 0x3168_7664 // 'dvh1'
            } else {
                outVideoPar.pointee.codec_tag = 0x3163_7668 // 'hvc1'
            }
        } else {
            outVideoPar.pointee.codec_tag = 0 // H.264 交给 muxer 选 avc1
        }
        outStreamByInIndex[videoIdx] = outVideo

        // 音轨
        for i in audioIndices {
            if let outStream = makeOutputStream(from: inStreams[i]) {
                outStream.pointee.codecpar.pointee.codec_tag = 0
                outStreamByInIndex[i] = outStream
            } else {
                warnings.append(String(localized: "一条音轨创建失败，已跳过"))
            }
        }
        // 字幕只提取不写流（旁路 cues）
        for i in subtitleIndices {
            let stream = inStreams[i]
            subtitleBuilders[i] = SubtitleCueBuilder(
                codecID: stream.pointee.codecpar.pointee.codec_id,
                lang: Self.metadataValue(stream, "language") ?? "",
                title: Self.metadataValue(stream, "title") ?? "",
                timeBase: stream.pointee.time_base)
        }

        ret = avio_open(&outFmt.pointee.pb, output.path, 2) // AVIO_FLAG_WRITE
        guard ret >= 0 else { throw FFmpegRemuxError.cannotCreateOutput(Self.errorString(ret)) }
        ret = avformat_write_header(outFmt, nil)
        guard ret >= 0 else {
            avio_closep(&outFmt.pointee.pb)
            throw FFmpegRemuxError.writeHeaderFailed(Self.errorString(ret))
        }

        // ---- 包循环（官方 remuxing.c 同款结构；错误即退出） ----
        guard let packet = av_packet_alloc() else {
            avio_closep(&outFmt.pointee.pb)
            throw FFmpegRemuxError.cannotCreateOutput(String(localized: "av_packet_alloc 失败"))
        }
        defer { var p: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&p) }

        var packetCount = 0
        var wrotePackets = 0
        var firstVideoDTSLogged = false
        var readError: Int32 = 0

        while true {
            if packetCount % 512 == 0 {
                if isCancelled {
                    avio_closep(&outFmt.pointee.pb)
                    try? FileManager.default.removeItem(at: output)
                    throw FFmpegRemuxError.cancelled
                }
                if inputSize > 0, let pb = inFmt.pointee.pb {
                    progress(min(0.99, Double(avio_tell(pb)) / Double(inputSize)))
                }
            }
            let r = av_read_frame(inFmt, packet)
            if r < 0 { readError = r; break }
            packetCount += 1

            let srcIndex = Int(packet.pointee.stream_index)
            if let builder = subtitleBuilders[srcIndex] {
                builder.addPacket(packet)
                av_packet_unref(packet)
                continue
            }
            guard let outStream = outStreamByInIndex[srcIndex] else {
                av_packet_unref(packet)
                continue
            }
            let inStream = inStreams[srcIndex]
            if srcIndex == videoIdx, !firstVideoDTSLogged {
                firstVideoDTSLogged = true
                AppLog.add("播放", "首个视频包 pts=\(packet.pointee.pts) dts=\(packet.pointee.dts)（MKV 时间戳自检）")
            }
            av_packet_rescale_ts(packet, inStream.pointee.time_base, outStream.pointee.time_base)
            packet.pointee.stream_index = outStream.pointee.index
            packet.pointee.pos = -1
            let w = av_interleaved_write_frame(outFmt, packet) // 含包的所有权转移，不再 unref
            guard w >= 0 else {
                avio_closep(&outFmt.pointee.pb)
                try? FileManager.default.removeItem(at: output)
                throw FFmpegRemuxError.writeFailed(Self.errorString(w))
            }
            wrotePackets += 1
        }

        let trailerRet = av_write_trailer(outFmt)
        avio_closep(&outFmt.pointee.pb)
        guard trailerRet >= 0, wrotePackets > 0 else {
            try? FileManager.default.removeItem(at: output)
            throw FFmpegRemuxError.writeFailed(readError != 0 ? Self.errorString(readError) : String(localized: "没有写出任何数据包"))
        }
        progress(1.0)

        // ---- 输出自检（回读校验，不靠猜） ----
        let check = Self.verifyOutput(output)
        let isDV = dvInfo != nil
        var verified = false
        if isDV {
            verified = check.hasDoviConfig || check.videoTag == 0x3168_7664 || check.videoTag == 0x6568_7664
            AppLog.add("播放", "重封装自检：视频入口=\(Self.tagString(check.videoTag)) 动态元数据盒=\(check.hasDoviConfig ? "有" : "无") 音轨=\(check.audioSummary)")
            if !verified {
                warnings.append(String(localized: "高动态范围配置未写入输出文件（自检未通过），将按普通 HDR 播放"))
            }
        } else {
            AppLog.add("播放", "重封装自检：视频入口=\(Self.tagString(check.videoTag)) 音轨=\(check.audioSummary)")
        }
        AppLog.add("播放", "重封装完成：\(output.lastPathComponent)（\(wrotePackets) 个数据包）")

        let subtitles = subtitleBuilders.values
            .map { $0.finish() }
            .filter { !$0.cues.isEmpty }
            .sorted { $0.lang < $1.lang }
        return FFmpegRemuxResult(outputURL: output,
                                 isDolbyVision: isDV,
                                 dvProfile: dvInfo?.profile,
                                 outputVerifiedDolbyVision: verified,
                                 durationSeconds: durationSeconds,
                                 warnings: warnings,
                                 embeddedSubtitles: subtitles)
    }

    // MARK: - 输出自检

    private struct OutputCheck {
        var videoTag: UInt32 = 0
        var hasDoviConfig = false
        var audioSummary: String = String(localized: "无")
    }

    /// 回读刚写出的 MP4：确认视频 sample entry、DOVI 配置盒与音轨构成（只读文件头，开销可忽略）
    private static func verifyOutput(_ url: URL) -> OutputCheck {
        var check = OutputCheck()
        var ctx: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&ctx, url.path, nil, nil) >= 0, let fmt = ctx else { return check }
        defer { avformat_close_input(&ctx) }
        guard avformat_find_stream_info(fmt, nil) >= 0 else { return check }
        var audioParts: [String] = []
        for i in 0..<Int(fmt.pointee.nb_streams) {
            guard let stream = fmt.pointee.streams.advanced(by: i).pointee,
                  let par = stream.pointee.codecpar else { continue }
            switch par.pointee.codec_type.rawValue {
            case 0:
                check.videoTag = par.pointee.codec_tag
                if doviSideData(par) != nil { check.hasDoviConfig = true }
            case 1:
                audioParts.append("\(codecName(par.pointee.codec_id))/\(tagString(par.pointee.codec_tag))")
            default:
                break
            }
        }
        if !audioParts.isEmpty { check.audioSummary = audioParts.joined(separator: ",") }
        return check
    }

    // MARK: - DOVI 工具

    /// 从 codecpar 的 coded_side_data 里找 DOVI 配置记录（AV_PKT_DATA_DOVI_CONF = 29，2019 年定版后从未变更）
    private static func doviSideData(_ par: UnsafeMutablePointer<AVCodecParameters>?) -> Data? {
        guard let par else { return nil }
        let count = Int(par.pointee.nb_coded_side_data)
        guard count > 0, let array = par.pointee.coded_side_data else { return nil }
        for i in 0..<count {
            let sd = array.advanced(by: i).pointee
            if sd.type.rawValue == 29, let data = sd.data, sd.size > 0 {
                return Data(bytes: data, count: sd.size)
            }
        }
        return nil
    }

    /// 解析 AVDOVIDecoderConfigurationRecord：profile / 是否带增强层 / 兼容 ID
    private static func doviConfiguration(_ par: UnsafeMutablePointer<AVCodecParameters>?) -> (profile: Int, elPresent: Bool, compatID: Int)? {
        guard let data = doviSideData(par), data.count >= 5 else { return nil }
        let b = [UInt8](data)
        let field = (UInt16(b[2]) << 8) | UInt16(b[3])
        let profile = Int((field >> 9) & 0x7F)
        let el = ((field >> 1) & 0x1) == 1
        let compat = Int(b[4] >> 4)
        return (profile, el, compat)
    }

    /// parameters_copy 没带过来时，手动把 DOVI side data 深拷贝到输出 codecpar
    private static func copyDoviSideData(from src: UnsafeMutablePointer<AVCodecParameters>?,
                                         to dst: UnsafeMutablePointer<AVCodecParameters>) {
        guard let src, let data = doviSideData(src) else { return }
        // type 直接沿用源元素上的枚举值，避免构造枚举常量的跨版本不确定性
        let count = Int(src.pointee.nb_coded_side_data)
        guard let array = src.pointee.coded_side_data else { return }
        for i in 0..<count {
            let sd = array.advanced(by: i).pointee
            if sd.type.rawValue == 29 {
                if let created = av_packet_side_data_new(&dst.pointee.coded_side_data,
                                                         &dst.pointee.nb_coded_side_data,
                                                         sd.type, data.count, 0),
                   let dstData = created.pointee.data {
                    data.withUnsafeBytes { _ = memcpy(dstData, $0.baseAddress, data.count) }
                }
                return
            }
        }
    }

    // MARK: - 小工具

    private static var codecIDCache: [String: AVCodecID] = [:]

    /// 按名查 codec id（avcodec_descriptor_get_by_name），避免硬编码数值随 FFmpeg 版本漂移
    static func codecID(_ name: String) -> AVCodecID? {
        if let hit = codecIDCache[name] { return hit }
        guard let id = avcodec_descriptor_get_by_name(name)?.pointee.id else { return nil }
        codecIDCache[name] = id
        return id
    }

    private static func codecName(_ id: AVCodecID) -> String {
        guard let desc = avcodec_descriptor_get(id), let namePtr = desc.pointee.name else {
            return String(localized: "未知编码")
        }
        return String(cString: namePtr)
    }

    private static let textSubtitleCodecs: Set<AVCodecID> = {
        Set(["subrip", "text", "ssa", "ass", "srt", "mov_text", "webvtt"].compactMap { codecID($0) })
    }()

    private static func metadataValue(_ stream: UnsafeMutablePointer<AVStream>?, _ key: String) -> String? {
        // 注：AVDictionary 在当前 FFmpeg 模块化下无法直接写出类型名（编译器找不到），
        // 故从 AVStream 入手、让 metadata 的类型由编译器推断，不显式命名。
        guard let stream, let dict = stream.pointee.metadata,
              let entry = av_dict_get(dict, key, nil, 0),
              let valuePtr = entry.pointee.value else { return nil }
        return String(cString: valuePtr)
    }

    private static func errorString(_ code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 512)
        av_strerror(code, &buffer, buffer.count)
        return String(cString: buffer)
    }

    private static func tagString(_ tag: UInt32) -> String {
        let bytes: [UInt8] = [UInt8(tag & 0xff), UInt8((tag >> 8) & 0xff),
                              UInt8((tag >> 16) & 0xff), UInt8((tag >> 24) & 0xff)]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "-"
    }

    // MARK: - 缓存指纹（沿用旧实现的思路：路径+大小+修改时间，产物只留最近 2 个）

    private static let stampKey = "remux.cache.v1"

    private static func sourceFingerprint(_ input: URL) -> String? {
        guard let values = try? input.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let mtime = values.contentModificationDate else { return nil }
        return "\(input.path)|\(size)|\(Int(mtime.timeIntervalSince1970))"
    }

    private static func stampIndex() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: stampKey) as? [String: String] ?? [:]
    }

    private static func pruneCache(cachesDir: URL, index: inout [String: String], keep: Int) {
        guard index.count > keep else { return }
        let sorted = index.sorted {
            (Int($0.value.split(separator: "|").first ?? "") ?? 0) < (Int($1.value.split(separator: "|").first ?? "") ?? 0)
        }
        for (name, _) in sorted.prefix(index.count - keep) {
            try? FileManager.default.removeItem(at: cachesDir.appendingPathComponent(name))
            try? FileManager.default.removeItem(at: cachesDir.appendingPathComponent(name + ".subs.json"))
            index.removeValue(forKey: name)
        }
    }

    /// 清除全部重封装缓存（设置页调用）：产物 MP4、字幕旁路与指纹索引一并清掉
    static func clearCache() {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        for name in stampIndex().keys {
            try? FileManager.default.removeItem(at: cachesDir.appendingPathComponent(name))
            try? FileManager.default.removeItem(at: cachesDir.appendingPathComponent(name + ".subs.json"))
        }
        UserDefaults.standard.removeObject(forKey: stampKey)
    }
}

// MARK: - 字幕包收集（文本字幕流 → cues）

/// 把一条文本字幕流的数据包逐个转成 SubtitleCue：时间取包的 pts/duration，文本按编码清洗。
/// MKV 的 S_TEXT/UTF8 包即纯文本；ASS 包走 SubtitleTools 的 MKV 块清洗；WebVTT 同理；
/// mov_text 包是「2 字节长度前缀＋UTF-8」序列，逐段取出。
private final class SubtitleCueBuilder {
    let codecID: AVCodecID
    let lang: String
    let title: String
    let timeBase: AVRational
    private var cues: [SubtitleCue] = []

    init(codecID: AVCodecID, lang: String, title: String, timeBase: AVRational) {
        self.codecID = codecID
        self.lang = lang
        self.title = title
        self.timeBase = timeBase
    }

    func addPacket(_ packet: UnsafeMutablePointer<AVPacket>) {
        let pts = packet.pointee.pts
        guard pts != Int64.max, let dataPtr = packet.pointee.data, packet.pointee.size > 0 else { return }
        let data = Data(bytes: dataPtr, count: Int(packet.pointee.size))
        let raw = String(decoding: data, as: UTF8.self)
        let text: String
        if codecID == FFmpegRemuxer.codecID("ass") || codecID == FFmpegRemuxer.codecID("ssa") {
            text = SubtitleParser.textFromMKVASSBlock(raw)
        } else if codecID == FFmpegRemuxer.codecID("webvtt") {
            text = SubtitleParser.textFromMKVWebVTTBlock(raw)
        } else if codecID == FFmpegRemuxer.codecID("mov_text") {
            text = Self.movText(from: data)
        } else {
            text = SubtitleParser.stripTags(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { return }
        let scale = Double(timeBase.num) / Double(timeBase.den)
        let start = Double(pts) * scale
        let duration = packet.pointee.duration > 0 ? Double(packet.pointee.duration) * scale : 0
        cues.append(SubtitleCue(start: start, end: start + duration, text: text))
    }

    func finish() -> FFmpegEmbeddedSubtitle {
        var sorted = cues.sorted { $0.start < $1.start }
        for i in sorted.indices {
            if sorted[i].end <= sorted[i].start {
                let next = i + 1 < sorted.count ? sorted[i + 1].start : sorted[i].start + 3
                sorted[i].end = min(max(next, sorted[i].start + 0.5), sorted[i].start + 10)
            }
        }
        return FFmpegEmbeddedSubtitle(lang: lang, title: title, cues: sorted)
    }

    private static func movText(from data: Data) -> String {
        var parts: [String] = []
        var offset = 0
        let bytes = [UInt8](data)
        while offset + 2 <= bytes.count {
            let length = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
            offset += 2
            guard length > 0, offset + length <= bytes.count else { break }
            parts.append(String(decoding: bytes[offset..<(offset + length)], as: UTF8.self))
            offset += length
        }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
