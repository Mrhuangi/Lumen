import AVFoundation
import Foundation
import UIKit

/// 一条媒体记录：本地文件（安全作用域书签）或网络地址（二选一）
struct MediaItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var bookmark: Data?      // 本地文件的 security-scoped bookmark
    var urlString: String?   // 网络直链
    var addedAt = Date()
    var subtitleBookmark: Data?  // 外挂字幕文件的 security-scoped bookmark（v3 新增，旧数据无此键也能解码）
    var subtitleName: String?    // 外挂字幕文件名
    var lastPlayedAt: Date?      // 最近播放时间（v4 新增，用于「继续观看」与排序）
    var fileExtension: String?   // 原始文件扩展名（小写，v4.1 新增：判断 MKV 不能只看片名，旧数据无此键为 nil）
    var sourceBookmark: Data?    // 文件源文件夹的 security-scoped 书签（v1.0.2 新增，与 relativePath 搭配定位文件）
    var relativePath: String?    // 文件相对路径（v1.0.2 新增）：有 sourceBookmark 时相对文件源根目录，无时相对 App 文档目录
}

/// 错误日志：记录导入、扫描、播放各环节的成败，设置页可查看与复制（排查问题用）
enum AppLog {
    private static let key = "app.log.v1"
    private static let maxEntries = 300

    static func add(_ tag: String, _ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        var lines = all()
        lines.append("\(formatter.string(from: Date())) [\(tag)] \(message)")
        if lines.count > maxEntries { lines.removeFirst(lines.count - maxEntries) }
        UserDefaults.standard.set(lines, forKey: key)
    }

    static func all() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// 一个文件源文件夹（安全作用域书签，原地读取不拷贝）
struct SourceFolder: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var bookmark: Data
}

/// 媒体库：增删、持久化（UserDefaults）、书签解析
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var progressMap: [UUID: Double] = [:]  // itemID -> 0...1 播放进度
    @Published private(set) var scanFolderName: String?
    @Published private(set) var sources: [SourceFolder] = []

    private let key = "library.items.v1"
    private let folderBookmarkKey = "scan.folderBookmark.v1"
    private let folderNameKey = "scan.folderName.v1"
    private let sourcesKey = "scan.folders.v2"
    /// 最近一次导入失败的用户可读原因（导入视图据此弹错；成功时为 nil）
    @Published private(set) var lastImportError: String?
    /// 安全作用域租约（S3）：同一作用域可被多方同时持有（播放、缩略图生成、外挂字幕），
    /// 按 URL 引用计数，最后一个释放者才真正 stop；旧实现只有单槽，
    /// 后台生成一张缩略图就会把正在播放文件的访问权掐断
    private var scopeAccessCounts: [URL: Int] = [:]
    /// 每个条目当前持有的租约（视频＋字幕），stopAccessing(for:) 按条目精确释放
    private var accessLeases: [UUID: [URL]] = [:]

    private func beginScopeAccess(_ url: URL, for item: MediaItem) {
        if (scopeAccessCounts[url] ?? 0) == 0 {
            guard url.startAccessingSecurityScopedResource() else { return }
        }
        scopeAccessCounts[url, default: 0] += 1
        accessLeases[item.id, default: []].append(url)
    }

    private func endScopeAccess(_ url: URL) {
        guard let count = scopeAccessCounts[url] else { return }
        if count <= 1 {
            scopeAccessCounts[url] = nil
            url.stopAccessingSecurityScopedResource()
        } else {
            scopeAccessCounts[url] = count - 1
        }
    }

    static let videoExtensions: Set<String> = ["mkv", "mp4", "mov", "m4v", "ts", "m2ts",
                                               "avi", "webm", "wmv", "flv", "mpg", "mpeg", "3gp"]

    init() {
        load()
        refreshProgress()
        loadSources()
        ensureLocalFolderPlaceholder()
    }

    /// 首次启动时在本机目录放一个说明文件，确保「文件」App 里能看到 Lumen 文件夹
    private func ensureLocalFolderPlaceholder() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let marker = docs.appendingPathComponent(String(localized: "把视频放进这个文件夹.txt"))
        if !FileManager.default.fileExists(atPath: marker.path) {
            try? String(localized: "把电影、剧集的视频文件或整个文件夹拷进这里，回到 Lumen 就会自动出现在媒体库中。").write(to: marker, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 续播进度

    func refreshProgress() {
        var map: [UUID: Double] = [:]
        for item in items {
            if let p = ResumeStore.progress(forKey: item.id.uuidString) { map[item.id] = p }
        }
        progressMap = map
    }

    func touchPlayed(_ item: MediaItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].lastPlayedAt = Date()
        save()
    }

    /// 有进度且没看完的条目，按最近播放排序（继续观看）
    var continueWatching: [MediaItem] {
        items.filter { item in
            guard let p = progressMap[item.id] else { return false }
            return p > 0.02 && p < 0.95
        }
        .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
    }

    // MARK: - 增删

    @discardableResult
    func addFile(url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var bookmark = try? url.bookmarkData(options: [],
                                             includingResourceValuesForKeys: nil,
                                             relativeTo: nil)
        var finalURL = url
        var copiedRelativePath: String? = nil
        if bookmark == nil {
            // 大文件绝不走全量拷贝兜底（几个 GB 同步复制会长时间假死）：跳过并提示改用添加文件夹
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if size > 200_000_000 {
                AppLog.add("导入", "\(url.lastPathComponent)：约 \(size / 1_000_000)MB 且书签创建失败，已跳过；大文件请用「添加文件夹」加入它所在的文件夹")
                lastImportError = String(localized: "这个文件太大，请用「添加文件夹」加入它所在的文件夹")
                return lastImportError
            }
            AppLog.add("导入", "\(url.lastPathComponent)：书签创建失败，尝试拷贝进 App 文档目录")
            if let copied = copyIntoDocuments(url) {
                finalURL = copied
                bookmark = nil
                copiedRelativePath = copied.lastPathComponent
            } else {
                lastImportError = String(localized: "文件加入失败，请重试")
                return lastImportError
            }
        }
        var item = MediaItem(name: finalURL.deletingPathExtension().lastPathComponent,
                             bookmark: bookmark,
                             urlString: nil)
        item.relativePath = copiedRelativePath
        item.fileExtension = finalURL.pathExtension.lowercased()
        items.insert(item, at: 0)
        save()
        AppLog.add("导入", "已加入媒体库：\(item.name)（书签\(bookmark == nil ? "无" : "有")）")
        return nil
    }

    /// 书签建不起来时的兜底：把文件拷进 App 自己的 Documents 目录。
    /// 同名已存在时先比对大小：一致才当同一文件复用，不一致是另一部同名片，走序号命名（L5），
    /// 绝不把 B 片静默指向 A 片的文件
    private func copyIntoDocuments(_ url: URL) -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var dest = docs.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            let existingSize = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            let incomingSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            if let existingSize, existingSize == incomingSize { return dest }
            var counter = 1
            repeat {
                dest = docs.appendingPathComponent(
                    "\(url.deletingPathExtension().lastPathComponent) \(counter).\(url.pathExtension)")
                counter += 1
            } while FileManager.default.fileExists(atPath: dest.path)
        }
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            AppLog.add("导入", "\(url.lastPathComponent)：已拷贝到 App 文档目录")
            return dest
        } catch {
            AppLog.add("导入", "\(url.lastPathComponent)：拷贝失败 \(error.localizedDescription)")
            return nil
        }
    }

    func addURL(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else { return }
        let name = url.deletingPathExtension().lastPathComponent.isEmpty
            ? (url.host ?? trimmed)
            : url.deletingPathExtension().lastPathComponent
        var item = MediaItem(name: name, bookmark: nil, urlString: trimmed)
        item.fileExtension = url.pathExtension.lowercased()
        items.insert(item, at: 0)
        save()
    }

    func remove(at offsets: IndexSet) {
        let removed = offsets.map { items[$0] }
        items.remove(atOffsets: offsets)
        for item in removed { cleanupAfterRemove(item) }
        save()
    }

    func remove(_ item: MediaItem) {
        items.removeAll { $0.id == item.id }
        cleanupAfterRemove(item)
        save()
    }

    /// 删条目时顺带清它的续播点与缩略图缓存，不留孤儿数据（L3）
    private func cleanupAfterRemove(_ item: MediaItem) {
        ResumeStore.remove(key: item.id.uuidString)
        ThumbnailStore.deleteCached(for: item)
    }

    // MARK: - 扫描文件夹

    /// 添加一个文件源文件夹（保存书签，原地读取不拷贝）并立即扫描一遍
    @discardableResult
    func addSource(url: URL) -> (added: Int, found: Int) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? url.bookmarkData(options: [],
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil) else {
            AppLog.add("扫描", "添加文件夹失败：\(url.lastPathComponent) 书签创建失败")
            lastImportError = String(localized: "文件夹加入失败，请重试")
            return (0, 0)
        }
        if let existing = sources.firstIndex(where: { $0.name == url.lastPathComponent }) {
            sources[existing].bookmark = data   // 重新添加同名文件夹：刷新书签，顺带修复失效的旧书签
        } else {
            sources.append(SourceFolder(name: url.lastPathComponent, bookmark: data))
        }
        persistSources()
        syncFolderName()
        let result = scanFolderContents(url, folderBookmark: data)
        AppLog.add("扫描", "文件源 \(url.lastPathComponent)：找到 \(result.found) 个视频，新加入 \(result.added) 个")
        return result
    }

    /// 兼容旧入口（设置页等仍在调用）
    @discardableResult
    func setScanFolder(url: URL) -> (added: Int, found: Int) { addSource(url: url) }

    /// 重新扫描全部文件源（App 启动时自动调用）
    @discardableResult
    func rescanAllSources() -> (added: Int, found: Int) {
        var total = (added: 0, found: 0)
        for source in sources {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: source.bookmark, options: [],
                                     relativeTo: nil, bookmarkDataIsStale: &stale) else {
                AppLog.add("扫描", "文件源 \(source.name) 的书签已失效，请在文件源页重新添加该文件夹")
                continue
            }
            let scoped = url.startAccessingSecurityScopedResource()
            let r = scanFolderContents(url, folderBookmark: source.bookmark)
            if scoped { url.stopAccessingSecurityScopedResource() }
            total.added += r.added
            total.found += r.found
        }
        if total.added > 0 {
            AppLog.add("扫描", "自动扫描文件源：新加入 \(total.added) 个")
        }
        return total
    }

    /// 兼容旧入口；没有任何文件源时返回 nil
    @discardableResult
    func rescanSavedFolder() -> (added: Int, found: Int)? {
        sources.isEmpty ? nil : rescanAllSources()
    }

    func removeSource(_ source: SourceFolder) {
        sources.removeAll { $0.id == source.id }
        persistSources()
        syncFolderName()
    }

    func clearScanFolder() {
        sources = []
        persistSources()
        syncFolderName()
        UserDefaults.standard.removeObject(forKey: folderBookmarkKey)
        UserDefaults.standard.removeObject(forKey: folderNameKey)
    }

    private func persistSources() {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: sourcesKey)
        }
    }

    private func syncFolderName() {
        scanFolderName = sources.first?.name
        if let name = scanFolderName {
            UserDefaults.standard.set(name, forKey: folderNameKey)
        }
    }

    private func loadSources() {
        if let data = UserDefaults.standard.data(forKey: sourcesKey),
           let decoded = try? JSONDecoder().decode([SourceFolder].self, from: data) {
            sources = decoded
        }
        // 迁移旧版的单个扫描文件夹
        if sources.isEmpty, let old = UserDefaults.standard.data(forKey: folderBookmarkKey) {
            var stale = false
            let name = (try? URL(resolvingBookmarkData: old, options: [],
                                 relativeTo: nil, bookmarkDataIsStale: &stale))?.lastPathComponent
                ?? UserDefaults.standard.string(forKey: folderNameKey) ?? String(localized: "文件夹")
            sources = [SourceFolder(name: name, bookmark: old)]
            persistSources()
        }
        scanFolderName = sources.first?.name
    }

    /// 扫描 App 自身的 Documents 目录（通过「文件」App 拷进 Lumen 的视频会出现在这里）
    @discardableResult
    func scanOwnDocuments() -> Int {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return scanFolderContents(docs, folderBookmark: nil).added
    }

    /// 处理从其他 App 分享/「打开方式」送进来的视频文件：拷入本机目录后自动入库
    func handleIncomingFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if url.standardizedFileURL.path.hasPrefix(docs.standardizedFileURL.path) {
            _ = scanOwnDocuments()
            return
        }
        var target = docs.appendingPathComponent(url.lastPathComponent)
        var counter = 1
        while FileManager.default.fileExists(atPath: target.path) {
            let base = url.deletingPathExtension().lastPathComponent
            target = docs.appendingPathComponent("\(base) \(counter).\(url.pathExtension)")
            counter += 1
        }
        do {
            try FileManager.default.copyItem(at: url, to: target)
            AppLog.add("导入", "外部打开的视频已存入本机目录：\(target.lastPathComponent)")
        } catch {
            AppLog.add("导入", "外部打开的视频保存失败：\(error.localizedDescription)")
        }
        _ = scanOwnDocuments()
    }

    /// 递归扫描文件夹，把新视频加入媒体库（按文件路径去重，已在库的不重复添加）
    /// v1.0.2：条目改存「文件夹书签＋相对路径」定位（逐文件 minimalBookmark 在 iOS 27 上解析失败）；
    /// 扫描命中老条目时顺带修复其定位，旧版导入的坏条目重新扫描后自愈。
    private func scanFolderContents(_ folder: URL, folderBookmark: Data?) -> (added: Int, found: Int) {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return (0, 0) }
        // 相对路径的基准：文件源以其根目录为准，本机目录一律以文档目录为准
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let basePath = (folderBookmark == nil ? docs : folder).path
        var found = 0
        var newItems: [MediaItem] = []
        var repaired = 0
        // 去重键（S5）：文件的绝对路径，由条目现有定位各自还原（文件源根＋相对路径 /
        // 本机相对路径 / 旧版逐文件书签）。旧键是「片名＋扩展名」，同名不同目录的两集会互相顶掉；
        // 片名从此只作展示与剧集分组
        var indexByPath: [String: Int] = [:]
        var rootCache: [Data: URL] = [:]
        for (i, item) in items.enumerated() {
            if let rel = item.relativePath {
                if let data = item.sourceBookmark {
                    let root: URL?
                    if let cached = rootCache[data] {
                        root = cached
                    } else {
                        var rootStale = false
                        root = try? URL(resolvingBookmarkData: data, options: [],
                                        relativeTo: nil, bookmarkDataIsStale: &rootStale)
                        if let root { rootCache[data] = root }
                    }
                    if let root {
                        indexByPath[root.appendingPathComponent(rel).standardizedFileURL.path] = i
                    }
                } else {
                    indexByPath[docs.appendingPathComponent(rel).standardizedFileURL.path] = i
                }
            } else if let data = item.bookmark {
                var itemStale = false
                if let resolved = try? URL(resolvingBookmarkData: data, options: [],
                                           relativeTo: nil, bookmarkDataIsStale: &itemStale) {
                    indexByPath[resolved.standardizedFileURL.path] = i
                }
            }
        }
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard Self.videoExtensions.contains(ext) else { continue }
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            found += 1
            let name = fileURL.deletingPathExtension().lastPathComponent
            let rel = fileURL.path.hasPrefix(basePath + "/")
                ? String(fileURL.path.dropFirst(basePath.count + 1))
                : fileURL.lastPathComponent
            if let idx = indexByPath[fileURL.standardizedFileURL.path] {
                // 已在库：修复/刷新定位（id 不变，续播与刮削关联都保留）
                if items[idx].sourceBookmark != folderBookmark || items[idx].relativePath != rel {
                    items[idx].sourceBookmark = folderBookmark
                    items[idx].relativePath = rel
                    repaired += 1
                }
                continue
            }
            var item = MediaItem(name: name, bookmark: nil, urlString: nil)
            item.sourceBookmark = folderBookmark
            item.relativePath = rel
            item.fileExtension = ext
            newItems.append(item)
        }
        if !newItems.isEmpty {
            items.insert(contentsOf: newItems, at: 0)
        }
        if !newItems.isEmpty || repaired > 0 {
            save()
        }
        if repaired > 0 {
            AppLog.add("扫描", "已修复 \(repaired) 个条目的文件定位")
        }
        return (newItems.count, found)
    }

    /// 同一部剧的下一集（按文件名识别剧集；没有下一集返回 nil）
    func nextInSeries(after item: MediaItem) -> MediaItem? {
        let episodes = episodesInSeries(of: item)
        guard let index = episodes.firstIndex(where: { $0.id == item.id }),
              index + 1 < episodes.count else { return nil }
        return episodes[index + 1]
    }

    func previousInSeries(before item: MediaItem) -> MediaItem? {
        let episodes = episodesInSeries(of: item)
        guard let index = episodes.firstIndex(where: { $0.id == item.id }),
              index > 0 else { return nil }
        return episodes[index - 1]
    }

    /// 同剧全部分集（按季/集排序）；不是剧集条目时只返回它自己
    func episodesInSeries(of item: MediaItem) -> [MediaItem] {
        guard let info = EpisodeParser.parse(item.name) else { return [item] }
        let episodes = items
            .filter { EpisodeParser.parse($0.name)?.show == info.show }
            .sorted(by: EpisodeParser.episodeSort)
        return episodes.isEmpty ? [item] : episodes
    }

    // MARK: - 解析可播放地址

    /// 返回可播放 URL；本地文件会开启安全作用域访问（按条目记租约），
    /// 播放结束后调用 stopAccessing(for:) 释放。重复解析同一条目只叠加租约、不再先掐旧的（S3）
    func resolveURL(for item: MediaItem) -> URL? {
        if let s = item.urlString { return URL(string: s) }
        // v1.0.2：相对路径定位——文件源文件走「文件夹书签＋相对路径」，本机目录文件直接拼文档目录
        if let rel = item.relativePath {
            if let folderData = item.sourceBookmark {
                var folderStale = false
                guard let folderURL = try? URL(resolvingBookmarkData: folderData,
                                               options: [], relativeTo: nil,
                                               bookmarkDataIsStale: &folderStale) else {
                    AppLog.add("播放", "\(item.name)：文件源书签解析失败")
                    return nil
                }
                beginScopeAccess(folderURL, for: item)
                return folderURL.appendingPathComponent(rel)
            }
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            return docs.appendingPathComponent(rel)
        }
        guard let data = item.bookmark else {
            AppLog.add("播放", "\(item.name)：条目没有书签，无法解析文件")
            return nil
        }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: [],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else {
            AppLog.add("播放", "\(item.name)：书签解析失败")
            return nil
        }
        beginScopeAccess(url, for: item)
        return url
    }

    /// 释放某个条目的全部租约（视频＋字幕）；其他持有者（如缩略图生成）不受影响
    func stopAccessing(for item: MediaItem) {
        guard let leases = accessLeases.removeValue(forKey: item.id) else { return }
        for url in leases { endScopeAccess(url) }
    }

    /// 释放全部租约（兜底清理）
    func stopAccessing() {
        let all = accessLeases
        accessLeases = [:]
        for (_, leases) in all {
            for url in leases { endScopeAccess(url) }
        }
    }

    // MARK: - 外挂字幕

    func attachSubtitle(item: MediaItem, url: URL) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        items[index].subtitleBookmark = try? url.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        items[index].subtitleName = url.lastPathComponent
        save()
    }

    func detachSubtitle(item: MediaItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].subtitleBookmark = nil
        items[index].subtitleName = nil
        save()
    }

    /// 解析外挂字幕文件为条目（SRT / ASS / SSA / VTT）；没有挂载或读失败返回 nil
    func loadExternalSubtitleCues(for item: MediaItem) -> [SubtitleCue]? {
        guard let data = item.subtitleBookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        beginScopeAccess(url, for: item)
        guard let fileData = try? Data(contentsOf: url) else { return nil }
        let cues = SubtitleParser.parse(data: fileData, fileExtension: url.pathExtension)
        return cues.isEmpty ? nil : cues
    }

    /// 解析外挂字幕文件的可读 URL（供直读播放以 sub-add 直接加载，字幕由引擎渲染）；
    /// 没有挂载或书签失效返回 nil。访问权按条目租约保持（与视频同一生命周期）。
    func externalSubtitleURL(for item: MediaItem) -> URL? {
        guard let data = item.subtitleBookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        beginScopeAccess(url, for: item)
        return url
    }

    // MARK: - 持久化

    /// 条目落盘改文件存储（M12）：整表 JSON 塞 UserDefaults 每次变更全量重写，
    /// 条目多了之后主线程卡顿；文件写用原子替换。旧 UserDefaults 数据首次启动自动迁入
    private var itemsFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LumenData", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library-items.json")
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: itemsFileURL, options: [.atomic])
    }

    private func load() {
        if let data = try? Data(contentsOf: itemsFileURL),
           let decoded = try? JSONDecoder().decode([MediaItem].self, from: data) {
            items = decoded
            return
        }
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([MediaItem].self, from: data) else { return }
        items = decoded
        if let fileData = try? JSONEncoder().encode(decoded) {
            try? fileData.write(to: itemsFileURL, options: [.atomic])
        }
    }
}

// MARK: - 缩略图（真实视频帧；MKV 用 FFmpeg 重封装后的缓存 MP4 抽帧，未重封装过的仍用占位图）

enum ThumbnailStore {
    private static var directory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cached(for item: MediaItem) -> UIImage? {
        let url = directory.appendingPathComponent(item.id.uuidString + ".jpg")
        return UIImage(contentsOfFile: url.path)
    }

    /// 删除条目时清掉它的缩略图缓存（L3）
    static func deleteCached(for item: MediaItem) {
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent(item.id.uuidString + ".jpg"))
    }

    /// 生成缩略图并落盘缓存；只处理本地文件（直链跳过）
    @MainActor
    static func generate(for item: MediaItem, store: LibraryStore) async -> UIImage? {
        if let image = cached(for: item) { return image }
        guard item.urlString == nil else { return nil }

        var source: URL?
        var needsScopeStop = false
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let remuxed = caches.appendingPathComponent(item.name + ".mp4")
        if FileManager.default.fileExists(atPath: remuxed.path) {
            source = remuxed // MKV 已重封装过：用缓存 MP4 抽帧（在 App 沙盒里，无需书签）
        } else if let ext = item.fileExtension, ["mp4", "mov", "m4v"].contains(ext) {
            source = store.resolveURL(for: item)
            needsScopeStop = source != nil
        }
        guard let src = source else { return nil }

        let image = await Task.detached(priority: .utility) { () -> UIImage? in
            let asset = AVURLAsset(url: src)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 400, height: 600)
            let time = CMTime(seconds: 30, preferredTimescale: 600)
            guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
            return UIImage(cgImage: cg)
        }.value

        // 只释放本条目的租约，不碰其他条目/正在播放的访问权（S3）
        if needsScopeStop { store.stopAccessing(for: item) }
        if let image, let data = image.jpegData(compressionQuality: 0.75) {
            try? data.write(to: directory.appendingPathComponent(item.id.uuidString + ".jpg"))
        }
        return image
    }
}

// MARK: - 续播存储（按条目 ID 记录位置与总时长，供继续观看与自动续播）

enum ResumeStore {
    private static let key = "resume.store.v2"

    private static func all() -> [String: [Double]] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:]
    }

    static func save(key itemKey: String, seconds: Double, duration: Double) {
        guard seconds > 3, duration > 0, seconds.isFinite, duration.isFinite else { return }
        var dict = all()
        dict[itemKey] = [seconds, duration]
        UserDefaults.standard.set(dict, forKey: key)
    }

    static func position(forKey itemKey: String) -> Double? {
        guard let pair = all()[itemKey], pair.count == 2 else { return nil }
        return pair[0]
    }

    static func progress(forKey itemKey: String) -> Double? {
        guard let pair = all()[itemKey], pair.count == 2, pair[1] > 0 else { return nil }
        return min(1, max(0, pair[0] / pair[1]))
    }

    /// 删除单条续播记录（播完自动清、删条目时清）
    static func remove(key itemKey: String) {
        var dict = all()
        guard dict[itemKey] != nil else { return }
        dict[itemKey] = nil
        UserDefaults.standard.set(dict, forKey: key)
    }

    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - 剧集元数据刮削（TVmaze：海报 / 简介 / 演职员 / 分集信息，图片缓存到本地）

struct EpisodeMeta: Codable {
    var title: String
    var summary: String?
    var runtime: Int?
    var stillFile: String?
}

struct CastMember: Codable {
    var name: String
    var character: String?
    var imageFile: String?
}

struct ShowMeta: Codable {
    var tvmazeID: Int
    var title: String
    var year: String?
    var rating: Double?
    var summary: String?
    var genres: [String]
    var posterFile: String?
    var cast: [CastMember]
    var episodes: [String: EpisodeMeta]
}

@MainActor
final class ScrapeStore: ObservableObject {
    @Published private(set) var shows: [String: ShowMeta] = [:]
    private var inFlight: Set<String> = []
    private let storageKey = "scrape.shows.v1"
    /// 刮削失败的负缓存（剧名小写 → 失败时间戳）：未命中不再每次启动全量重搜（M8）
    private var failureDates: [String: Double] = [:]
    private let failuresKey = "scrape.failures.v1"
    /// 负缓存有效期：7 天
    private static let failureTTL: Double = 7 * 24 * 3600

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: ShowMeta].self, from: data) {
            shows = decoded
        }
        failureDates = UserDefaults.standard.dictionary(forKey: failuresKey) as? [String: Double] ?? [:]
    }

    private func recordFailure(_ key: String) {
        failureDates[key] = Date().timeIntervalSince1970
        UserDefaults.standard.set(failureDates, forKey: failuresKey)
    }

    private func failureIsFresh(_ key: String) -> Bool {
        guard let stamp = failureDates[key] else { return false }
        return Date().timeIntervalSince1970 - stamp < Self.failureTTL
    }

    func meta(for show: String) -> ShowMeta? { shows[show.lowercased()] }

    static func episodeKey(season: Int, episode: Int) -> String {
        String(format: "S%02dE%02d", season, episode)
    }

    private static var scrapeDir: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("scrape", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func image(named file: String?) -> UIImage? {
        guard let file else { return nil }
        return UIImage(contentsOfFile: scrapeDir.appendingPathComponent(file).path)
    }

    func posterImage(for show: String) -> UIImage? {
        Self.image(named: meta(for: show)?.posterFile)
    }

    func stillImage(for show: String, season: Int, episode: Int) -> UIImage? {
        Self.image(named: meta(for: show)?.episodes[Self.episodeKey(season: season, episode: episode)]?.stillFile)
    }

    /// 扫描媒体库的剧集分组，对没刮削过的剧自动去 TVmaze 匹配（同剧只抓一次）
    func ensureAll(items: [MediaItem]) {
        var groups: [String: [EpisodeParser.Info]] = [:]
        for item in items {
            if let info = EpisodeParser.parse(item.name) {
                groups[info.show, default: []].append(info)
            }
        }
        for (show, infos) in groups where infos.count >= 2 {
            let key = show.lowercased()
            let wanted = Set(infos.map { Self.episodeKey(season: $0.season, episode: $0.episode) })
            if let existing = shows[key] {
                // 数据在但海报文件被系统清掉（图片在 Caches）：允许重抓一次补图（B6）
                if let poster = existing.posterFile,
                   !FileManager.default.fileExists(atPath: Self.scrapeDir.appendingPathComponent(poster).path),
                   !inFlight.contains(key) {
                    inFlight.insert(key)
                    Task { await self.scrape(show: show, key: key, wantedEpisodes: wanted) }
                }
                continue
            }
            guard !inFlight.contains(key), !failureIsFresh(key) else { continue }
            inFlight.insert(key)
            Task { await self.scrape(show: show, key: key, wantedEpisodes: wanted) }
        }
    }

    private func scrape(show: String, key: String, wantedEpisodes: Set<String>) async {
        defer { inFlight.remove(key) }
        // 命中校验（M8）：候选先过分数门槛，再验标题是否对得上（归一化后相等/互含，
        // 或分数极高才放行），不再无条件取 hits.first 把同分更高的另一部剧刮进来；
        // 没有可信匹配就写负缓存，7 天内不重复全量搜索
        guard let encoded = show.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://api.tvmaze.com/search/shows?q=\(encoded)"),
              let (searchData, _) = try? await URLSession.shared.data(from: searchURL),
              let hits = try? JSONDecoder().decode([TVSearchHit].self, from: searchData),
              let hit = hits.filter({ $0.score >= 0.5 })
                  .first(where: { Self.isPlausible($0, for: show) }) else {
            recordFailure(key)
            AppLog.add("刮削", "\(show)：TVmaze 没有可信匹配，已记入负缓存")
            return
        }
        let s = hit.show
        async let episodesFetched = fetchData("https://api.tvmaze.com/shows/\(s.id)/episodes")
        async let castFetched = fetchData("https://api.tvmaze.com/shows/\(s.id)/cast")
        let episodesData = await episodesFetched
        let castData = await castFetched
        let tvEpisodes: [TVEpisode] = episodesData.flatMap { try? JSONDecoder().decode([TVEpisode].self, from: $0) } ?? []
        let tvCast: [TVCastEntry] = castData.flatMap { try? JSONDecoder().decode([TVCastEntry].self, from: $0) } ?? []

        var meta = ShowMeta(tvmazeID: s.id, title: s.name,
                            year: s.premiered.map { String($0.prefix(4)) },
                            rating: s.rating?.average,
                            summary: Self.stripHTML(s.summary),
                            genres: s.genres ?? [],
                            posterFile: nil, cast: [], episodes: [:])
        if let posterURL = s.image?.original ?? s.image?.medium {
            meta.posterFile = await Self.downloadImage(posterURL, name: "\(s.id)-poster.jpg")
        }
        for ep in tvEpisodes {
            guard let number = ep.number else { continue }
            let ekey = Self.episodeKey(season: ep.season, episode: number)
            var em = EpisodeMeta(title: ep.name, summary: Self.stripHTML(ep.summary),
                                 runtime: ep.runtime, stillFile: nil)
            if wantedEpisodes.contains(ekey), let still = ep.image?.medium {
                em.stillFile = await Self.downloadImage(still, name: "\(s.id)-\(ekey).jpg")
            }
            meta.episodes[ekey] = em
        }
        for entry in tvCast.prefix(12) {
            var member = CastMember(name: entry.person.name,
                                    character: entry.character?.name, imageFile: nil)
            if let img = entry.person.image?.medium {
                member.imageFile = await Self.downloadImage(img, name: "\(s.id)-cast-\(meta.cast.count).jpg")
            }
            meta.cast.append(member)
        }
        shows[key] = meta
        if failureDates[key] != nil {
            failureDates[key] = nil
            UserDefaults.standard.set(failureDates, forKey: failuresKey)
        }
        if let data = try? JSONEncoder().encode(shows) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        AppLog.add("刮削", "\(show)：已匹配《\(s.name)》，\(meta.episodes.count) 集信息、\(meta.cast.count) 位演职员")
    }

    private func fetchData(_ string: String) async -> Data? {
        guard let url = URL(string: string) else { return nil }
        return try? await URLSession.shared.data(from: url).0
    }

    private static func downloadImage(_ string: String, name: String) async -> String? {
        guard let url = URL(string: string),
              let (data, _) = try? await URLSession.shared.data(from: url),
              UIImage(data: data) != nil else { return nil }
        do {
            try data.write(to: scrapeDir.appendingPathComponent(name))
            return name
        } catch { return nil }
    }

    /// 候选可信度校验：标题归一化（去大小写/标点/空格）后相等或互含才算对上；
    /// 实在对不上时只认分数 ≥ 0.9 的强命中
    private static func isPlausible(_ hit: TVSearchHit, for show: String) -> Bool {
        func normalized(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let wanted = normalized(show)
        let got = normalized(hit.show.name)
        if !wanted.isEmpty, !got.isEmpty,
           wanted == got || wanted.contains(got) || got.contains(wanted) {
            return true
        }
        return hit.score >= 0.9
    }

    static func stripHTML(_ html: String?) -> String? {
        guard let html else { return nil }
        var text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - TVmaze 接口结构

private struct TVSearchHit: Decodable { let score: Double; let show: TVShow }
private struct TVShow: Decodable {
    let id: Int
    let name: String
    let premiered: String?
    let rating: TVRating?
    let summary: String?
    let genres: [String]?
    let image: TVImage?
}
private struct TVRating: Decodable { let average: Double? }
private struct TVImage: Decodable { let medium: String?; let original: String? }
private struct TVEpisode: Decodable {
    let name: String
    let season: Int
    let number: Int?
    let runtime: Int?
    let summary: String?
    let image: TVImage?
}
private struct TVCastEntry: Decodable { let person: TVPerson; let character: TVCharacter? }
private struct TVPerson: Decodable { let name: String; let image: TVImage? }
private struct TVCharacter: Decodable { let name: String }
