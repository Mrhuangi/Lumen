import SwiftUI

/// 兼容播放（mpv）的自建控制层：参照 Apple TV App / 系统播放器的设计语言——
/// SF Symbols 图标、Liquid Glass 材质、系统字阶、原生 Menu；
/// 单击隐显、控件 4 秒无操作自动隐藏、双击两侧快退/快进 10 秒（gobackward.10 / goforward.10）。
/// 不自绘标题与徽章（与既定规则一致，标题层交给系统）。
struct MPVControlsView: View {
    @ObservedObject var model: MPVPlayerModel

    @State private var controlsVisible = true
    @State private var interactionSeed = 0
    @State private var scrubValue: Double?
    @State private var flashVisible = false

    private static let rates: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]

    var body: some View {
        ZStack {
            tapSurface
            if model.isBuffering {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            } else if model.isPaused || controlsVisible {
                centerPlayButton
            }
            if let flash = model.seekFlash, flashVisible {
                seekFlashView(forward: flash.forward)
            }
            if controlsVisible {
                bottomBar
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        .task(id: interactionSeed) {
            // 播放中且无新交互时 4 秒后自动隐藏；暂停时保持显示
            guard controlsVisible, !model.isPaused else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { controlsVisible = false }
        }
        .onChange(of: model.isPaused) { _, paused in
            if paused { controlsVisible = true }
            bumpInteraction()
        }
        .onChange(of: model.seekFlash?.counter) { _, _ in
            flashVisible = true
            Task {
                try? await Task.sleep(for: .milliseconds(650))
                flashVisible = false
            }
        }
    }

    // MARK: 手势层（单击切换隐显；左右双击快退/快进）

    private var tapSurface: some View {
        HStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.seekBy(-10); bumpInteraction() }
                .onTapGesture { toggleControls() }
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.seekBy(10); bumpInteraction() }
                .onTapGesture { toggleControls() }
        }
    }

    private func toggleControls() {
        controlsVisible.toggle()
        bumpInteraction()
    }

    private func bumpInteraction() {
        interactionSeed += 1
    }

    // MARK: 中央播放键（大而克制，玻璃圆钮）

    private var centerPlayButton: some View {
        Button {
            model.togglePlayPause()
            bumpInteraction()
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

    // MARK: 底部控制条（玻璃胶囊：时间 / 进度 / 时间 + 轨道与倍速菜单）

    private var bottomBar: some View {
        VStack {
            Spacer()
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Text(Self.timeText(scrubValue ?? model.position))
                        .frame(width: 52, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { scrubValue ?? model.position },
                            set: { scrubValue = $0 }
                        ),
                        in: 0...max(model.duration, 1)
                    ) { editing in
                        bumpInteraction()
                        if !editing, let target = scrubValue {
                            model.seek(to: target)
                            scrubValue = nil
                        }
                    }
                    .tint(.white)
                    Text(Self.timeText(model.duration))
                        .frame(width: 52, alignment: .trailing)
                }
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.white)

                HStack(spacing: 10) {
                    rateMenu
                    Spacer()
                    subtitleMenu
                    audioMenu
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private func menuButton(_ systemImage: String, label: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 40, height: 32)
            .glassEffect(.regular.interactive(), in: Capsule())
            .accessibilityLabel(label)
    }

    private var rateMenu: some View {
        Menu {
            ForEach(Self.rates, id: \.self) { value in
                Button {
                    model.setRate(value)
                    bumpInteraction()
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
                Image(systemName: "speedometer")
                    .font(.system(size: 15, weight: .medium))
                Text(Self.rateText(model.rate))
                    .font(.subheadline.monospacedDigit())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .accessibilityLabel("播放速度")
    }

    private var subtitleMenu: some View {
        Menu {
            Button {
                model.selectSubtitleTrack(nil)
                bumpInteraction()
            } label: {
                if model.selectedSubtitleID == nil {
                    Label("关闭字幕", systemImage: "checkmark")
                } else {
                    Text("关闭字幕")
                }
            }
            ForEach(model.subtitleTracks) { track in
                Button {
                    model.selectSubtitleTrack(track.id)
                    bumpInteraction()
                } label: {
                    if track.id == model.selectedSubtitleID {
                        Label(track.displayName, systemImage: "checkmark")
                    } else {
                        Text(track.displayName)
                    }
                }
            }
        } label: {
            menuButton("captions.bubble.fill", label: "字幕")
        }
    }

    private var audioMenu: some View {
        Menu {
            ForEach(model.audioTracks) { track in
                Button {
                    model.selectAudioTrack(track.id)
                    bumpInteraction()
                } label: {
                    if track.id == model.selectedAudioID {
                        Label(track.displayName, systemImage: "checkmark")
                    } else {
                        Text(track.displayName)
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
