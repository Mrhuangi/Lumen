import AVFoundation
import SwiftUI
import UIKit

/// 直读播放（mpv）的自建控制层（1.3 按苹果原生播放体验重做）：
/// 组织方式对齐 iOS 16 起的系统播放器——渐变遮罩＋裸 glyph＋中央走带簇＋二级功能进气泡/sheet。
/// 全屏材质预算只有：顶/底两条渐变带、拖动预览卡、跳过片尾药丸、提示片（顶栏侧）；
/// 按钮一律无背景，靠阴影与画面分离，不再有玻璃大板与玻璃胶囊。
///
/// 层级（自下而上）：L1 渐变带（不接收触摸）→ L2 控件（中央走带簇＋底部叠栈）→
/// L3 瞬时反馈（缓冲、±10s 闪标、跳过片尾）→ L4 拖动预览 → L5 气泡/sheet（模态）。
/// 显隐只有一个数据源：PlayerScreen 持有的 chromeVisible（本视图通过 Binding 读写）；
/// 自动隐藏计时在 PlayerScreen 统一处理，本视图在拖动/气泡/面板打开时通过
/// chromeSuspended 通知上层冻结计时。气泡打开时 L1 归零、L2 淡出，控件整体让位，
/// 不再出现「气泡压在玻璃面板上透出按钮轮廓」。
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
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// 横屏判定（与面板内部信号一致）：竖向尺寸类 compact 时系统 sheet 会忽略 detents、
    /// 直接全屏——横屏面板改走底部浮层（见 landscapePanelLayer），竖屏仍用 sheet。
    private var isLandscape: Bool { verticalSizeClass == .compact }

    @State private var scrubValue: Double?
    @State private var scrubStartPosition: Double?
    @State private var scrubStartX: CGFloat = 0
    @State private var scrubRateTier: Double = 1
    @State private var flashVisible = false
    @State private var showSubtitlePanel = false
    @State private var showMoreSettings = false
    @State private var showEpisodes = false
    @State private var showAudioPanel = false
    @State private var activeBubble: Bubble?
    @State private var showRemaining = false
    @State private var previewImage: UIImage?
    @State private var previewSecond = -1
    @State private var previewTask: Task<Void, Never>?

    /// 锚定气泡（倍速/章节/音轨/竖屏更多）：用可控呈现的气泡而非 Menu，
    /// 因为 SwiftUI 的 Menu 不暴露打开状态，没法执行「打开时 L1/L2 让位」的规则
    private enum Bubble: Equatable { case rate, chapters, audio, more }

    private static let rates: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]

    private var panelOpen: Bool {
        showSubtitlePanel || showMoreSettings || showEpisodes || showAudioPanel
    }
    private var scrubbing: Bool { scrubValue != nil }
    /// 气泡打开：渐变归零、控件淡出（L5 让位规则）
    private var bubbleOpen: Bool { activeBubble != nil }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 700
            ZStack {
                tapSurface
                gradientLayer(wide: wide)
                if model.isBuffering {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                } else {
                    centerCluster(wide: wide)
                }
                if let flash = model.seekFlash, flashVisible {
                    seekFlashView(forward: flash.forward)
                }
                if model.outroPromptVisible {
                    outroButton(wide: wide)
                }
                bottomStack(wide: wide, insets: geo.safeAreaInsets)
                if geo.size.width > geo.size.height {
                    landscapePanelLayer(height: geo.size.height * 0.62)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .statusBarHidden(true)
        .animation(.easeInOut(duration: 0.25), value: chromeVisible)
        .animation(.easeInOut(duration: 0.2), value: bubbleOpen)
        .animation(.easeInOut(duration: 0.2), value: scrubbing)
        .onChange(of: model.seekFlash?.counter) { _, _ in
            flashVisible = true
            Task {
                try? await Task.sleep(for: .milliseconds(650))
                flashVisible = false
            }
        }
        .onChange(of: scrubValue) { _, _ in syncSuspended() }
        .onChange(of: panelOpen) { _, _ in syncSuspended(); if panelOpen { poke() } }
        .onChange(of: activeBubble) { _, _ in
            syncSuspended()
            if activeBubble == nil { poke() }
        }
        .task { await runSmokeHooksIfNeeded() }
        .sheet(isPresented: Binding(get: { showSubtitlePanel && !isLandscape }, set: { showSubtitlePanel = $0 })) {
            SubtitlePanelView(model: model, onLoadLocalSubtitle: onLoadLocalSubtitle)
        }
        .sheet(isPresented: Binding(get: { showMoreSettings && !isLandscape }, set: { showMoreSettings = $0 })) {
            PlayerMoreSettingsView()
        }
        .sheet(isPresented: Binding(get: { showEpisodes && !isLandscape }, set: { showEpisodes = $0 })) {
            EpisodePanelView(episodes: episodes, currentID: currentEpisodeID,
                             stillProvider: stillProvider) { item in
                showEpisodes = false
                onSelectEpisode(item)
            }
        }
        .sheet(isPresented: Binding(get: { showAudioPanel && !isLandscape }, set: { showAudioPanel = $0 })) {
            AudioPanelView(model: model)
        }
    }

    /// 打开面板的统一入口：音轨/字幕面板先刷一次轨道信息（选中轨 profile 这时多半已可读，
    /// 全景声标注与列表内容追上），再打开面板——避免开屏瞬间列表为空（1.5 门禁实测）。
    private func openSubtitlePanel() { model.refreshTrackInfoForMenu(); showSubtitlePanel = true }
    private func openAudioPanel() { model.refreshTrackInfoForMenu(); showAudioPanel = true }
    private func openEpisodesPanel() { showEpisodes = true }
    private func openSettingsPanel() { showMoreSettings = true }

    /// 横屏面板浮层（底部 0.62 高）：iPhone 横屏时系统 sheet 忽略 detents、直接全屏，
    /// 故横屏改走自绘底部浮层；竖屏继续用 sheet。面板内容与 sheet 共用同一视图，
    /// 关闭经 onDone 回到本视图的 show 标志。
    @ViewBuilder
    private var landscapePanel: some View {
        if showSubtitlePanel {
            SubtitlePanelView(model: model, onLoadLocalSubtitle: onLoadLocalSubtitle,
                              onDone: { showSubtitlePanel = false })
        } else if showAudioPanel {
            AudioPanelView(model: model, onDone: { showAudioPanel = false })
        } else if showEpisodes {
            EpisodePanelView(episodes: episodes, currentID: currentEpisodeID,
                             stillProvider: stillProvider,
                             onSelect: { item in
                                 showEpisodes = false
                                 onSelectEpisode(item)
                             },
                             onDone: { showEpisodes = false })
        } else if showMoreSettings {
            PlayerMoreSettingsView(onDone: { showMoreSettings = false })
        }
    }

    /// 横屏浮层容器：底部对齐、0.62 高、圆角＋系统底色；无面板打开时为空视图、不挡触摸。
    private func landscapePanelLayer(height: CGFloat) -> some View {
        landscapePanel
            .frame(height: height, alignment: .top)
            .frame(maxWidth: .infinity)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 24, y: -6)
            .transition(.move(edge: .bottom))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .animation(.snappy, value: panelOpen)
    }

    private func syncSuspended() {
        chromeSuspended = scrubbing || panelOpen || bubbleOpen
    }

    // MARK: 手势层（单击切换显隐；左右双击快退/快进）

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

    // MARK: L1 渐变遮罩（顶/底两条带，与控件同显同隐；画面中部保持原亮度）

    private func gradientLayer(wide: Bool) -> some View {
        VStack(spacing: 0) {
            LinearGradient(stops: [
                .init(color: .black.opacity(0.55), location: 0),
                .init(color: .black.opacity(0.28), location: 0.55),
                .init(color: .black.opacity(0), location: 1)
            ], startPoint: .top, endPoint: .bottom)
            .frame(height: wide ? 92 : 56)
            .opacity(topGradientVisible ? 1 : 0)
            Spacer()
            LinearGradient(stops: [
                .init(color: .black.opacity(0), location: 0),
                .init(color: .black.opacity(0.28), location: 0.45),
                .init(color: .black.opacity(0.55), location: 1)
            ], startPoint: .top, endPoint: .bottom)
            .frame(height: wide ? 118 : 72)
            .opacity(bottomGradientVisible ? 1 : 0)
        }
        .allowsHitTesting(false)
    }

    private var topGradientVisible: Bool {
        chromeVisible && !bubbleOpen && !scrubbing
    }

    private var bottomGradientVisible: Bool {
        chromeVisible && !bubbleOpen
    }

    // MARK: L2 中央走带簇（裸 glyph，无背景；暂停时随控件常驻）

    private var clusterVisible: Bool {
        (chromeVisible || model.isPaused) && !bubbleOpen && !scrubbing && !model.isBuffering
    }

    @ViewBuilder
    private func centerCluster(wide: Bool) -> some View {
        HStack(spacing: 16) {
            if wide, showPrevNextButtons, let onPrevious {
                clusterButton("backward.end.fill", glyph: 26, hit: 52, label: "上一集") { onPrevious() }
            }
            if showSeekButtons {
                clusterButton("gobackward.10", glyph: wide ? 36 : 30, hit: wide ? 60 : 52,
                              label: "快退 10 秒") { model.seekBy(-10) }
            }
            Button {
                model.togglePlayPause()
                poke()
            } label: {
                Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: wide ? 50 : 40, weight: .regular))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 1)
                    .frame(width: wide ? 76 : 60, height: wide ? 76 : 60)
                    .contentShape(Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(model.isPaused ? "播放" : "暂停")
            if showSeekButtons {
                clusterButton("goforward.10", glyph: wide ? 36 : 30, hit: wide ? 60 : 52,
                              label: "快进 10 秒") { model.seekBy(10) }
            }
            if wide, showPrevNextButtons, let onNext {
                clusterButton("forward.end.fill", glyph: 26, hit: 52, label: "下一集") { onNext() }
            }
        }
        .opacity(clusterVisible ? 1 : 0)
        .allowsHitTesting(clusterVisible)
    }

    private func clusterButton(_ systemImage: String, glyph: CGFloat, hit: CGFloat,
                               label: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            poke()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: glyph, weight: .regular))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 6, y: 1)
                .frame(width: hit, height: hit)
                .contentShape(Circle())
        }
        .accessibilityLabel(label)
    }

    /// 模拟器门禁钩子（仅启动参数触发，真机无此参数、零影响）：
    /// -smokePanel subtitle|audio|episodes|settings → 播放页出现 6 秒后打开指定面板，
    /// 供工作流截图逐个核对面板有内容（1.4.1 横屏面板不可见的教训）。
    private func runSmokeHooksIfNeeded() async {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "-smokePanel"), idx + 1 < args.count else { return }
        try? await Task.sleep(for: .seconds(6))
        switch args[idx + 1] {
        case "subtitle": openSubtitlePanel()
        case "audio": openAudioPanel()
        case "episodes": openEpisodesPanel()
        case "settings": openSettingsPanel()
        default: break
        }
    }

    // MARK: L3 瞬时反馈（双击闪标、跳过片尾；独立生命周期，不绑架主显隐）

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
        VStack(spacing: 2) {
            Image(systemName: forward ? "goforward.10" : "gobackward.10")
                .font(.system(size: 30, weight: .regular))
            Text("10 秒")
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
        .frame(width: 64, height: 64)
    }

    /// 跳过片尾：全屏唯一允许的悬浮胶囊（黑 α0.55 实底，不再用玻璃）
    private func outroButton(wide: Bool) -> some View {
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
                        .background(.black.opacity(0.55), in: Capsule())
                }
            }
            .padding(.trailing, 16)
            .padding(.bottom, chromeVisible ? (wide ? 108 : 72) : 30)
        }
        .animation(.easeInOut(duration: 0.25), value: chromeVisible)
        .transition(.opacity)
    }

    // MARK: L2 底部叠栈（站在底渐变上；横屏两行、竖屏单行紧凑，都是同一套控件）

    private func bottomStack(wide: Bool, insets: EdgeInsets) -> some View {
        let side = max(insets.leading, insets.trailing) + 16
        let bottomPad = insets.bottom > 0 ? 6.0 : 12.0
        return VStack {
            Spacer()
            if wide {
                VStack(spacing: 6) {
                    progressRow
                    functionRow
                        .opacity(scrubbing ? 0 : 1)
                        .allowsHitTesting(!scrubbing && chromeVisible && !bubbleOpen)
                }
            } else {
                compactRow
            }
        }
        .padding(.leading, wide ? side : 16)
        .padding(.trailing, wide ? side : 16)
        .padding(.bottom, bottomPad)
        .opacity(chromeVisible && !bubbleOpen ? 1 : 0)
        .allowsHitTesting(chromeVisible && !bubbleOpen)
    }

    /// 横屏进度行：左时间＋自绘进度条＋右时间（点按右时间在总时长/剩余间切换）
    private var progressRow: some View {
        HStack(spacing: 12) {
            Text(Self.timeText(scrubValue ?? model.position))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
                .frame(width: 48, alignment: .leading)
            progressBar
            Button {
                showRemaining.toggle()
                poke()
            } label: {
                Text(durationText)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
                    .frame(width: 48, alignment: .trailing)
                    .frame(height: 30)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("切换时长显示")
        }
        .frame(height: 30)
    }

    private var durationText: String {
        if showRemaining {
            let left = max(model.duration - (scrubValue ?? model.position), 0)
            return "-" + Self.timeText(left)
        }
        return Self.timeText(model.duration)
    }

    /// 横屏功能行：左组倍速/章节，右组字幕/音轨/选集/更多（一行放全，裸 glyph）
    private var functionRow: some View {
        HStack(spacing: 8) {
            rateButton
            if !model.chapters.isEmpty { chaptersButton }
            Spacer(minLength: 8)
            glyphButton("captions.bubble.fill", label: "字幕") { openSubtitlePanel() }
            audioButton
            if episodes.count > 1 {
                glyphButton("list.bullet", label: "选集") { openEpisodesPanel() }
            }
            glyphButton("ellipsis.circle", label: "更多设置") { openSettingsPanel() }
        }
        .frame(height: 44)
    }

    /// 竖屏单行（同一套控件的紧凑形态）：倍速→时间→进度条→时长→字幕→音轨→更多。
    /// 章节/选集收进「更多」气泡，不堆第二行。
    private var compactRow: some View {
        HStack(spacing: 4) {
            rateButton
            Text(Self.timeText(scrubValue ?? model.position))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
                .frame(minWidth: 40, alignment: .leading)
            progressBar
            Text(durationText)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
                .frame(minWidth: 40, alignment: .trailing)
            glyphButton("captions.bubble.fill", glyph: 18, hitWidth: 40, label: "字幕") {
                openSubtitlePanel()
            }
            audioButtonCompact
            moreButtonCompact
        }
        .frame(height: 44)
    }

    // MARK: 底部按钮（裸 glyph，点击域一律补满 44 高）

    private func glyphButton(_ systemImage: String, glyph: CGFloat = 20, hitWidth: CGFloat = 44,
                             label: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            poke()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: glyph, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
                .frame(width: hitWidth, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    private var rateButton: some View {
        Button {
            toggleBubble(.rate)
        } label: {
            Text(Self.rateText(model.rate))
                .font(.system(size: 15, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("播放速度")
        .popover(isPresented: bubbleBinding(.rate),
                 attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            ratePopover
        }
    }

    private var chaptersButton: some View {
        Button {
            toggleBubble(.chapters)
        } label: {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("章节")
        .popover(isPresented: bubbleBinding(.chapters),
                 attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            chaptersPopover
        }
    }

    /// 音轨：≤10 条用锚定气泡，更多时升格为底部 sheet（行规范与字幕面板同构）
    @ViewBuilder
    private var audioButton: some View {
        if model.audioTracks.count > 10 {
            glyphButton("waveform", label: "音轨") { openAudioPanel() }
        } else {
            audioBubbleButton
        }
    }

    @ViewBuilder
    private var audioButtonCompact: some View {
        if model.audioTracks.count > 10 {
            glyphButton("waveform", glyph: 18, hitWidth: 40, label: "音轨") { openAudioPanel() }
        } else {
            audioBubbleButtonCompact
        }
    }

    private var audioBubbleButton: some View {
        Button {
            toggleBubble(.audio)
        } label: {
            Image(systemName: "waveform")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("音轨")
        .popover(isPresented: bubbleBinding(.audio),
                 attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            audioPopover
        }
    }

    private var audioBubbleButtonCompact: some View {
        Button {
            toggleBubble(.audio)
        } label: {
            Image(systemName: "waveform")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("音轨")
        .popover(isPresented: bubbleBinding(.audio),
                 attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            audioPopover
        }
    }

    /// 竖屏「更多」气泡：选集、章节（直接列表点选）、更多设置都收在这里
    private var moreButtonCompact: some View {
        Button {
            toggleBubble(.more)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("更多")
        .popover(isPresented: bubbleBinding(.more),
                 attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            morePopover
        }
    }

    private func toggleBubble(_ bubble: Bubble) {
        withAnimation(.easeInOut(duration: 0.2)) {
            activeBubble = (activeBubble == bubble) ? nil : bubble
        }
        poke()
    }

    private func bubbleBinding(_ bubble: Bubble) -> Binding<Bool> {
        Binding(
            get: { activeBubble == bubble },
            set: { presented in
                if presented {
                    activeBubble = bubble
                } else if activeBubble == bubble {
                    activeBubble = nil
                }
            }
        )
    }

    // MARK: 气泡内容（单选即走，行高 ≥44，选中带勾）

    private var ratePopover: some View {
        VStack(spacing: 0) {
            ForEach(Self.rates, id: \.self) { value in
                Button {
                    model.setRate(value)
                    activeBubble = nil
                    poke()
                } label: {
                    HStack(spacing: 8) {
                        Text(Self.rateText(value))
                            .foregroundStyle(.primary)
                        Spacer()
                        if value == model.rate {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if value != Self.rates.last {
                    Divider()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(width: 200)
        .presentationCompactAdaptation(.popover)
    }

    private var chaptersPopover: some View {
        VStack(spacing: 0) {
            ForEach(model.chapters) { chapter in
                Button {
                    model.seek(to: chapter.time)
                    activeBubble = nil
                    poke()
                } label: {
                    HStack(spacing: 8) {
                        Text(chapter.displayTitle)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                        Text(Self.timeText(chapter.time))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if chapter.id != model.chapters.last?.id {
                    Divider()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(width: 280)
        .presentationCompactAdaptation(.popover)
    }

    private var audioPopover: some View {
        VStack(spacing: 0) {
            ForEach(model.audioTracks) { track in
                Button {
                    model.selectAudioTrack(track.id)
                    activeBubble = nil
                    poke()
                } label: {
                    HStack(spacing: 8) {
                        Text(audioLabel(for: track))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                        if track.id == model.selectedAudioID {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if track.id != model.audioTracks.last?.id {
                    Divider()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(width: 300)
        .presentationCompactAdaptation(.popover)
    }

    private var morePopover: some View {
        VStack(spacing: 0) {
            if episodes.count > 1 {
                Button {
                    activeBubble = nil
                    openEpisodesPanel()
                } label: {
                    HStack(spacing: 8) {
                        Text("选集").foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "list.bullet").foregroundStyle(.secondary)
                    }
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
            if !model.chapters.isEmpty {
                ForEach(model.chapters) { chapter in
                    Button {
                        model.seek(to: chapter.time)
                        activeBubble = nil
                        poke()
                    } label: {
                        HStack(spacing: 8) {
                            Text(chapter.displayTitle)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer()
                            Text(Self.timeText(chapter.time))
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .frame(height: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
            Button {
                activeBubble = nil
                openSettingsPanel()
            } label: {
                HStack(spacing: 8) {
                    Text("更多设置").foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                }
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(width: 260)
        .presentationCompactAdaptation(.popover)
    }

    /// 音轨气泡行文：显示名（语言 · 名称）＋模型徽标（编码 · 声道 · Atmos），呈现层原样拼
    private func audioLabel(for track: MPVTrack) -> String {
        track.codecBadgeLabel.isEmpty
            ? track.displayName
            : "\(track.displayName) · \(track.codecBadgeLabel)"
    }

    // MARK: 自绘进度条（弃用系统 Slider：轨道 5pt、滑块 Ø14、scrub 时 Ø24/轨道 9pt）

    private var displayFraction: Double {
        guard model.duration > 0 else { return 0 }
        let value = (scrubValue ?? model.position) / model.duration
        return min(max(value, 0), 1)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let thumb: CGFloat = scrubbing ? 24 : 14
            let trackHeight: CGFloat = scrubbing ? 9 : 5
            let thumbX = width * CGFloat(displayFraction)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.25))
                    .frame(height: trackHeight)
                Capsule()
                    .fill(.white)
                    .frame(width: width * CGFloat(displayFraction), height: trackHeight)
                if !model.chapters.isEmpty, model.duration > 0 {
                    ForEach(model.chapters) { chapter in
                        Circle()
                            .fill(.white.opacity(0.85))
                            .frame(width: 4, height: 4)
                            .offset(x: width * CGFloat(chapter.time / model.duration) - 2)
                    }
                }
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    .frame(width: thumb, height: thumb)
                    .offset(x: thumbX - thumb / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(scrubGesture(width: width))
            .overlay(alignment: .top) {
                if let target = scrubValue {
                    scrubPreviewCard(target)
                        .offset(x: previewOffsetX(thumbX: thumbX, barWidth: width),
                                y: previewImage != nil ? -118 : -36)
                }
            }
        }
        .frame(height: 30)
        .animation(.easeInOut(duration: 0.15), value: scrubbing)
    }

    /// 精细 scrub：手势离进度行越远速率越细（1× → 0.5× → 0.25×，系统播放器同款）
    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                guard model.duration > 0, width > 0 else { return }
                if scrubStartPosition == nil {
                    scrubStartPosition = scrubValue ?? model.position
                    scrubStartX = gesture.location.x
                    poke()
                }
                let vertical = abs(gesture.translation.height)
                let tier = vertical > 90 ? 0.25 : (vertical > 40 ? 0.5 : 1.0)
                scrubRateTier = tier
                let start = scrubStartPosition ?? model.position
                let delta = Double((gesture.location.x - scrubStartX) / width) * model.duration * tier
                let target = min(max(start + delta, 0), model.duration)
                scrubValue = target
                schedulePreview(for: target)
            }
            .onEnded { _ in
                if let target = scrubValue {
                    model.seek(to: target)
                }
                scrubValue = nil
                scrubStartPosition = nil
                scrubRateTier = 1
                previewImage = nil
                previewSecond = -1
            }
    }

    /// 预览卡横向跟随滑块、边缘夹紧（卡宽 160，两侧至少留 12pt 屏边余量按行内近似）
    private func previewOffsetX(thumbX: CGFloat, barWidth: CGFloat) -> CGFloat {
        let center = min(max(thumbX, 80), max(barWidth - 80, 80))
        return center - barWidth / 2
    }

    /// L4 拖动预览：抽帧卡 160×90＋时间泡（掠过章节时追加章节名，精细档追加速率）
    private func scrubPreviewCard(_ target: Double) -> some View {
        VStack(spacing: 6) {
            if let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 160, height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Text(previewBubbleText(target))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.black.opacity(0.55), in: Capsule())
        }
        .transition(.opacity)
    }

    private func previewBubbleText(_ target: Double) -> String {
        var text = Self.timeText(target)
        if let chapter = model.chapters.last(where: { $0.time <= target }),
           target - chapter.time <= 2.5 {
            text += " · \(chapter.displayTitle)"
        }
        if scrubRateTier < 1 {
            text += " · \(Self.rateText(scrubRateTier))"
        }
        return text
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
            generator.maximumSize = CGSize(width: 320, height: 180)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
            return UIImage(cgImage: cg)
        }.value
    }
}

// MARK: - 字幕轨呈现规则（面板专用：语言分组、简繁显示名、格式徽章）
//
// 分组与排序（多轨场景规范）：简体中文 → 繁体中文 → 中文（未分简繁）→ 英语 → 日语 →
// 韩语 → 其他语言；组内完整轨在前、强制轨沉底，其次默认轨优先，再按格式
// ASS ＞ SSA ＞ SRT ＞ VTT ＞ 文本 ＞ PGS ＞ DVB 排（文本轨可调字号，位图轨沉底）。

private enum SubtitleTrackPresentation {
    struct TrackGroup: Identifiable {
        let id: String
        let header: String
        let tracks: [MPVTrack]
    }

    static func displayName(for track: MPVTrack) -> String {
        if track.isSimplifiedChinese { return String(localized: "简体中文") }
        if track.isTraditionalChinese {
            let lang = (track.lang ?? "").lowercased()
            if lang.contains("tw") { return String(localized: "繁体中文（台湾）") }
            if lang.contains("hk") { return String(localized: "繁体中文（香港）") }
            return String(localized: "繁体中文")
        }
        if track.isChinese { return String(localized: "中文") }
        if let label = MPVTrack.languageLabel(track.lang) { return label }
        return track.displayName
    }

    static func formatLabel(for track: MPVTrack) -> String {
        // 共享编解码以模型侧 MPVTrack.subtitleFormatLabel 为单一事实源；
        // 以下三类 A 侧未细分的格式由呈现层补齐（MOV/CC/DVB 与 PGS 别名）
        switch (track.codec ?? "").lowercased() {
        case "mov_text", "tx3g": return "MOV"
        case "eia_608", "eia_708": return "CC"
        case "dvb_subtitle", "dvbsub": return "DVB"
        case "pgs": return "PGS"
        default: return track.subtitleFormatLabel
        }
    }

    static func isSDH(_ track: MPVTrack) -> Bool {
        let title = (track.title ?? "").uppercased()
        return title.contains("SDH") || title.contains("HOH") || (track.title ?? "").contains("听障")
    }

    private static func formatPriority(_ track: MPVTrack) -> Int {
        switch formatLabel(for: track) {
        case "ASS": return 0
        case "SSA": return 1
        case "SRT": return 2
        case "VTT": return 3
        case "MOV": return 4
        case "CC": return 5
        case "PGS": return 6
        case "DVB": return 7
        default: return track.subtitleIsText ? 5 : 8
        }
    }

    private static func groupInfo(for track: MPVTrack) -> (order: Int, id: String, header: String) {
        if track.isSimplifiedChinese { return (0, "hans", String(localized: "简体中文")) }
        if track.isTraditionalChinese { return (1, "hant", String(localized: "繁体中文")) }
        if track.isChinese { return (2, "zh", String(localized: "中文")) }
        if track.isEnglish { return (3, "en", String(localized: "英语")) }
        let lang = (track.lang ?? "").lowercased()
        if lang.hasPrefix("ja") || lang == "jpn" { return (4, "ja", String(localized: "日语")) }
        if lang.hasPrefix("ko") || lang == "kor" { return (5, "ko", String(localized: "韩语")) }
        let name = displayName(for: track)
        return (6, "other:" + name, name)
    }

    static func groups(for tracks: [MPVTrack]) -> [TrackGroup] {
        var buckets: [String: (order: Int, header: String, tracks: [MPVTrack])] = [:]
        for track in tracks {
            let info = groupInfo(for: track)
            var bucket = buckets[info.id] ?? (order: info.order, header: info.header, tracks: [])
            bucket.tracks.append(track)
            buckets[info.id] = bucket
        }
        return buckets
            .map { (id: $0.key, order: $0.value.order, header: $0.value.header, tracks: $0.value.tracks) }
            .sorted { a, b in
                if a.order != b.order { return a.order < b.order }
                return a.header < b.header
            }
            .map { entry in
                TrackGroup(id: entry.id, header: entry.header, tracks: sortedInGroup(entry.tracks))
            }
    }

    private static func sortedInGroup(_ tracks: [MPVTrack]) -> [MPVTrack] {
        tracks.sorted { a, b in
            if a.isForced != b.isForced { return !a.isForced }
            if a.isDefault != b.isDefault { return a.isDefault }
            let pa = formatPriority(a)
            let pb = formatPriority(b)
            if pa != pb { return pa < pb }
            return false
        }
    }
}

// MARK: - 面板 detent 规则（横屏限高，单一实现）

/// sheet 面板的高度规则：横屏（竖向尺寸类 compact，即窗口矮）只给 .fraction(0.62) 一档，
/// 不给 .large——横屏下 .large 等于全屏高，面板会把画面整个挡住且内容被纵向拉散（1.3 真机实证）；
/// 竖屏按内容量决定：内容多直接 [.large]，内容少 [.medium, .large]（系统默认取较小档、可上拉）。
/// 不再用 selection 绑定：面板的初始档位若不在 detents 集合内（横屏时 @State 初始值
/// 仍是 .medium/.large），sheet 会以无效高度呈现、等于不出现（1.4.1 横屏面板不可见的根因）；
/// 去掉绑定后系统按集合取默认档，档位切换只由这一个函数决定。
enum PanelDetents {
    static func set(isLandscape: Bool, portraitLarge: Bool) -> Set<PresentationDetent> {
        if isLandscape { return [.fraction(0.62)] }
        return portraitLarge ? [.large] : [.medium, .large]
    }
}

// MARK: - 液态玻璃统一出口（设置可关）

/// 全 App 玻璃面的唯一实现（用户 2026-11-08 要求设置里可关液态玻璃）：
/// 开（默认）→ 系统 Liquid Glass；关 → 经典磨砂材质＋细描边（26 之前的观感）。
/// 任何新玻璃面都走 chromeGlass，不再各处直接写 glassEffect。
struct ChromeGlassModifier<S: InsettableShape>: ViewModifier {
    @AppStorage(PlayerSettings.liquidGlassKey) private var liquidGlass = true
    let shape: S
    var interactive: Bool = false
    var active: Bool = false

    func body(content: Content) -> some View {
        if liquidGlass {
            content.glassEffect(active ? .regular.tint(.white.opacity(0.35)).interactive()
                                       : (interactive ? .regular.interactive() : .regular),
                                in: shape)
        } else {
            content
                .background(shape.fill(.ultraThinMaterial))
                .overlay(shape.strokeBorder(.white.opacity(active ? 0.4 : 0.2), lineWidth: 1))
                .clipShape(shape)
        }
    }
}

extension View {
    func chromeGlass<S: InsettableShape>(in shape: S, interactive: Bool = false,
                                          active: Bool = false) -> some View {
        modifier(ChromeGlassModifier(shape: shape, interactive: interactive, active: active))
    }
}

// MARK: - 字幕面板（主/副双字幕：分组全列表＋摘要头＋加载本地字幕＋字号）

/// 面板自绘标题栏（标题＋完成按钮）：1.5.2 门禁实测，横屏浮层里 NavigationStack 的
/// toolbar 完成按钮在 Pro Max 上会被裁到屏外；改走面板内自绘标题栏，位置由面板自身布局保证。
/// 四个面板共用，竖屏 sheet 与横屏浮层同一套外观。
private struct PanelTitleBar: View {
    let title: String
    let onDone: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            Button("完成") { onDone() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

struct SubtitlePanelView: View {
    @ObservedObject var model: MPVPlayerModel
    let onLoadLocalSubtitle: () -> Void
    var onDone: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PlayerSettings.mpvSubtitleFontSizeKey) private var fontSize: Int = 55
    @State private var tab: Tab = .primary
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private enum Tab { case primary, secondary }

    /// 横屏判定：竖向尺寸类 compact 即窗口矮（iPhone 横屏），此时面板必须限高
    private var isLandscape: Bool { verticalSizeClass == .compact }
    /// 关闭面板：浮层模式经 onDone 回到父视图的 show 标志；sheet 模式走系统 dismiss。
    private func dismissPanel() {
        if let onDone { onDone() } else { dismiss() }
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelTitleBar(title: "字幕") { dismissPanel() }
            header
            trackList
        }
        .preferredColorScheme(.dark)
        .presentationDetents(PanelDetents.set(isLandscape: isLandscape,
                                               portraitLarge: model.subtitleTracks.count > 10))
    }

    /// 固定头部（不随列表滚动）：主/副分段＋当前选择摘要，进面板先看清现状
    private var header: some View {
        VStack(spacing: 8) {
            Picker("字幕", selection: $tab) {
                Text("主字幕").tag(Tab.primary)
                Text("副字幕").tag(Tab.secondary)
            }
            .pickerStyle(.segmented)
            Text(summaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var summaryText: String {
        let primary = selectionSummary(model.selectedSubtitleID)
        let secondary = selectionSummary(model.selectedSecondarySubtitleID)
        return String(localized: "主：\(primary)　副：\(secondary)")
    }

    private func selectionSummary(_ id: Int?) -> String {
        guard let id, let track = model.subtitleTracks.first(where: { $0.id == id }) else {
            return String(localized: "关闭")
        }
        let name = SubtitleTrackPresentation.displayName(for: track)
        let format = SubtitleTrackPresentation.formatLabel(for: track)
        return "\(name) · \(format)"
    }

    private var trackList: some View {
        List {
                Section {
                    offRow
                }
                ForEach(SubtitleTrackPresentation.groups(for: model.subtitleTracks)) { group in
                    Section {
                        ForEach(group.tracks) { track in
                            trackRow(track)
                        }
                    } header: {
                        Text("\(group.header) · \(group.tracks.count)")
                            .font(.footnote.weight(.semibold))
                    }
                }
                Section {
                    Button {
                        dismissPanel()
                        onLoadLocalSubtitle()
                    } label: {
                        Label("加载本地字幕", systemImage: "doc.badge.plus")
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
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
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
        }
        .listStyle(.plain)
    }

    private var offRow: some View {
        Button {
            select(nil)
        } label: {
            HStack {
                Text("关闭")
                    .font(.body.weight(selectedID == nil ? .semibold : .regular))
                    .foregroundStyle(.primary)
                Spacer()
                if selectedID == nil {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .listRowBackground(selectedID == nil ? Color.accentColor.opacity(0.12) : Color.clear)
        .id(-1)
    }

    private func trackRow(_ track: MPVTrack) -> some View {
        let selected = track.id == selectedID
        let conflict = conflictReason(for: track)
        return Button {
            select(track.id)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(SubtitleTrackPresentation.displayName(for: track))
                        .font(.body.weight(selected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                    subtitleLine(for: track, conflict: conflict)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(conflict != nil)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .listRowBackground(selected ? Color.accentColor.opacity(0.12) : Color.clear)
        .id(track.id)
    }

    @ViewBuilder
    private func subtitleLine(for track: MPVTrack, conflict: String?) -> some View {
        HStack(spacing: 6) {
            if let title = track.title, !title.isEmpty {
                Text(title).lineLimit(1)
            }
            badge(SubtitleTrackPresentation.formatLabel(for: track))
            if track.isForced { badge("强制") }
            if track.isDefault { badge("默认") }
            if track.isExternal { badge("外挂") }
            if SubtitleTrackPresentation.isSDH(track) { badge("SDH") }
            if SubtitleTrackPresentation.formatLabel(for: track) == "PGS" {
                Text("图形字幕，字号设置不生效").lineLimit(1)
            }
            if let conflict {
                Text(conflict).lineLimit(1)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.secondary.opacity(0.15), in: Capsule())
    }

    private var selectedID: Int? {
        tab == .primary ? model.selectedSubtitleID : model.selectedSecondarySubtitleID
    }

    private func conflictReason(for track: MPVTrack) -> String? {
        if tab == .primary, track.id == model.selectedSecondarySubtitleID {
            return String(localized: "已设为副字幕")
        }
        if tab == .secondary, track.id == model.selectedSubtitleID {
            return String(localized: "已设为主字幕")
        }
        return nil
    }

    private func select(_ id: Int?) {
        if tab == .primary {
            model.selectSubtitleTrack(id)
        } else {
            model.selectSecondarySubtitleTrack(id)
        }
    }
}

// MARK: - 音轨面板（音轨超过 10 条时由气泡升格为底部 sheet，行规范与字幕行同构）

struct AudioPanelView: View {
    @ObservedObject var model: MPVPlayerModel
    var onDone: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// 横屏判定与限高规则同字幕面板（见 PanelDetents）；竖屏默认档保持原规则 .large
    private var isLandscape: Bool { verticalSizeClass == .compact }
    /// 关闭面板：浮层模式经 onDone 回到父视图的 show 标志；sheet 模式走系统 dismiss。
    private func dismissPanel() {
        if let onDone { onDone() } else { dismiss() }
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelTitleBar(title: "音轨") { dismissPanel() }
            List {
                ForEach(model.audioTracks) { track in
                    Button {
                        model.selectAudioTrack(track.id)
                        dismissPanel()
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(track.displayName)
                                    .font(.body.weight(track.id == model.selectedAudioID ? .semibold : .regular))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if !track.codecBadgeLabel.isEmpty {
                                    Text(track.codecBadgeLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if track.id == model.selectedAudioID {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        track.id == model.selectedAudioID
                            ? Color.accentColor.opacity(0.12)
                            : Color.clear
                    )
                }
            }
            .listStyle(.plain)
        }
        .preferredColorScheme(.dark)
        .presentationDetents(PanelDetents.set(isLandscape: isLandscape,
                                               portraitLarge: true))
    }
}

// MARK: - 选集面板（同剧分集：剧照优先，其次视频帧缩略图）

struct EpisodePanelView: View {
    let episodes: [MediaItem]
    let currentID: UUID
    let stillProvider: (MediaItem) -> UIImage?
    let onSelect: (MediaItem) -> Void
    var onDone: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// 横屏判定与限高规则同字幕面板（见 PanelDetents）
    private var isLandscape: Bool { verticalSizeClass == .compact }
    /// 关闭面板：浮层模式经 onDone 回到父视图的 show 标志；sheet 模式走系统 dismiss。
    private func dismissPanel() {
        if let onDone { onDone() } else { dismiss() }
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelTitleBar(title: "选集") { dismissPanel() }
            List(episodes) { item in
                Button {
                    onSelect(item)
                    dismissPanel()
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
        }
        .preferredColorScheme(.dark)
        .presentationDetents(PanelDetents.set(isLandscape: isLandscape,
                                               portraitLarge: episodes.count > 8))
    }
}

// MARK: - 播放器更多设置（与设置页共用同一组 AppStorage 键）

struct PlayerMoreSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    var onDone: (() -> Void)? = nil
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// 横屏判定与限高规则同字幕面板（见 PanelDetents）
    private var isLandscape: Bool { verticalSizeClass == .compact }
    /// 关闭面板：浮层模式经 onDone 回到父视图的 show 标志；sheet 模式走系统 dismiss。
    private func dismissPanel() {
        if let onDone { onDone() } else { dismiss() }
    }
    @AppStorage(PlayerSettings.nativeModeKey) private var nativeMode = false
    @AppStorage(PlayerSettings.skipKey) private var skipIntroOutro = false
    @AppStorage(PlayerSettings.introSecondsKey) private var introSeconds: Double = 90
    @AppStorage(PlayerSettings.outroSecondsKey) private var outroSeconds: Double = 120
    @AppStorage(PlayerSettings.showPrevNextKey) private var showPrevNextButtons = true
    @AppStorage(PlayerSettings.showSeekButtonsKey) private var showSeekButtons = true

    var body: some View {
        VStack(spacing: 0) {
            PanelTitleBar(title: "更多设置") { dismissPanel() }
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
        }
        .preferredColorScheme(.dark)
        .presentationDetents(PanelDetents.set(isLandscape: isLandscape, portraitLarge: false))
    }
}
