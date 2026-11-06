import SwiftUI
import UIKit
import UniformTypeIdentifiers


// MARK: - UIKit 文件选择桥（替代 SwiftUI .fileImporter）
// 侧载安装环境下 SwiftUI .fileImporter 的选择器会吞掉点击、回调永不触发
// （GitHub 上有同类开源项目踩过同一个坑并这样修好）。改为从最顶层控制器
// 直接呈现 UIDocumentPickerViewController，绕开 SwiftUI 的呈现协调层。
enum DocumentPickerBridge {
    private static var activeCoordinator: Coordinator?

    static func presentPicker(contentTypes: [UTType], allowsMultiple: Bool,
                              completion: @escaping ([URL]?) -> Void) {
        // 稍等一拍，让触发它的菜单先完成关闭动画，避免呈现上下文被拆掉
        DispatchQueue.main.async {
            // 单槽协调者（M9）：新呈现前先把还挂着的旧请求按「取消」结算并记日志。
            // 旧 completion 被 activeCoordinator 强引用着，一旦被新请求覆盖就永不回调——
            // 菜单连点时导入假死正出在这里
            if let stale = activeCoordinator {
                AppLog.add("选择器", "上一个选择请求未结算，已先按取消处理")
                activeCoordinator = nil
                stale.settle(with: nil)
            }
            guard let presenter = topPresenter() else {
                AppLog.add("选择器", "打不开：找不到可呈现的界面")
                completion(nil)
                return
            }
            let coordinator = Coordinator(completion: completion)
            activeCoordinator = coordinator
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: false)
            picker.allowsMultipleSelection = allowsMultiple
            picker.delegate = coordinator
            AppLog.add("选择器", "已打开选择器（多选：\(allowsMultiple)）")
            presenter.present(picker, animated: true)
        }
    }

    private static func topPresenter() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    private final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let completion: ([URL]?) -> Void
        private var settled = false
        init(completion: @escaping ([URL]?) -> Void) { self.completion = completion }

        /// 只结算一次：被新请求顶替时由桥以 nil 结算，之后选择器自身的回调不再重复触发
        func settle(with urls: [URL]?) {
            guard !settled else { return }
            settled = true
            completion(urls)
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            AppLog.add("选择器", "已选择 \(urls.count) 项")
            settle(with: urls)
            DocumentPickerBridge.activeCoordinator = nil
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            AppLog.add("选择器", "用户取消选择")
            settle(with: nil)
            DocumentPickerBridge.activeCoordinator = nil
        }
    }
}

// MARK: - 根视图：媒体库 + 搜索（iOS 26 Liquid Glass 基线）

struct ContentView: View {
    @StateObject private var store = LibraryStore()
    @StateObject private var scrape = ScrapeStore()
    @AppStorage("appearance.mode") private var appearanceRaw = AppearanceMode.system.rawValue

    var body: some View {
        TabView {
            Tab("媒体库", systemImage: "film.stack") {
                LibraryView()
            }
            Tab("文件源", systemImage: "folder") {
                SourcesView()
            }
            Tab("设置", systemImage: "gearshape") {
                SettingsView()
            }
            Tab("搜索", systemImage: "magnifyingglass") {
                SearchView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .environmentObject(store)
        .environmentObject(scrape)
        .preferredColorScheme(AppearanceMode(rawValue: appearanceRaw)?.scheme ?? nil)
    }
}

// MARK: - 外观（跟随系统 / 浅色 / 深色）

enum AppearanceMode: String, CaseIterable {
    case system, light, dark
    var label: String {
        switch self {
        case .system: return String(localized: "跟随系统")
        case .light: return String(localized: "浅色")
        case .dark: return String(localized: "深色")
        }
    }
    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - 排序 / 显示偏好

enum LibrarySort: String, CaseIterable {
    case recentPlayed, recentAdded, name
    var label: String {
        switch self {
        case .recentPlayed: return String(localized: "最近播放")
        case .recentAdded: return String(localized: "最近添加")
        case .name: return String(localized: "片名")
        }
    }
}

enum LibraryDisplay: String, CaseIterable {
    case grid, list
    var label: String { self == .grid ? String(localized: "网格") : String(localized: "列表") }
}

// MARK: - 剧集识别（按文件名自动收纳：S01E02 / 第X集）

enum EpisodeParser {
    struct Info {
        let show: String
        let season: Int
        let episode: Int
    }

    static func parse(_ name: String) -> Info? {
        if let m = match(#"[Ss](\d{1,2})[Ee](\d{1,3})"#, in: name),
           let season = Int(m.1), let episode = Int(m.2) {
            let show = cleanShow(String(name[..<m.range.lowerBound]))
            return Info(show: show.isEmpty ? name : show, season: season, episode: episode)
        }
        if let m = match(#"第\s*(\d{1,3})\s*集"#, in: name),
           let episode = Int(m.1) {
            let show = cleanShow(String(name[..<m.range.lowerBound]))
            return Info(show: show.isEmpty ? name : show, season: 1, episode: episode)
        }
        return nil
    }

    static func episodeSort(_ a: MediaItem, _ b: MediaItem) -> Bool {
        let ia = parse(a.name)
        let ib = parse(b.name)
        if let ia, let ib {
            if ia.season != ib.season { return ia.season < ib.season }
            if ia.episode != ib.episode { return ia.episode < ib.episode }
        }
        return a.name.localizedCompare(b.name) == .orderedAscending
    }

    private static func match(_ pattern: String, in text: String)
        -> (range: Range<String.Index>, String, String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let full = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: full),
              let r = Range(m.range, in: text) else { return nil }
        func group(_ index: Int) -> String {
            guard m.numberOfRanges > index, let gr = Range(m.range(at: index), in: text) else { return "" }
            return String(text[gr])
        }
        return (r, group(1), group(2))
    }

    private static func cleanShow(_ raw: String) -> String {
        raw.replacingOccurrences(of: ".", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " _-·"))
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - 媒体库

struct LibraryView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var scrape: ScrapeStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("library.sort") private var sortRaw = LibrarySort.recentPlayed.rawValue
    @AppStorage("library.display") private var displayRaw = LibraryDisplay.grid.rawValue

    @State private var activeItem: MediaItem?
    @State private var scanSummary: String?
    @State private var importError: String?
    @State private var autoplayDone = false

    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .recentPlayed }
    private var display: LibraryDisplay { LibraryDisplay(rawValue: displayRaw) ?? .grid }

    private var sortedItems: [MediaItem] {
        switch sort {
        case .recentPlayed:
            return store.items.sorted { ($0.lastPlayedAt ?? $0.addedAt) > ($1.lastPlayedAt ?? $1.addedAt) }
        case .recentAdded:
            return store.items.sorted { $0.addedAt > $1.addedAt }
        case .name:
            return store.items.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
    }

    /// 大字体（无障碍字号）时网格自动降为列表，避免小屏崩版
    private var effectiveDisplay: LibraryDisplay {
        typeSize.isAccessibilitySize ? .list : display
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    EmptyLibraryView(
                        onImport: { pickFiles() },
                        onScan: { pickFolder() }
                    )
                } else if effectiveDisplay == .grid {
                    homeBody
                } else {
                    listBody
                }
            }
            .navigationTitle("Lumen")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { pickFolder() } label: { Label("添加文件夹", systemImage: "folder.badge.plus") }
                        Button { pickFiles() } label: { Label("导入文件", systemImage: "doc.badge.plus") }
                        if !store.sources.isEmpty {
                            Button { rescan() } label: { Label("重新扫描", systemImage: "arrow.triangle.2.circlepath") }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("排序", selection: $sortRaw) {
                            ForEach(LibrarySort.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                        }
                        Picker("显示", selection: $displayRaw) {
                            ForEach(LibraryDisplay.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .alert("操作失败", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("好") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .alert("扫描完成", isPresented: Binding(
            get: { scanSummary != nil },
            set: { if !$0 { scanSummary = nil } }
        )) {
            Button("好") { scanSummary = nil }
        } message: {
            Text(scanSummary ?? "")
        }
        .onOpenURL { url in
            store.handleIncomingFile(url)
        }
        .task {
            // 启动自动扫描：App 自身文档目录 + 全部文件源；剧集自动刮削元数据
            store.scanOwnDocuments()
            store.rescanSavedFolder()
            scrape.ensureAll(items: store.items)
        }
        .onAppear { autoplayIfNeeded() }
        .onChange(of: store.items.count) { _, _ in
            scrape.ensureAll(items: store.items)
            autoplayIfNeeded()
        }
        .fullScreenCover(item: $activeItem) { item in
            PlaybackFlow(item: item, store: store, scrape: scrape)
        }
    }

    private func pickFiles() {
        DocumentPickerBridge.presentPicker(
            contentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie, .item],
            allowsMultiple: true) { urls in
            guard let urls, !urls.isEmpty else { return }
            AppLog.add("导入", "选择器返回 \(urls.count) 个文件")
            urls.forEach { _ = store.addFile(url: $0) }
            // 导入失败要真正弹错（M7）：store 记录了失败原因，视图层一直没人接
            if let error = store.lastImportError { importError = error }
        }
    }

    private func pickFolder() {
        DocumentPickerBridge.presentPicker(contentTypes: [.folder], allowsMultiple: false) { urls in
            guard let folder = urls?.first else { return }
            let r = store.addSource(url: folder)
            if let error = store.lastImportError {
                importError = error
            } else {
                scanSummary = String(localized: "已添加文件源「\(folder.lastPathComponent)」：共找到 \(r.found) 个视频，新加入媒体库 \(r.added) 个。之后每次打开 App 都会自动扫描。")
            }
        }
    }

    private func pickSubtitle(for item: MediaItem) {
        DocumentPickerBridge.presentPicker(contentTypes: [.item], allowsMultiple: false) { urls in
            if let url = urls?.first { store.attachSubtitle(item: item, url: url) }
        }
    }

    // MARK: 首页分区（继续观看 / 最近添加 / 剧集 / 其他）

    private var seriesGroups: [(show: String, episodes: [MediaItem])] {
        var dict: [String: [MediaItem]] = [:]
        for item in store.items {
            if let info = EpisodeParser.parse(item.name) {
                dict[info.show, default: []].append(item)
            }
        }
        return dict.filter { $0.value.count >= 2 }
            .map { (show: $0.key, episodes: $0.value.sorted(by: EpisodeParser.episodeSort)) }
            .sorted { $0.show.localizedCompare($1.show) == .orderedAscending }
    }

    private var groupedIDs: Set<UUID> {
        Set(seriesGroups.flatMap { $0.episodes.map(\.id) })
    }

    private var standaloneItems: [MediaItem] {
        sortedItems.filter { !groupedIDs.contains($0.id) }
    }

    private var allRecentItems: [MediaItem] {
        store.items.sorted { $0.addedAt > $1.addedAt }
    }

    private var recentItems: [MediaItem] {
        Array(allRecentItems.prefix(10))
    }

    /// 最近添加的一张卡：同一部剧的多集折叠成一张剧集卡（点进剧集页），单片保持条目卡（点开即播）
    private struct RecentCard: Identifiable {
        let id: String
        let show: String?
        let episodes: [MediaItem]
        let item: MediaItem
    }

    private func groupedRecents(_ items: [MediaItem]) -> [RecentCard] {
        var seenShows = Set<String>()
        var cards: [RecentCard] = []
        for item in items {
            if let info = EpisodeParser.parse(item.name) {
                guard seenShows.insert(info.show).inserted else { continue }
                let episodes = store.items.filter { EpisodeParser.parse($0.name)?.show == info.show }
                cards.append(RecentCard(id: "show:" + info.show, show: info.show, episodes: episodes, item: item))
            } else {
                cards.append(RecentCard(id: item.id.uuidString, show: nil, episodes: [item], item: item))
            }
        }
        return cards
    }

    private var recentCards: [RecentCard] { groupedRecents(recentItems) }
    private var allRecentCardCount: Int { groupedRecents(allRecentItems).count }

    private var homeBody: some View {
        GeometryReader { geo in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    if !store.continueWatching.isEmpty {
                        continueSection(cardWidth: min(300, max(252, geo.size.width * 0.68)))
                    }
                    recentSection
                    if !seriesGroups.isEmpty {
                        seriesSection
                    }
                    standaloneSection
                }
                .padding(.top, 8)
                // 底部留白大于悬浮 dock 高度，最后一个分区的文字不被压住
                .padding(.bottom, 120)
            }
        }
    }

    /// 分区标题行：左侧分区名，右侧「全部 · N ›」进入该分区的全量页
    private func sectionHeader<Destination: View>(_ title: LocalizedStringKey,
                                                  count: Int,
                                                  @ViewBuilder destination: () -> Destination) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.bold))
            Spacer()
            NavigationLink {
                destination()
            } label: {
                HStack(spacing: 3) {
                    Text("全部 · \(count)")
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
    }

    private func continueSection(cardWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("继续观看", count: store.continueWatching.count) {
                LibraryContinueGridPage(items: store.continueWatching)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(store.continueWatching) { item in
                        ContinueCard(item: item, width: cardWidth) { activeItem = item }
                            .contextMenu { mediaMenu(item) }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("最近添加", count: allRecentCardCount) {
                LibraryItemsGridPage(title: "最近添加", items: allRecentItems)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(recentCards) { card in
                        if let show = card.show {
                            NavigationLink {
                                SeriesView(show: show)
                            } label: {
                                SeriesCard(show: show, episodes: card.episodes)
                                    .frame(width: 110)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { mediaMenu(card.item) }
                        } else {
                            MediaCell(item: card.item, showName: true) { activeItem = card.item }
                                .frame(width: 110)
                                .contextMenu { mediaMenu(card.item) }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var seriesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("剧集", count: seriesGroups.count) {
                LibrarySeriesGridPage(groups: seriesGroups)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(seriesGroups, id: \.show) { group in
                        NavigationLink {
                            SeriesView(show: group.show)
                        } label: {
                            SeriesCard(show: group.show, episodes: group.episodes)
                                .frame(width: 110)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var standaloneSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(seriesGroups.isEmpty ? "全部影片" : "电影与其他",
                          count: standaloneItems.count) {
                LibraryItemsGridPage(title: seriesGroups.isEmpty ? "全部影片" : "电影与其他",
                                     items: standaloneItems)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 170), spacing: 12)], spacing: 18) {
                ForEach(standaloneItems) { item in
                    MediaCell(item: item, showName: true) { activeItem = item }
                        .contextMenu { mediaMenu(item) }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var listBody: some View {
        List {
            if !store.continueWatching.isEmpty {
                Section("继续观看") {
                    ForEach(store.continueWatching) { item in
                        MediaRow(item: item) { activeItem = item }
                            .contextMenu { mediaMenu(item) }
                    }
                }
            }
            Section("全部影片") {
                ForEach(sortedItems) { item in
                    MediaRow(item: item) { activeItem = item }
                        .contextMenu { mediaMenu(item) }
                }
                .onDelete { offsets in
                    offsets.map { sortedItems[$0] }.forEach(store.remove)
                }
            }
        }
        .listStyle(.plain)
    }

    /// CI 自测钩子：带 -autoplayFirst 启动时，条目载入后自动打开第一条能解析出集数的条目（只触发一次）
    private func autoplayIfNeeded() {
        guard !autoplayDone else { return }
        guard ProcessInfo.processInfo.arguments.contains("-autoplayFirst") else { return }
        guard let target = store.items.first(where: { EpisodeParser.parse($0.name) != nil }) else { return }
        autoplayDone = true
        activeItem = target
    }

    private func rescan() {
        if let r = store.rescanSavedFolder() {
            scanSummary = String(localized: "重新扫描完成：共 \(r.found) 个视频，新加入 \(r.added) 个。")
        }
    }

    @ViewBuilder
    private func mediaMenu(_ item: MediaItem) -> some View {
        Button { activeItem = item } label: { Label("播放", systemImage: "play.fill") }
        if item.subtitleName == nil {
            Button { pickSubtitle(for: item) } label: { Label("添加外挂字幕", systemImage: "captions.bubble") }
        } else {
            Button { pickSubtitle(for: item) } label: { Label("更换外挂字幕", systemImage: "captions.bubble") }
            Button(role: .destructive) { store.detachSubtitle(item: item) } label: {
                Label("移除外挂字幕", systemImage: "captions.bubble.slash")
            }
        }
        Divider()
        Button(role: .destructive) { store.remove(item) } label: { Label("删除", systemImage: "trash") }
    }
}

// MARK: - 空库引导（自绘以保证对比度与按钮层级，深浅色都清晰）

struct EmptyLibraryView: View {
    let onImport: () -> Void
    let onScan: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text("暂无影片")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Text("添加一个文件夹作为文件源，视频会自动入库。\n点开即播：MKV、MP4 等格式直接读取播放。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) {
                Button(action: onScan) {
                    Text("添加文件夹").frame(maxWidth: 220)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button(action: onImport) {
                    Text("导入单个文件").frame(maxWidth: 220)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 海报占位图（无海报时按片名生成的标题图，2:3）

struct PosterArt: View {
    let item: MediaItem
    var wide = false

    private static let palettes: [(Color, Color)] = [
        (Color(red: 0.16, green: 0.19, blue: 0.30), Color(red: 0.03, green: 0.03, blue: 0.07)),
        (Color(red: 0.26, green: 0.14, blue: 0.27), Color(red: 0.07, green: 0.03, blue: 0.09)),
        (Color(red: 0.10, green: 0.24, blue: 0.19), Color(red: 0.02, green: 0.07, blue: 0.05)),
        (Color(red: 0.30, green: 0.21, blue: 0.11), Color(red: 0.08, green: 0.05, blue: 0.02)),
        (Color(red: 0.09, green: 0.23, blue: 0.27), Color(red: 0.02, green: 0.07, blue: 0.08)),
        (Color(red: 0.30, green: 0.12, blue: 0.15), Color(red: 0.08, green: 0.03, blue: 0.04)),
    ]

    private var palette: (Color, Color) {
        let seed = item.name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Self.palettes[abs(seed) % Self.palettes.count]
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [palette.0, palette.1], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack {
                HStack {
                    LiuGuangGlyph()
                    Spacer()
                }
                Spacer()
            }
            .padding(10)
            Text(item.name)
                .font(wide ? .headline : .subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(3)
                .padding(10)
        }
        .aspectRatio(wide ? 16.0 / 9.0 : 2.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }
}

/// 流光三线（与 App 图标 A 款一致的符号）
struct LiuGuangGlyph: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 3.5) {
            bar(width: 30)
            bar(width: 21)
            bar(width: 26)
        }
    }
    private func bar(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(.white.opacity(0.92))
            .frame(width: width, height: 5)
    }
}

// MARK: - 网格单元 / 列表行 / 继续观看卡

extension MediaItem {
    var isRemote: Bool { urlString != nil }
    var formatText: String {
        if let e = fileExtension, !e.isEmpty { return e.uppercased() }
        let ext = ((urlString ?? name) as NSString).pathExtension.uppercased()
        return ext.isEmpty ? String(localized: "视频") : ext
    }
    var captionText: String {
        var parts = [isRemote ? String(localized: "直链") : String(localized: "本地"), formatText]
        if subtitleName != nil { parts.append(String(localized: "外挂字幕")) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 卡片数据解析（显示名 / 分集行 / 年份：刮削优先，未刮削退清洗文件名）

/// 季/集计数文案：英文单数单独成句，避免出现 "1 Seasons / 1 Episodes"
func seasonCountText(_ seasons: Int) -> String {
    seasons == 1 ? String(localized: "共 1 季") : String(localized: "共 \(seasons) 季")
}

func episodeCountText(_ count: Int) -> String {
    count == 1 ? String(localized: "共 1 集") : String(localized: "共 \(count) 集")
}

enum CardText {
    /// 清洗文件名：去扩展名，点与下划线转空格
    static func cleaned(_ name: String) -> String {
        (name as NSString).deletingPathExtension
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// 卡片显示名：刮削标题优先，其次解析出的剧名，最后清洗文件名
    @MainActor
    static func title(for item: MediaItem, scrape: ScrapeStore) -> String {
        if let info = EpisodeParser.parse(item.name) {
            return scrape.meta(for: info.show)?.title ?? info.show
        }
        return cleaned(item.name)
    }

    /// 分集行：「第2季 第2集 · 分集名」，非剧集条目返回 nil
    @MainActor
    static func episodeLine(for item: MediaItem, scrape: ScrapeStore) -> String? {
        guard let info = EpisodeParser.parse(item.name) else { return nil }
        var line = String(localized: "第\(info.season)季 第\(info.episode)集")
        if let meta = scrape.meta(for: info.show),
           let ep = meta.episodes[ScrapeStore.episodeKey(season: info.season, episode: info.episode)],
           !ep.title.isEmpty {
            line += " · \(ep.title)"
        }
        return line
    }

    /// 文件名里的年份（电影副信息用），解析不到返回 nil
    static func year(in name: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "(?:19|20)\\d{2}"),
              let m = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let r = Range(m.range, in: name) else { return nil }
        return String(name[r])
    }

    /// 秒数显示：不足 1 小时「28:04」，超过「1:01:11」
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

/// 安静占位图：按名字取色的低饱和渐变 + 居中品牌字形，卡面上不出现任何文件名文字
struct QuietArtwork: View {
    let seed: String
    var wide = false

    private static let palettes: [(Color, Color)] = [
        (Color(red: 0.16, green: 0.19, blue: 0.30), Color(red: 0.03, green: 0.03, blue: 0.07)),
        (Color(red: 0.26, green: 0.14, blue: 0.27), Color(red: 0.07, green: 0.03, blue: 0.09)),
        (Color(red: 0.10, green: 0.24, blue: 0.19), Color(red: 0.02, green: 0.07, blue: 0.05)),
        (Color(red: 0.30, green: 0.21, blue: 0.11), Color(red: 0.08, green: 0.05, blue: 0.02)),
        (Color(red: 0.09, green: 0.23, blue: 0.27), Color(red: 0.02, green: 0.07, blue: 0.08)),
        (Color(red: 0.30, green: 0.12, blue: 0.15), Color(red: 0.08, green: 0.03, blue: 0.04)),
    ]

    private var palette: (Color, Color) {
        let value = seed.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Self.palettes[abs(value) % Self.palettes.count]
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [palette.0, palette.1], startPoint: .topLeading, endPoint: .bottomTrailing)
            LiuGuangGlyph()
                .opacity(0.55)
        }
        .aspectRatio(wide ? 16.0 / 9.0 : 2.0 / 3.0, contentMode: .fit)
    }
}

/// 竖版卡面（2:3）：剧集海报 → 视频帧缩略图 → 安静占位，三级回退都不出现文件名
struct PosterArtwork: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var scrape: ScrapeStore
    let item: MediaItem
    var show: String? = nil
    @State private var thumb: UIImage?

    private var poster: UIImage? {
        guard let show else { return nil }
        return scrape.posterImage(for: show)
    }

    var body: some View {
        ZStack {
            QuietArtwork(seed: item.name)
            if let poster {
                Image(uiImage: poster)
                    .resizable()
                    .scaledToFill()
            } else if let thumb {
                Image(uiImage: thumb)
                    .resizable()
                    .scaledToFill()
            }
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .task(id: item.id) {
            guard poster == nil else { return }
            if let cached = ThumbnailStore.cached(for: item) {
                thumb = cached
            } else {
                thumb = await ThumbnailStore.generate(for: item, store: store)
            }
        }
    }
}

/// 横版卡面（16:9）：分集剧照 → 节目海报 → 安静占位
struct WideArtwork: View {
    @EnvironmentObject private var scrape: ScrapeStore
    let item: MediaItem

    private var image: UIImage? {
        guard let info = EpisodeParser.parse(item.name) else { return nil }
        if let still = scrape.stillImage(for: info.show, season: info.season, episode: info.episode) {
            return still
        }
        return scrape.posterImage(for: info.show)
    }

    var body: some View {
        ZStack {
            QuietArtwork(seed: item.name, wide: true)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }
}

/// 评分角标（卡面右下角，深色胶囊白字）
struct RatingBadge: View {
    let rating: Double

    var body: some View {
        Text(String(format: "%.1f", rating))
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(.black.opacity(0.62)))
    }
}

struct MediaCell: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var scrape: ScrapeStore
    let item: MediaItem
    var showName = false
    let onPlay: () -> Void

    private var info: EpisodeParser.Info? { EpisodeParser.parse(item.name) }

    private var rating: Double? {
        guard let info else { return nil }
        return scrape.meta(for: info.show)?.rating
    }

    /// 副信息：剧集按库内季数「共 N 季」（算不出季数退「共 N 集」），电影显示文件名年份
    private var subtitleText: String {
        if let info {
            let episodes = store.items.filter { EpisodeParser.parse($0.name)?.show == info.show }
            let seasons = Set(episodes.compactMap { EpisodeParser.parse($0.name)?.season }).count
            if seasons > 0 { return seasonCountText(seasons) }
            return episodeCountText(episodes.count)
        }
        if let year = CardText.year(in: item.name) { return year }
        return item.captionText
    }

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    PosterArtwork(item: item, show: info?.show)
                    if let rating {
                        RatingBadge(rating: rating)
                            .padding(6)
                    }
                }
                if let p = store.progressMap[item.id] {
                    ProgressBar(value: p)
                }
                if showName {
                    Text(CardText.title(for: item, scrape: scrape))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Text(subtitleText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("播放 \(item.name)")
    }
}

/// 海报：有真实视频帧缩略图时显示缩略图，否则用标题占位图
struct PosterView: View {
    @EnvironmentObject private var store: LibraryStore
    let item: MediaItem
    var wide = false
    @State private var thumb: UIImage?

    var body: some View {
        ZStack {
            PosterArt(item: item, wide: wide)
            if let thumb {
                Image(uiImage: thumb)
                    .resizable()
                    .scaledToFill()
            }
        }
        .aspectRatio(wide ? 16.0 / 9.0 : 2.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: item.id) {
            if let cached = ThumbnailStore.cached(for: item) {
                thumb = cached
            } else {
                thumb = await ThumbnailStore.generate(for: item, store: store)
            }
        }
    }
}

/// 剧集卡（首页「剧集」分区）：刮削海报卡面 + 评分角标，副信息按库内季数显示
struct SeriesCard: View {
    @EnvironmentObject private var scrape: ScrapeStore
    let show: String
    let episodes: [MediaItem]

    private var seasons: Int {
        Set(episodes.compactMap { EpisodeParser.parse($0.name)?.season }).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                PosterArtwork(item: episodes[0], show: show)
                if let rating = scrape.meta(for: show)?.rating {
                    RatingBadge(rating: rating)
                        .padding(6)
                }
            }
            Text(scrape.meta(for: show)?.title ?? show)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(seasons > 0 ? seasonCountText(seasons) : episodeCountText(episodes.count))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// 剧集详情页：海报头图 + 简介 + 演职人员 + 带剧照的分集列表（刮削数据来自 TVmaze）
struct SeriesView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var scrape: ScrapeStore
    let show: String
    @State private var activeItem: MediaItem?

    private var episodes: [MediaItem] {
        store.items
            .filter { EpisodeParser.parse($0.name)?.show == show }
            .sorted(by: EpisodeParser.episodeSort)
    }

    private var meta: ShowMeta? { scrape.meta(for: show) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let meta, !meta.cast.isEmpty {
                    castSection(meta)
                }
                episodesSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .navigationTitle(show)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $activeItem) { item in
            PlaybackFlow(item: item, store: store, scrape: scrape)
        }
        .task { scrape.ensureAll(items: store.items) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let img = scrape.posterImage(for: show) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else if let first = episodes.first {
                    PosterView(item: first)
                }
            }
            .frame(width: 104, height: 156)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(meta?.title ?? show)
                    .font(.title3.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                if let meta {
                    HStack(spacing: 6) {
                        if let year = meta.year { Text(year) }
                        if let rating = meta.rating {
                            Label(String(format: "%.1f", rating), systemImage: "star.fill")
                        }
                        if !meta.genres.isEmpty {
                            Text(meta.genres.prefix(3).joined(separator: " · "))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let summary = meta.summary {
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("正在匹配剧集信息…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("共 \(episodes.count) 集")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func castSection(_ meta: ShowMeta) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("演职人员")
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(meta.cast.indices, id: \.self) { index in
                        let member = meta.cast[index]
                        VStack(spacing: 5) {
                            castAvatar(member)
                            Text(member.name)
                                .font(.caption2.weight(.medium))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                            if let character = member.character {
                                Text(character)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: 64)
                    }
                }
            }
        }
    }

    private func castAvatar(_ member: CastMember) -> some View {
        Group {
            if let img = ScrapeStore.image(named: member.imageFile) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.25))
                    .overlay {
                        Image(systemName: "person.fill")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: 54, height: 54)
        .clipShape(Circle())
    }

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("分集")
                .font(.headline)
                .padding(.bottom, 4)
            ForEach(episodes) { item in
                episodeRow(item)
                Divider()
            }
        }
    }

    private func episodeRow(_ item: MediaItem) -> some View {
        let info = EpisodeParser.parse(item.name)
        let em = info.flatMap { meta?.episodes[ScrapeStore.episodeKey(season: $0.season, episode: $0.episode)] }
        return Button {
            activeItem = item
        } label: {
            HStack(spacing: 12) {
                Group {
                    if let info, let img = scrape.stillImage(for: show, season: info.season, episode: info.episode) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        PosterView(item: item, wide: true)
                    }
                }
                .frame(width: 118, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    if let info {
                        Text("第 \(info.episode) 集 · \(ScrapeStore.episodeKey(season: info.season, episode: info.episode))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(em?.title ?? item.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if let runtime = em?.runtime {
                        Text("\(runtime) 分钟")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let p = store.progressMap[item.id] {
                        ProgressBar(value: p)
                            .frame(maxWidth: 140)
                    }
                }
                Spacer()
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { activeItem = item } label: { Label("播放", systemImage: "play.fill") }
            Button(role: .destructive) { store.remove(item) } label: { Label("删除", systemImage: "trash") }
        }
    }
}

struct MediaRow: View {
    let item: MediaItem
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                PosterView(item: item)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(item.captionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    MediaProgress(item: item)
                }
                Spacer()
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 行内进度（独立小组件以便读取环境中的 store）
struct MediaProgress: View {
    @EnvironmentObject private var store: LibraryStore
    let item: MediaItem
    var body: some View {
        if let p = store.progressMap[item.id] {
            ProgressBar(value: p).frame(maxWidth: 160)
        }
    }
}

/// 继续观看卡（16:9）：剧照卡面 + 毛玻璃播放键 + 底部细进度线与时间，卡下两行显示名与分集行
struct ContinueCard: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var scrape: ScrapeStore
    let item: MediaItem
    var width: CGFloat = 264
    let onPlay: () -> Void

    private var progress: Double? { store.progressMap[item.id] }

    /// 卡内右下时间：续播秒数与总时长都有时显示「28:04 / 1:01:11」，否则退百分比
    private var timeText: String? {
        guard let progress else { return nil }
        if let position = ResumeStore.position(forKey: item.id.uuidString), progress > 0 {
            return "\(CardText.clock(position)) / \(CardText.clock(position / progress))"
        }
        return String(localized: "已看 \(Int(progress * 100))%")
    }

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 7) {
                ZStack {
                    WideArtwork(item: item)
                    // 卡面底部渐变：保证时间文本压在亮剧照上也可读
                    LinearGradient(colors: [.clear, .black.opacity(0.45)],
                                   startPoint: .center, endPoint: .bottom)
                    // 毛玻璃圆底播放键
                    ZStack {
                        Circle().fill(.ultraThinMaterial)
                        Image(systemName: "play.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .offset(x: 1.5)
                    }
                    .frame(width: 46, height: 46)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                    if let timeText {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                Text(timeText)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
                            }
                        }
                        .padding(.trailing, 8)
                        .padding(.bottom, 8)
                    }
                    if let progress {
                        VStack {
                            Spacer()
                            ProgressBar(value: progress, height: 3, onDarkBackground: true)
                        }
                    }
                }
                Text(CardText.title(for: item, scrape: scrape))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let line = CardText.episodeLine(for: item, scrape: scrape) ?? CardText.year(in: item.name) {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: width)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("继续播放 \(item.name)")
    }
}

struct ProgressBar: View {
    let value: Double
    var height: CGFloat = 3
    var onDarkBackground = false
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(onDarkBackground ? .white.opacity(0.25) : Color.primary.opacity(0.15))
                Capsule().fill(onDarkBackground ? .white : Color.accentColor)
                    .frame(width: geo.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: height)
    }
}

// MARK: - 分区全量页（分区标题「全部 · N ›」进入，与首页共用同一套卡片组件）

struct LibraryItemsGridPage: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var scrape: ScrapeStore
    let title: LocalizedStringKey
    let items: [MediaItem]
    @State private var activeItem: MediaItem?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 170), spacing: 12)], spacing: 18) {
                ForEach(items) { item in
                    MediaCell(item: item, showName: true) { activeItem = item }
                        .contextMenu {
                            Button { activeItem = item } label: { Label("播放", systemImage: "play.fill") }
                            Button(role: .destructive) { store.remove(item) } label: { Label("删除", systemImage: "trash") }
                        }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 120)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $activeItem) { item in
            PlaybackFlow(item: item, store: store, scrape: scrape)
        }
    }
}

struct LibrarySeriesGridPage: View {
    let groups: [(show: String, episodes: [MediaItem])]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 170), spacing: 12)], spacing: 18) {
                ForEach(groups, id: \.show) { group in
                    NavigationLink {
                        SeriesView(show: group.show)
                    } label: {
                        SeriesCard(show: group.show, episodes: group.episodes)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 120)
        }
        .navigationTitle("剧集")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LibraryContinueGridPage: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var scrape: ScrapeStore
    let items: [MediaItem]
    @State private var activeItem: MediaItem?

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(items) { item in
                        ContinueCard(item: item, width: geo.size.width - 32) { activeItem = item }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 120)
            }
        }
        .navigationTitle("继续观看")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $activeItem) { item in
            PlaybackFlow(item: item, store: store, scrape: scrape)
        }
    }
}

// MARK: - 搜索

struct SearchView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var scrape: ScrapeStore
    @State private var query = ""
    @State private var activeItem: MediaItem?

    private var results: [MediaItem] {
        query.isEmpty ? store.items : store.items.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(results) { item in
                        MediaRow(item: item) { activeItem = item }
                            .contextMenu {
                                Button { activeItem = item } label: { Label("播放", systemImage: "play.fill") }
                                Button(role: .destructive) { store.remove(item) } label: { Label("删除", systemImage: "trash") }
                            }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("搜索")
        }
        .searchable(text: $query, prompt: "搜索片名")
        .fullScreenCover(item: $activeItem) { item in
            PlaybackFlow(item: item, store: store, scrape: scrape)
        }
    }
}

// MARK: - 文件源（本地来源管理：扫描文件夹 / 导入）

struct SourcesView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var summary: String?
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            List {
                Section("本机目录") {
                    Text("打开「文件」App →「浏览」→「我的 iPhone」→「Lumen」，把视频或整个文件夹拷进来，回到 Lumen 就会自动出现在媒体库里，不需要在 App 里做任何选择。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        let added = store.scanOwnDocuments()
                        summary = added > 0 ? String(localized: "新入库 \(added) 个视频。") : String(localized: "没有发现新视频。先把视频拷进「文件」App 的 Lumen 文件夹再试。")
                    } label: {
                        Label("扫描本机目录", systemImage: "folder.badge.gearshape")
                    }
                }
                Section("文件源（文件夹）") {
                    if store.sources.isEmpty {
                        Text("还没有添加文件夹。添加后，文件夹里的视频会原地读取、自动入库，不拷贝文件。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.sources) { source in
                        Label(source.name, systemImage: "folder.fill")
                    }
                    .onDelete { offsets in
                        offsets.map { store.sources[$0] }.forEach(store.removeSource)
                    }
                    Button {
                        pickFolder()
                    } label: {
                        Label("添加文件夹", systemImage: "folder.badge.plus")
                    }
                    if !store.sources.isEmpty {
                        Button {
                            rescan()
                        } label: {
                            Label("重新扫描全部", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    Text("每次打开 App 都会自动扫描文件源里的新视频。左滑可移除文件源（已入库的条目不受影响）。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("导入单个文件") {
                    Button {
                        pickFiles()
                    } label: {
                        Label("从「文件」导入", systemImage: "doc.badge.plus")
                    }
                    Text("单个大文件（几个 GB）经系统选择器导出会很慢，建议用上面的「添加文件夹」加入它所在的文件夹。也可以把视频拷进「文件」App 里 Lumen 的文件夹，下次打开 App 时会自动入库。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("媒体库") {
                    LabeledContent("视频总数", value: "\(store.items.count)")
                }
            }
            .navigationTitle("文件源")
        }
        .alert("扫描完成", isPresented: Binding(
            get: { summary != nil },
            set: { if !$0 { summary = nil } }
        )) {
            Button("好") { summary = nil }
        } message: {
            Text(summary ?? "")
        }
        .alert("操作失败", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("好") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private func pickFiles() {
        DocumentPickerBridge.presentPicker(
            contentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie, .item],
            allowsMultiple: true) { urls in
            guard let urls, !urls.isEmpty else { return }
            AppLog.add("导入", "选择器返回 \(urls.count) 个文件")
            urls.forEach { _ = store.addFile(url: $0) }
            if let error = store.lastImportError { importError = error }
        }
    }

    private func pickFolder() {
        DocumentPickerBridge.presentPicker(contentTypes: [.folder], allowsMultiple: false) { urls in
            guard let folder = urls?.first else { return }
            let r = store.addSource(url: folder)
            if let error = store.lastImportError {
                importError = error
            } else {
                summary = String(localized: "已添加文件源「\(folder.lastPathComponent)」：共找到 \(r.found) 个视频，新加入媒体库 \(r.added) 个。")
            }
        }
    }

    private func rescan() {
        let r = store.rescanAllSources()
        summary = String(localized: "重新扫描完成：共 \(r.found) 个视频，新加入 \(r.added) 个。")
    }
}

// MARK: - 设置

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance.mode") private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage("settings.autoResume") private var autoResume = true
    @AppStorage("settings.autoNext") private var autoNext = true
    @AppStorage("settings.autoPiP") private var autoPiP = true
    @AppStorage("settings.rememberRate") private var rememberRate = true
    @AppStorage("settings.subFontSize") private var subFontSize: Double = 17
    @AppStorage(PlayerSettings.nativeModeKey) private var nativeMode = false
    @AppStorage(PlayerSettings.skipKey) private var skipIntroOutro = false
    @AppStorage(PlayerSettings.introSecondsKey) private var introSeconds: Double = 90
    @AppStorage(PlayerSettings.outroSecondsKey) private var outroSeconds: Double = 120
    @AppStorage(PlayerSettings.showPrevNextKey) private var showPrevNextButtons = true
    @AppStorage(PlayerSettings.showSeekButtonsKey) private var showSeekButtons = true
    @AppStorage(PlayerSettings.mpvSubtitleFontSizeKey) private var mpvSubtitleFontSize: Int = 55
    @State private var cacheNote: String?
    @State private var scanNote: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("外观") {
                    Picker("外观", selection: $appearanceRaw) {
                        ForEach(AppearanceMode.allCases, id: \.rawValue) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("播放器界面始终为深色，不受此设置影响。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("播放") {
                    Toggle("自动续播", isOn: $autoResume)
                    Toggle("自动连播下一集", isOn: $autoNext)
                    Toggle("退出时自动画中画", isOn: $autoPiP)
                    Toggle("记住播放速度", isOn: $rememberRate)
                    Toggle("原生模式", isOn: $nativeMode)
                    Text("默认直读直放，点开即播。开启原生模式后，视频先无损重封装再用系统播放器播放，画中画也仅在此模式可用。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Toggle("跳过片头片尾", isOn: $skipIntroOutro)
                    if skipIntroOutro {
                        Stepper(value: $introSeconds, in: 0...600, step: 5) {
                            LabeledContent("片头时长", value: String(localized: "\(Int(introSeconds)) 秒"))
                        }
                        Stepper(value: $outroSeconds, in: 0...600, step: 5) {
                            LabeledContent("片尾时长", value: String(localized: "\(Int(outroSeconds)) 秒"))
                        }
                    }
                    Toggle("上一集 / 下一集按钮", isOn: $showPrevNextButtons)
                    Toggle("快退 / 快进按钮", isOn: $showSeekButtons)
                    Stepper(value: $subFontSize, in: 13...26, step: 1) {
                        LabeledContent("字幕字号（原生模式）", value: "\(Int(subFontSize))")
                    }
                    Stepper(value: $mpvSubtitleFontSize, in: 36...80, step: 1) {
                        LabeledContent("字幕字号（直读）", value: "\(mpvSubtitleFontSize)")
                    }
                }
                Section("扫描") {
                    LabeledContent("文件源数量", value: "\(store.sources.count)")
                    if !store.sources.isEmpty {
                        Button("重新扫描全部") {
                            let r = store.rescanAllSources()
                            scanNote = String(localized: "共 \(r.found) 个视频，新加入 \(r.added) 个。")
                        }
                        Button("清除全部文件源", role: .destructive) {
                            store.clearScanFolder()
                            scanNote = nil
                        }
                    } else {
                        Text("在「文件源」页点「添加文件夹」，选一次文件夹，之后每次打开 App 都会自动把里面的新视频加入媒体库。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let scanNote {
                        Text(scanNote).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("数据") {
                    Button("清除续播记录", role: .destructive) {
                        ResumeStore.clearAll()
                        store.refreshProgress()
                    }
                    Button("清除重封装缓存") { clearRemuxCache() }
                    Text("原生模式播放时生成的无损重封装文件会缓存在本机，可在此清除。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let cacheNote {
                        Text(cacheNote).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("日志") {
                    NavigationLink("错误日志") { LogView() }
                    Text("导入、扫描、播放失败都会记在这里。遇到问题把日志复制发给我，就能定位在哪一步断的。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("关于") {
                    LabeledContent("版本", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"))")
                    NavigationLink("更新日志") { ChangelogView() }
                    Text("直读播放为默认，点开即播；字幕、音轨、章节一应俱全。原生模式可在设置或播放器更多设置中开启。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
        }
    }

    private func clearRemuxCache() {
        FFmpegRemuxer.clearCache()
        cacheNote = String(localized: "重封装缓存已清除。")
    }
}

// MARK: - 错误日志页

struct LogView: View {
    @State private var lines: [String] = []

    var body: some View {
        List {
            if lines.isEmpty {
                Text("暂无日志")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("错误日志")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        UIPasteboard.general.string = lines.joined(separator: "\n")
                    } label: { Label("复制全部", systemImage: "doc.on.doc") }
                    Button(role: .destructive) {
                        AppLog.clear()
                        lines = []
                    } label: { Label("清空日志", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear { lines = AppLog.all() }
    }
}

// MARK: - 播放流程：直读直放为默认；原生模式（手动开启）才走无损重封装 → 系统播放

enum PlaybackEngine: Equatable {
case avPlayer(URL)
case mpv(URL)
}

/// 原生模式下的字幕选项（外挂文件 / 重封装时提取的内封文本字幕），供叠加层选轨
struct NativeSubtitleOption: Identifiable {
let id: String
let label: String
let kindLabel: String
/// 默认选中优先级分数（越大越优先）：外挂最高，内封按简体＞繁体＞英文
let score: Int
let cues: [SubtitleCue]
}

struct PlaybackFlow: View {
let item: MediaItem
@ObservedObject var store: LibraryStore
var scrape: ScrapeStore? = nil
/// 方向上下文：模型判定写进来（1.4 起呈现层不再消费，仅保留参数兼容）
var orientationContext: PlaybackOrientationContext? = nil
@StateObject private var avModel = PlayerModel()
@StateObject private var mpvModel = MPVPlayerModel()
@Environment(\.dismiss) private var dismiss
@AppStorage(PlayerSettings.nativeModeKey) private var nativeMode = false

@State private var currentItem: MediaItem
@State private var engine: PlaybackEngine?
@State private var nativeOptions: [NativeSubtitleOption] = []
@State private var subtitleOptionsToken = 0
@State private var externalSubURL: URL?
@State private var remuxProgress: Double?
@State private var failure: String?
@State private var warnings: [String] = []
@State private var showWarnings = false
@State private var notice: String?
@State private var remuxer: FFmpegRemuxer?

init(item: MediaItem, store: LibraryStore, scrape: ScrapeStore? = nil,
orientationContext: PlaybackOrientationContext? = nil) {
self.item = item
self.store = store
self.scrape = scrape
self.orientationContext = orientationContext
_currentItem = State(initialValue: item)
}

private var episodes: [MediaItem] { store.episodesInSeries(of: currentItem)}
private var preferenceScope: String {
// 记忆归属：文件源内的相对目录名优先（合集盘里多部剧同目录时，文件名解析的剧名会串），
// 其次文件名解析的剧名，最后片名本身（B7）
if let rel = currentItem.relativePath {
let dir = (rel as NSString).deletingLastPathComponent
if !dir.isEmpty, dir != "." {
return (dir as NSString).lastPathComponent
}
}
return EpisodeParser.parse(currentItem.name)?.show ?? currentItem.name
}
/// 播放页标题：有刮削时用「剧名 SxxExx · 分集名」，否则退回清洗后的文件名
/// （去掉扩展名与发布组惯用的点分隔），不再把原始文件名直接摆给用户
private var displayTitle: String {
if let info = EpisodeParser.parse(currentItem.name),
   let meta = scrape?.meta(for: info.show) {
let key = ScrapeStore.episodeKey(season: info.season, episode: info.episode)
let base = "\(meta.title) \(key)"
if let episodeTitle = meta.episodes[key]?.title, !episodeTitle.isEmpty {
return "\(base) · \(episodeTitle)"
}
return base
}
return currentItem.name
.replacingOccurrences(of: ".", with: " ")
.replacingOccurrences(of: "_", with: " ")
.trimmingCharacters(in: .whitespaces)
}
private var hasPrevious: Bool { store.previousInSeries(before: currentItem) != nil}
private var hasNext: Bool { store.nextInSeries(after: currentItem) != nil}

var body: some View {
ZStack {
Color.black.ignoresSafeArea()
if let engine {
PlayerScreen(engine: engine, title: displayTitle,
nativeSubtitleOptions: nativeOptions,
externalSubtitleURL: externalSubURL,
resumeKey: currentItem.id.uuidString,
preferenceScope: preferenceScope,
notice: notice,
subtitleOptionsToken: subtitleOptionsToken,
episodes: episodes,
currentEpisodeID: currentItem.id,
stillProvider: stillImage(for:),
orientationContext: orientationContext,
avModel: avModel, mpvModel: mpvModel,
onClose: { dismiss()},
onSelectEpisode: { switchToEpisode($0)},
onPrevious: hasPrevious ? { goPrevious() } : nil,
onNext: hasNext ? { goNextManual() } : nil,
onLoadLocalSubtitle: { loadLocalSubtitle()})
.id(currentItem.id)
} else if let failure {
ContentUnavailableView {
Label("无法播放", systemImage: "exclamationmark.triangle")
} description: {
Text(failure)
} actions: {
Button("关闭") { dismiss()}
}
.foregroundStyle(.white)
} else {
preparingView
}
}
.preferredColorScheme(.dark)
.task { start()}
.onAppear {
store.touchPlayed(currentItem)
avModel.onPlaybackEnded = { advanceToNext(manual: false)}
mpvModel.onPlaybackEnded = { advanceToNext(manual: false)}
avModel.onOutroReached = { advanceToNext(manual: false)}
mpvModel.onOutroReached = { advanceToNext(manual: false)}
avModel.onSkipOutroRequested = { advanceToNext(manual: true)}
mpvModel.onSkipOutroRequested = { advanceToNext(manual: true)}
OrientationHelper.unlockForPlayback()
}
.onDisappear {
remuxer?.cancel()
avModel.stop()
mpvModel.stop()
store.stopAccessing(for: currentItem)
store.refreshProgress()
OrientationHelper.lockToPortrait()
}
.onChange(of: nativeMode) { _, newValue in
// 在播放器更多设置或设置页切换模式：当前视频按新模式重新载入
guard engine != nil else { return}
notice = newValue
? String(localized: "已切换原生模式")
: String(localized: "已切换直读播放")
avModel.stop()
mpvModel.stop()
engine = nil
start()
}
.alert("播放提示", isPresented: $showWarnings) {
Button("继续播放") {}
} message: {
Text(warnings.joined(separator: "\n"))
}
}

/// 准备视图只在原生模式的重封装阶段出现（用户手动选择的模式）；默认直读不经过这里
private var preparingView: some View {
VStack(spacing: 14) {
LiuGuangGlyph()
Text(currentItem.name)
.font(.headline)
.foregroundStyle(.white)
.lineLimit(2)
.multilineTextAlignment(.center)
if let progress = remuxProgress {
Text("正在重封装 \(Int(progress * 100))%")
.font(.subheadline)
.foregroundStyle(.white.opacity(0.75))
ProgressView(value: progress)
.tint(.white)
.frame(width: 200)
Text("无损转换，不重新编码，速度取决于文件大小")
.font(.caption)
.foregroundStyle(.white.opacity(0.5))
} else {
ProgressView().tint(.white)
Text("正在准备…")
.font(.subheadline)
.foregroundStyle(.white.opacity(0.75))
}
}
.padding(28)
.glassEffect(.regular, in:.rect(cornerRadius: 24))
.padding(.horizontal, 32)
}

private func stillImage(for episode: MediaItem) -> UIImage? {
guard let scrape, let info = EpisodeParser.parse(episode.name) else { return nil}
return scrape.stillImage(for: info.show, season: info.season, episode: info.episode)
}

// MARK: 启动与切集

private func start() {
let target = currentItem
remuxer?.cancel()
nativeOptions = []
failure = nil
remuxProgress = nil
guard let url = store.resolveURL(for: target) else {
failure = String(localized: "无法读取这个文件（书签失效或链接不可用），请删除后重新导入。")
return
}
externalSubURL = store.externalSubtitleURL(for: target)
let nextExists = store.nextInSeries(after: target) != nil
avModel.outroAdvanceAvailable = nextExists
mpvModel.outroAdvanceAvailable = nextExists
if nativeMode {
startNative(url: url, item: target)
} else {
// 默认路线：直读直放，点开即播，不做任何预处理
engine = .mpv(url)
}
}

/// 原生模式：系统原生容器直接系统播放；其余先无损重封装再系统播放；
/// 重封装不可用时提示并改直读（不静默、不阻塞默认路线）
private func startNative(url: URL, item target: MediaItem) {
let ext = url.pathExtension.lowercased()
if target.urlString != nil || ["mp4", "mov", "m4v"].contains(ext) {
nativeOptions = externalOption(for: target).map { [$0] } ?? []
engine = .avPlayer(url)
return
}
AppLog.add("播放", "\(target.name)：原生模式，先无损重封装")
remuxProgress = 0
let activeRemuxer = FFmpegRemuxer()
remuxer = activeRemuxer
Task {
do {
let result = try await Task.detached(priority:.userInitiated) {
try activeRemuxer.remux(input: url) { value in
Task { @MainActor in remuxProgress = value}
}
}.value
guard currentItem.id == target.id else { return}
remuxProgress = nil
warnings = result.warnings
var options: [NativeSubtitleOption] = []
if let external = externalOption(for: target) { options.append(external)}
options += result.embeddedSubtitles.enumerated().map { idx, sub in
let track = MPVTrack(id: 0, type: "sub", lang: sub.lang, title: sub.title,
codec: "subrip", isExternal: false)
return NativeSubtitleOption(id: "emb-\(idx)",
label: track.displayName,
kindLabel: String(localized: "文本"),
score: track.subtitleDefaultScore,
cues: sub.cues)
}
nativeOptions = options
engine = .avPlayer(result.outputURL)
if !warnings.isEmpty { showWarnings = true}
} catch let error as FFmpegRemuxError {
guard currentItem.id == target.id else { return}
remuxProgress = nil
if error == .cancelled { return}
AppLog.add("播放", "\(target.name)：原生模式重封装不可用（\(error.errorDescription ?? "")），改直读播放")
notice = String(localized: "原生模式不可用，已切换直读播放")
engine = .mpv(url)
} catch {
guard currentItem.id == target.id else { return}
remuxProgress = nil
AppLog.add("播放", "\(target.name)：原生模式重封装异常（\(error.localizedDescription)），改直读播放")
notice = String(localized: "原生模式不可用，已切换直读播放")
engine = .mpv(url)
}
}
}

private func externalOption(for target: MediaItem) -> NativeSubtitleOption? {
guard let cues = store.loadExternalSubtitleCues(for: target) else { return nil}
var label = String(localized: "外挂字幕")
if let name = target.subtitleName { label += " · \(name)"}
return NativeSubtitleOption(id: "external", label: label,
kindLabel: String(localized: "文本"),
score: Int.max, cues: cues)
}

private func switchToEpisode(_ target: MediaItem) {
guard target.id != currentItem.id else { return}
avModel.stop()
mpvModel.stop()
currentItem = target
engine = nil
store.touchPlayed(target)
start()
}

/// 连播：自动触发（播完/片尾）受「自动连播下一集」设置约束；手动点跳过片尾则直接切
private func advanceToNext(manual: Bool) {
if !manual,
UserDefaults.standard.object(forKey: "settings.autoNext") as? Bool == false { return}
guard let next = store.nextInSeries(after: currentItem) else { return}
AppLog.add("播放", "连播下一集：\(next.name)")
switchToEpisode(next)
}

private func goPrevious() {
if let prev = store.previousInSeries(before: currentItem) { switchToEpisode(prev)}
}

private func goNextManual() {
if let next = store.nextInSeries(after: currentItem) { switchToEpisode(next)}
}

/// 加载本地外挂字幕：选择器选文件 → 挂到条目（持久化）→ 按当前引擎立即生效
private func loadLocalSubtitle() {
let target = currentItem
DocumentPickerBridge.presentPicker(contentTypes: [.item], allowsMultiple: false) { urls in
guard let picked = urls?.first else { return}
store.attachSubtitle(item: target, url: picked)
guard target.id == currentItem.id else { return}
externalSubURL = store.externalSubtitleURL(for: target)
switch engine {
case.mpv:
if let externalSubURL { mpvModel.addExternalSubtitleFile(externalSubURL)}
notice = String(localized: "字幕已加载")
case.avPlayer:
if let option = externalOption(for: target) {
nativeOptions.removeAll { $0.id == "external"}
nativeOptions.insert(option, at: 0)
subtitleOptionsToken += 1
notice = String(localized: "字幕已加载")
}
case nil:
break
}
}
}
}

// MARK: - 播放器界面（双引擎共用外壳）
//
//
// controlsVisible 是唯一的显隐状态：顶部栏（标题、关闭按钮、提示条、报错条）、
// 原生路的自绘按钮与 MPVControlsView 的全部控件都由它驱动，不存在第二套计时。
// 规则：播放中 3.5 秒无操作淡出全隐；任意交互（poke）唤出并重置计时；
// 拖动进度或打开面板时暂停计时（chromeSuspended）；暂停时保持显示；
// 报错/提示出现时强制唤出，提示 4 秒后自动消失、报错随控件一同隐去。

struct PlayerScreen: View {
let engine: PlaybackEngine
let title: String
var nativeSubtitleOptions: [NativeSubtitleOption] = []
var externalSubtitleURL: URL? = nil
var resumeKey: String = ""
var preferenceScope: String = ""
var notice: String? = nil
var subtitleOptionsToken: Int = 0
var episodes: [MediaItem] = []
var currentEpisodeID: UUID
var stillProvider: (MediaItem) -> UIImage? = { _ in nil}
/// 呈现控制器的方向上下文：判定到达时同步写一份，呈现层与请求层双保险
var orientationContext: PlaybackOrientationContext? = nil
@ObservedObject var avModel: PlayerModel
@ObservedObject var mpvModel: MPVPlayerModel
let onClose: () -> Void
let onSelectEpisode: (MediaItem) -> Void
let onPrevious: (() -> Void)?
let onNext: (() -> Void)?
let onLoadLocalSubtitle: () -> Void

@State private var controlsVisible = true
@State private var interactionSeed = 0
@State private var chromeSuspended = false
@State private var currentNotice: String?
@State private var selectedPrimaryOptionID: String?
@State private var selectedSecondaryOptionID: String?
@State private var showAVSubtitlePanel = false
@State private var showAVEpisodes = false
@AppStorage(PlayerSettings.showPrevNextKey) private var showPrevNextButtons = true

private var isMPV: Bool {
if case.mpv = engine { return true}
return false
}
private var activePaused: Bool { isMPV ? mpvModel.isPaused : avModel.isPaused}
private var activeError: String? { isMPV ? mpvModel.errorMessage : avModel.errorMessage}
private var anyPanelOpen: Bool { chromeSuspended || showAVSubtitlePanel || showAVEpisodes}

private struct HideKey: Equatable {
var visible: Bool
var seed: Int
var suspended: Bool
var paused: Bool
}

var body: some View {
ZStack {
engineLayer
if controlsVisible {
topChrome
.transition(.opacity)
}
if !isMPV, avModel.outroPromptVisible {
avOutroButton
}
}
.animation(.easeInOut(duration: 0.25), value: controlsVisible)
.task(id: HideKey(visible: controlsVisible, seed: interactionSeed,
suspended: anyPanelOpen, paused: activePaused)) {
guard controlsVisible,!activePaused,!anyPanelOpen else { return}
try? await Task.sleep(for:.seconds(3.5))
guard !Task.isCancelled else { return}
withAnimation(.easeInOut(duration: 0.3)) { controlsVisible = false}
}
.task(id: engine) {
switch engine {
case.avPlayer(let url):
avModel.load(url: url, title: title, resumeKey: resumeKey)
applySubtitleDefaults()
avModel.player.play()
case.mpv(let url):
mpvModel.load(url: url, title: title, resumeKey: resumeKey,
externalSubtitleURL: externalSubtitleURL,
preferenceScope: preferenceScope)
}
}
.task(id: notice) {
currentNotice = notice
guard notice != nil else { return}
controlsVisible = true
interactionSeed &+= 1
try? await Task.sleep(for:.seconds(4))
if !Task.isCancelled { currentNotice = nil}
}
.onChange(of: activeError) { _, newValue in
if newValue != nil {
controlsVisible = true
interactionSeed &+= 1
}
}
.onChange(of: activePaused) { _, paused in
if paused { controlsVisible = true}
}
.onChange(of: subtitleOptionsToken) { _, _ in applySubtitleDefaults()}
.onChange(of: selectedPrimaryOptionID) { _, _ in applyAVSubtitles()}
.onChange(of: selectedSecondaryOptionID) { _, _ in applyAVSubtitles()}
.onChange(of: avModel.videoIsLandscape, initial: true) { _, isLandscape in
// 电平触发（含初始值）：判定在页面出现之前就已置位时，边沿触发永远等不到变化——
// 1.2.1「点开 16:9 不自动横屏」的根因之一。写上下文给呈现控制器，再发 geometry 请求补位
guard !isMPV else { return}
orientationContext?.aspectLandscape = isLandscape
OrientationHelper.setPlaybackAspect(isLandscape)
}
.onChange(of: mpvModel.videoIsLandscape, initial: true) { _, isLandscape in
guard isMPV else { return}
orientationContext?.aspectLandscape = isLandscape
OrientationHelper.setPlaybackAspect(isLandscape)
}
.onAppear {
// 页面（重新）出现时按当前判定再校正一次方向
let current = isMPV ? mpvModel.videoIsLandscape : avModel.videoIsLandscape
orientationContext?.aspectLandscape = current
OrientationHelper.setPlaybackAspect(current)
}
.sheet(isPresented: $showAVSubtitlePanel) {
AVSubtitlePanelView(options: nativeSubtitleOptions,
primaryID: $selectedPrimaryOptionID,
secondaryID: $selectedSecondaryOptionID,
onLoadLocalSubtitle: onLoadLocalSubtitle)
}
.sheet(isPresented: $showAVEpisodes) {
EpisodePanelView(episodes: episodes, currentID: currentEpisodeID,
stillProvider: stillProvider) { picked in
showAVEpisodes = false
onSelectEpisode(picked)
}
}
}

/// 任意交互后调用：控件未显示则淡入，并重置自动隐藏计时
private func poke() {
if !controlsVisible {
withAnimation(.easeInOut(duration: 0.25)) { controlsVisible = true}
}
interactionSeed &+= 1
}

@ViewBuilder
private var engineLayer: some View {
switch engine {
case.avPlayer:
PlayerView(player: avModel.player,
subtitleText: avModel.currentSubtitleText,
secondarySubtitleText: avModel.currentSecondarySubtitleText)
.ignoresSafeArea()
.simultaneousGesture(TapGesture().onEnded { poke()})
case.mpv:
MPVPlayerView(model: mpvModel)
.ignoresSafeArea()
MPVControlsView(model: mpvModel,
chromeVisible: $controlsVisible,
chromeSuspended: $chromeSuspended,
poke: poke,
episodes: episodes,
currentEpisodeID: currentEpisodeID,
onSelectEpisode: onSelectEpisode,
onPrevious: onPrevious,
onNext: onNext,
onLoadLocalSubtitle: onLoadLocalSubtitle,
stillProvider: stillProvider)
}
}

// MARK: 顶部栏（标题＋关闭＋提示/报错）——与控件同显同隐

private var topChrome: some View {
VStack {
HStack(alignment:.top, spacing: 10) {
if isMPV {
// 直读路没有系统标题层，自绘标题（随控件显隐）；原生路标题由系统控件显示。
// 长标题尾部截断显示省略号，绝不顶出左边缘（1.2.1 小屏适配修复）
Text(title)
.font(.headline)
.foregroundStyle(.white)
.lineLimit(1)
.truncationMode(.tail)
.shadow(color:.black.opacity(0.55), radius: 4, y: 1)
.padding(.top, 7)
}
Spacer()
VStack(alignment:.trailing, spacing: 8) {
HStack(spacing: 8) {
if !isMPV {
if showPrevNextButtons, let onPrevious {
chromeButton("backward.end.fill", label: "上一集") { onPrevious()}
}
if showPrevNextButtons, let onNext {
chromeButton("forward.end.fill", label: "下一集") { onNext()}
}
if episodes.count > 1 {
chromeButton("list.bullet", label: "选集") { showAVEpisodes = true}
}
// 字幕键常驻（M5）：选项要等重封装扫完才到，先灰着也要有入口，
// 不再出现「播了半天找不到字幕按钮」
chromeButton("captions.bubble.fill", label: "字幕") { showAVSubtitlePanel = true}
}
// 关闭键：裸 glyph＋44pt 点击域，与新控件层统一（渐变由控件层提供，父级不叠玻璃圆）
Button {
onClose()
} label: {
Image(systemName: "xmark")
.font(.system(size: 15, weight:.semibold))
.foregroundStyle(.white)
.shadow(color:.black.opacity(0.55), radius: 4, y: 1)
.frame(width: 44, height: 44)
.contentShape(Rectangle())
}
.accessibilityLabel("关闭")
}
if let currentNotice {
chip(currentNotice)
}
if let activeError {
chip(activeError)
}
}
}
Spacer()
}
// 宽度钉死为父级给到的整屏宽、左右各留 16pt（与底部面板外边距同规格）：
// 不再依赖内容自适应宽度，避免任一子元素把整栏撑出屏幕后居中裁掉两头（1.2.1）
.frame(maxWidth:.infinity)
.padding(.horizontal, 16)
.padding(.top, 8)
}

private func chromeButton(_ systemImage: String, label: String,
action: @escaping () -> Void) -> some View {
Button {
action()
poke()
} label: {
Image(systemName: systemImage)
.font(.system(size: 14, weight:.semibold))
.foregroundStyle(.white)
.frame(width: 34, height: 34)
.glassEffect(.regular.interactive(), in: Circle())
}
.accessibilityLabel(label)
}

private func chip(_ text: String) -> some View {
Text(text)
.font(.footnote)
.foregroundStyle(.white)
.lineLimit(2)
.multilineTextAlignment(.trailing)
.padding(.horizontal, 12)
.padding(.vertical, 8)
.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style:.continuous))
// 提示/报错文本再长也只在本栏内换行，不许把顶栏撑宽（1.2.1）
.frame(maxWidth: 260, alignment:.trailing)
}

/// 原生路的「跳过片尾」（片尾窗口内出现，与直读路一致）
private var avOutroButton: some View {
VStack {
Spacer()
HStack {
Spacer()
Button {
avModel.skipOutro()
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
}
.padding(.bottom, 96)
.transition(.opacity)
}

// MARK: 原生路字幕选择

private func applySubtitleDefaults() {
let best = nativeSubtitleOptions.max { $0.score < $1.score}
selectedPrimaryOptionID = best?.id
selectedSecondaryOptionID = nil
applyAVSubtitles()
}

private func applyAVSubtitles() {
let primary = nativeSubtitleOptions.first { $0.id == selectedPrimaryOptionID }?.cues ?? []
let secondary = nativeSubtitleOptions.first { $0.id == selectedSecondaryOptionID }?.cues ?? []
avModel.setOverlaySubtitles(primary: primary, secondary: secondary)
}
}

// MARK: - 原生模式字幕面板（外挂＋内封文本字幕：主/副双选）

struct AVSubtitlePanelView: View {
let options: [NativeSubtitleOption]
@Binding var primaryID: String?
@Binding var secondaryID: String?
let onLoadLocalSubtitle: () -> Void
@Environment(\.dismiss) private var dismiss
@State private var tab: Tab = .primary

private enum Tab { case primary, secondary}

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
ForEach(options) { option in
Button {
select(option.id)
} label: {
HStack(spacing: 8) {
Text(option.label)
.foregroundStyle(.primary)
.lineLimit(2)
Spacer()
Text(option.kindLabel)
.font(.caption2.weight(.medium))
.foregroundStyle(.secondary)
.padding(.horizontal, 6)
.padding(.vertical, 2)
.background(.secondary.opacity(0.15), in: Capsule())
if option.id == selectedID {
Image(systemName: "checkmark").foregroundStyle(.tint)
}
}
}
.disabled(isConflicting(option))
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
Text("原生模式仅列出可叠加显示的文本字幕；图形字幕请用直读播放查看。")
}
}
.navigationTitle("字幕")
.navigationBarTitleDisplayMode(.inline)
.toolbar {
ToolbarItem(placement:.confirmationAction) {
Button("完成") { dismiss()}
}
}
}
.preferredColorScheme(.dark)
.presentationDetents([.medium,.large])
}

private var selectedID: String? {
tab == .primary ? primaryID : secondaryID
}

private func isConflicting(_ option: NativeSubtitleOption) -> Bool {
tab == .primary ? option.id == secondaryID : option.id == primaryID
}

private func select(_ id: String?) {
if tab == .primary {
primaryID = id
} else {
secondaryID = id
}
}
}
