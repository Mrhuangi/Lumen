import AVFoundation
import SwiftUI
import UIKit

/// 直读播放（mpv）的自建控制层：参照 Apple TV App / 系统播放器的设计语言——
/// SF Symbols 图标、Liquid Glass 材质、系统字阶、原生 Menu 与面板。
///
/// 控件显隐只有一个数据源：PlayerScreen 持有的 chromeVisible（本视图通过 Binding 读写）。
/// 本视图负责的交互：单击切换显隐、双击两侧快退/快进 10 秒、拖动进度（带抽帧预览）、
/// 轨道/倍速/章节菜单、字幕面板（主/副双字幕）、选集面板、更多设置。
/// 自动隐藏的计时在 PlayerScreen 统一处理；本视图在拖动或面板打开时通过
/// chromeSuspended 通知上层暂停计时。
struct MPVControlsView: View {
    @ObservedObject var model: MPVPlayerModel
    @Binding var chromeVisible: Bool
    @Binding var chromeSuspended: Bool
    /// 任意交互后调用：唤出控件并重置上层的自动隐藏计时
    let poke: () -> Void

    let episodes: [MediaItem]
    let currentEpisodeID: UUID
    let onSelectEpisode: (MediaItem) -> Void
    let onPrevious: (() -> Void)?
    let onNext: (() -> Void)?
    let onLoadLocalSubtitle: () -> Void
    let stillProvider: (MediaItem) -> UIImage?

    @AppStorage(PlayerSettings.showPrevNextKey) private var showPrevNextButtons = true
    @AppStorage(PlayerSettings.showSeekButtonsKey) private var showSeekButtons = true

    @State private var scrubValue: Double?
    @State private var flashVisible = false
    @State private var showSubtitlePanel = false
    @State private var showMoreSettings = false
    @State private var showEpisodes = false
    @State private var previewImage: UIImage?
    @State private var previewSecond = -1
    @State private var previewTask: Task<Void, Never>?

    private static let rates: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]

    private var panelOpen: Bool { showSubtitlePanel || showMoreSettings || showEpisodes }

    var body: some View {
        ZStack {
            tapSurface
            if model.isBuffering {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            } else if model.isPaused || chromeVisible {
                centerPlayButton
            }
            if let flash = model.seekFlash, flashVisible {
                seekFlashView(forward: flash.forward)
            }
            if model.outroPromptVisible {
                outroButton
            }
            if chromeVisible {
                bottomBar
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: chromeVisible)
        .onChange(of: model.seekFlash?.counter) { _, _ in
            flashVisible = true
            Task {
                try? await Task.sleep(for: .milliseconds(650))
                flashVisible = false
            }
        }
        .onChange(of: scrubValue) { _, _ in syncSuspended() }
        .onChange(of: panelOpen) { _, _ in syncSuspended(); if panelOpen { poke() } }
        .sheet(isPresented: $showSubtitlePanel) {
            SubtitlePanelView(model: model, onLoadLocalSubtitle: onLoadLocalSubtitle)
        }
        .sheet(isPresented: $showMoreSettings) {
            PlayerMoreSettingsView()
        }
        .sheet(isPresented: $showEpisodes) {
            EpisodePanelView(episodes: episodes, currentID: currentEpisodeID,
                             stillProvider: stillProvider) { item in
                showEpisodes = false
                onSelectEpisode(item)
            }
        }
    }

    private func syncSuspended() {
        chromeSuspended = (scrubValue != nil) || panelOpen
    }

    // MARK: 手势层（单击切换隐显；左右双击快退/快进）

    private var tapSurface: some View {
        HStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.seekBy(-10); poke() }
                .onTapGesture { toggleChrome() }
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggleChrome() }
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.seekBy(10); poke() }
                .onTapGesture { toggleChrome() }
        }
    }

    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.25)) { chromeVisible.toggle() }
        if chromeVisible { poke() }
    }

    // MARK: 中央播放键（大而克制，玻璃圆钮）

    private var centerPlayButton: some View {
        Button {
            model.togglePlayPause()
            poke()
        } label: {
            Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .accessibilityLabel(model.isPaused ? "播放" : "暂停")
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
    }

    private func seekFlashView(forward: Bool) -> some View {
        HStack {
            if !forward {
                flashIcon(forward: false)
                Spacer()
            } else {
                Spacer()
                flashIcon(forward: true)
            }
        }
        .padding(.horizontal, 56)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private func flashIcon(forward: Bool) -> some View {
        Image(systemName: forward ? "goforward.10" : "gobackward.10")
            .font(.system(size: 34, weight: .regular))
            .foregroundStyle(.white)
            .frame(width: 64, height: 64)
            .glassEffect(.regular, in: Circle())
    }

    // MARK: 跳过片尾（片尾窗口内显示，不随控件显隐——出现即是提示本身）

    private var outroButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    model.skipOutro()
                } label: {
                    Label("跳过片尾", systemImage: "forward.end.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect(.regular.interactive(), in: Capsule())
                }
            }
            .padding(.trailing, 16)
            .padding(.bottom, chromeVisible ? 128 : 30)
        }
        .animation(.easeInOut(duration: 0.25), value: chromeVisible)
        .transition(.opacity)
    }

    // MARK: 底部控制条
    //
    // 宽度自适应（1.2.1 修复）：按钮全是固定 40pt 宽，单行全开最满约需 629pt，
    // 远大于小屏竖屏的可用宽（375 − 32 面板边距 − 36 内边距 = 307pt）。
    // 固定宽子视图不会收缩，HStack 只会把理想宽报给父级，整套 chrome 被撑出屏幕、
    // 居中后两头一起裁（SE3 竖屏标题贴边、关闭按钮出界、面板两头按钮被切的同一根源）。
    // 故按实测宽度分档：< 700pt 用双行紧凑排布（每行都留有余量），≥ 700pt 用单行
    // （此时内容宽 ≥ 632pt，单行最满 629pt 恰好装得下）。

    private var bottomBar: some View {
        GeometryReader { geo in
            VStack {
                Spacer()
                if let target = scrubValue {
                    scrubPreview(target)
                }
                VStack(spacing: 10) {
                    progressRow
                    if geo.size.width < 700 {
                        compactButtonRows
                    } else {
                        wideButtonRow
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var progressRow: some View {
        HStack(spacing: 12) {
            Text(Self.timeText(scrubValue ?? model.position))
                .frame(width: 52, alignment: .leading)
            progressWithChapters
            Text(Self.timeText(model.duration))
                .frame(width: 52, alignment: .trailing)
        }
        .font(.footnote.monospacedDigit())
        .foregroundStyle(.white)
    }

    /// 宽屏单行（总宽 ≥ 700pt、内容宽 ≥ 632pt 时才走这里；固定宽最满约 629pt）
    private var wideButtonRow: some View {
        HStack(spacing: 8) {
            rateMenu()
            if !model.chapters.isEmpty { chaptersMenu }
            Spacer(minLength: 4)
            transportButtons
            Spacer(minLength: 4)
            controlButton("captions.bubble.fill", label: "字幕") { showSubtitlePanel = true }
            audioMenu
            if episodes.count > 1 {
                controlButton("list.bullet", label: "选集") { showEpisodes = true }
            }
            controlButton("ellipsis.circle", label: "更多设置") { showMoreSettings = true }
        }
    }

    /// 窄屏双行：上行放功能键（倍速/章节靠左，字幕/音轨/选集/更多靠右），下行走带键居中。
    /// 375pt 可用 307pt：上行最满约 294pt（倍速键在紧凑档去掉图标只留倍率数字）、
    /// 下行最满约 236pt，均不溢出。
    private var compactButtonRows: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                rateMenu(compact: true)
                if !model.chapters.isEmpty { chaptersMenu }
                Spacer(minLength: 4)
                controlButton("captions.bubble.fill", label: "字幕") { showSubtitlePanel = true }
                audioMenu
                if episodes.count > 1 {
                    controlButton("list.bullet", label: "选集") { showEpisodes = true }
                }
                controlButton("ellipsis.circle", label: "更多设置") { showMoreSettings = true }
            }
            HStack(spacing: 8) {
                Spacer()
                transportButtons
                Spacer()
            }
        }
    }

    /// 走带键组（快退/快进与上/下集按设置开关出现，两档排布共用）
    @ViewBuilder
    private var transportButtons: some View {
        if showSeekButtons {
            controlButton("gobackward.10", label: "快退 10 秒") { model.seekBy(-10) }
        }
        if showPrevNextButtons, let onPrevious {
            controlButton("backward.end.fill", label: "上一集") { onPrevious() }
        }
        playPauseButton
        if showPrevNextButtons, let onNext {
            controlButton("forward.end.fill", label: "下一集") { onNext() }
        }
        if showSeekButtons {
            controlButton("goforward.10", label: "快进 10 秒") { model.seekBy(10) }
        }
    }

    /// 进度 Slider ＋ 章节标记点（有章节才叠加）
    private var progressWithChapters: some View {
        ZStack {
            Slider(
                value: Binding(
                    get: { scrubValue ?? model.position },
                    set: { newValue in
                        scrubValue = newValue
                        schedulePreview(for: newValue)
                    }
                ),
                in: 0...max(model.duration, 1)
            ) { editing in
                poke()
                if !editing, let target = scrubValue {
                    model.seek(to: target)
                    scrubValue = nil
                    previewImage = nil
                    previewSecond = -1
                }
            }
            .tint(.white)
            if !model.chapters.isEmpty, model.duration > 0 {
                GeometryReader { geo in
                    ForEach(model.chapters) { chapter in
                        Circle()
                            .fill(.white.opacity(0.85))
                            .frame(width: 4, height: 4)
                            .position(x: geo.size.width * CGFloat(chapter.time / model.duration),
                                      y: geo.size.height / 2)
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }

    /// 拖动预览：目标时间＋该位置的本地抽帧图（抽不到帧时只显示时间，绝不阻塞主线程）
    private func scrubPreview(_ target: Double) -> some View {
        VStack(spacing: 6) {
            if let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 144, height: 81)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            Text(Self.timeText(target))
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: Capsule())
        }
        .padding(.bottom, 10)
        .transition(.opacity)
    }

    private func schedulePreview(for target: Double) {
        let second = Int(target.rounded())
        guard second != previewSecond else { return }
        previewTask?.cancel()
        let url = model.currentURL
        previewTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            if Task.isCancelled { return }
            let image = await ScrubPreviewGenerator.image(for: url, at: target)
            if Task.isCancelled { return }
            previewSecond = second
            previewImage = image
        }
    }

    private var playPauseButton: some View {
        Button {
            model.togglePlayPause()
            poke()
        } label: {
            Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 32)
                .glassEffect(.regular.interactive(), in: Capsule())
        }
        .accessibilityLabel(model.isPaused ? "播放" : "暂停")
    }

    private func controlButton(_ systemImage: String, label: String,
                               action: @escaping () -> Void) -> some View {
        Button {
            action()
            poke()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 40, height: 32)
                .glassEffect(.regular.interactive(), in: Capsule())
        }
        .accessibilityLabel(label)
    }

    private func menuButton(_ systemImage: String, label: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 40, height: 32)
            .glassEffect(.regular.interactive(), in: Capsule())
            .accessibilityLabel(label)
    }

    /// 倍速菜单；紧凑档（窄屏双行）去掉图标、收窄内边距，只保留倍率数字，省出约 27pt
    private func rateMenu(compact: Bool = false) -> some View {
        Menu {
            ForEach(Self.rates, id: \.self) { value in
                Button {
                    model.setRate(value)
                    poke()
                } label: {
                    if value == model.rate {
                        Label(Self.rateText(value), systemImage: "checkmark")
                    } else {
                        Text(Self.rateText(value))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if !compact {
                    Image(systemName: "speedometer")
                        .font(.system(size: 15, weight: .medium))
                }
                Text(Self.rateText(model.rate))
                    .font(.subheadline.monospacedDigit())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 8 : 12)
            .frame(height: 32)
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .accessibilityLabel("播放速度")
    }

    private var chaptersMenu: some View {
        Menu {
            ForEach(model.chapters) { chapter in
                Button {
                    model.seek(to: chapter.time)
                    poke()
                } label: {
                    Text("\(chapter.displayTitle) · \(Self.timeText(chapter.time))")
                }
            }
        } label: {
            menuButton("bookmark.fill", label: "章节")
        }
    }

    private var audioMenu: some View {
        Menu {
            ForEach(model.audioTracks) { track in
                Button {
                    model.selectAudioTrack(track.id)
                    poke()
                } label: {
                    let label = track.codecLabel.isEmpty
                        ? track.displayName
                        : "\(track.displayName) · \(track.codecLabel)"
                    if track.id == model.selectedAudioID {
                        Label(label, systemImage: "checkmark")
                    } else {
                        Text(label)
                    }
                }
            }
        } label: {
            menuButton("waveform", label: "音轨")
        }
    }

    // MARK: 格式化

    static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    static func rateText(_ rate: Double) -> String {
        rate.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f×", rate)
            : String(format: "%g×", rate)
    }
}

// MARK: - 拖动预览抽帧（后台执行；系统解码器读不了的容器直接返回 nil，只显示时间）

enum ScrubPreviewGenerator {
    static func image(for url: URL?, at seconds: Double) async -> UIImage? {
        guard let url, url.isFileURL, seconds.isFinite, seconds >= 0 else { return nil }
        return await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 288, height: 162)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
            return UIImage(cgImage: cg)
        }.value
    }
}

// MARK: - 字幕面板（主/副双字幕：全轨列表＋形态标注＋加载本地字幕＋字号）

struct SubtitlePanelView: View {
    @ObservedObject var model: MPVPlayerModel
    let onLoadLocalSubtitle: () -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PlayerSettings.mpvSubtitleFontSizeKey) private var fontSize: Int = 55
    @State private var tab: Tab = .primary

    private enum Tab { case primary, secondary }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("字幕", selection: $tab) {
                        Text("主字幕").tag(Tab.primary)
                        Text("副字幕").tag(Tab.secondary)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }
                Section {
                    Button {
                        select(nil)
                    } label: {
                        HStack {
                            Text("关闭")
                                .foregroundStyle(.primary)
                            Spacer()
                            if selectedID == nil {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    ForEach(model.subtitleTracks) { track in
                        Button {
                            select(track.id)
                        } label: {
                            HStack(spacing: 8) {
                                Text(track.displayName)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                Spacer()
                                Text(track.subtitleKindLabel)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.secondary.opacity(0.15), in: Capsule())
                                if track.id == selectedID {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .disabled(isConflicting(track))
                    }
                } header: {
                    Text(tab == .primary ? "主字幕" : "副字幕")
                }
                Section {
                    Button {
                        dismiss()
                        onLoadLocalSubtitle()
                    } label: {
                        Label("加载本地字幕", systemImage: "doc.badge.plus")
                    }
                } footer: {
                    Text("支持 SRT / ASS / SSA / VTT，加载后会记住并用于本片。")
                }
                Section("字幕设置") {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("字号", value: "\(fontSize)")
                        Slider(value: Binding(
                            get: { Double(fontSize) },
                            set: { fontSize = Int($0.rounded()) }
                        ), in: 36...80, step: 1) {
                            Text("字号")
                        } onEditingChanged: { _ in model.applySubtitleFontSize() }
                        .onChange(of: fontSize) { _, _ in model.applySubtitleFontSize() }
                    }
                }
            }
            .navigationTitle("字幕")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }

    private var selectedID: Int? {
        tab == .primary ? model.selectedSubtitleID : model.selectedSecondarySubtitleID
    }

    /// 主副不能选同一条（引擎会重复渲染同一轨）
    private func isConflicting(_ track: MPVTrack) -> Bool {
        tab == .primary
            ? track.id == model.selectedSecondarySubtitleID
            : track.id == model.selectedSubtitleID
    }

    private func select(_ id: Int?) {
        if tab == .primary {
            model.selectSubtitleTrack(id)
        } else {
            model.selectSecondarySubtitleTrack(id)
        }
    }
}

// MARK: - 选集面板（同剧分集：剧照优先，其次视频帧缩略图）

struct EpisodePanelView: View {
    let episodes: [MediaItem]
    let currentID: UUID
    let stillProvider: (MediaItem) -> UIImage?
    let onSelect: (MediaItem) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(episodes) { item in
                Button {
                    onSelect(item)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Group {
                            if let still = stillProvider(item) {
                                Image(uiImage: still)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                PosterView(item: item, wide: true)
                            }
                        }
                        .frame(width: 104, height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            if let info = EpisodeParser.parse(item.name) {
                                Text("第 \(info.episode) 集 · \(ScrapeStore.episodeKey(season: info.season, episode: info.episode))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(item.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                        }
                        Spacer()
                        if item.id == currentID {
                            Image(systemName: "speaker.wave.2.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("选集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }
}

// MARK: - 播放器更多设置（与设置页共用同一组 AppStorage 键）

struct PlayerMoreSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PlayerSettings.nativeModeKey) private var nativeMode = false
    @AppStorage(PlayerSettings.skipKey) private var skipIntroOutro = false
    @AppStorage(PlayerSettings.introSecondsKey) private var introSeconds: Double = 90
    @AppStorage(PlayerSettings.outroSecondsKey) private var outroSeconds: Double = 120
    @AppStorage(PlayerSettings.showPrevNextKey) private var showPrevNextButtons = true
    @AppStorage(PlayerSettings.showSeekButtonsKey) private var showSeekButtons = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("原生模式", isOn: $nativeMode)
                } header: {
                    Text("播放模式")
                } footer: {
                    Text("默认直读直放，点开即播。开启原生模式后，视频先无损重封装再用系统播放器播放，打开较慢；切换后当前视频会重新载入。")
                }
                Section {
                    Toggle("跳过片头片尾", isOn: $skipIntroOutro)
                    if skipIntroOutro {
                        Stepper(value: $introSeconds, in: 0...600, step: 5) {
                            LabeledContent("片头时长", value: String(localized: "\(Int(introSeconds)) 秒"))
                        }
                        Stepper(value: $outroSeconds, in: 0...600, step: 5) {
                            LabeledContent("片尾时长", value: String(localized: "\(Int(outroSeconds)) 秒"))
                        }
                    }
                } header: {
                    Text("跳过片头片尾")
                } footer: {
                    if skipIntroOutro {
                        Text("开播时自动跳过片头；进入片尾时段会显示跳过按钮，有下一集时自动连播。")
                    }
                }
                Section("按钮") {
                    Toggle("上一集 / 下一集按钮", isOn: $showPrevNextButtons)
                    Toggle("快退 / 快进按钮", isOn: $showSeekButtons)
                }
            }
            .navigationTitle("更多设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }
}
