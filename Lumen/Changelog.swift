import SwiftUI

/// 内置更新日志数据源（设置 → 关于 → 更新日志）。
/// 维护规矩：每次发版必须同步在 entries 最上方新增一条，否则不发版（工作流注释里同步立规）。
enum Changelog {
    struct Item {
        var category: String // 新增 / 优化 / 修复
        var text: String
    }

    struct Entry {
        var version: String
        var date: String
        var items: [Item]
    }

    static let entries: [Entry] = [
        Entry(version: "1.1", date: "2026-11-05", items: [
            Item(category: "新增", text: "双引擎播放：MKV 等格式先无损重封装后用系统播放器播放，原生输出高动态范围与空间音频；系统不支持的格式自动切换兼容播放，直接读取原文件"),
            Item(category: "新增", text: "兼容播放控制层：播放/暂停、进度拖动、音轨与字幕菜单、倍速菜单，双击两侧快退/快进 10 秒"),
            Item(category: "新增", text: "更新日志页（设置 → 关于 → 更新日志）"),
            Item(category: "优化", text: "界面全面打磨：媒体库、剧集详情、文件源与设置页排版统一，苹果风格材质与字阶"),
            Item(category: "优化", text: "适配 iPhone 12 及后续机型，5.4 英寸到 6.9 英寸全尺寸响应式布局"),
            Item(category: "优化", text: "播放启用硬件解码，降低发热与功耗；缩略图与图片缓存加上限管理"),
            Item(category: "优化", text: "图标改为白底黑线"),
            Item(category: "修复", text: "重封装在大型高动态范围文件上卡死、异常发热与闪退"),
            Item(category: "优化", text: "应用标识全新启用：本版以全新应用安装，旧版可删除，片源需重新导入一次"),
        ]),
        Entry(version: "1.0.2", date: "2026-11-04", items: [
            Item(category: "修复", text: "播放时报「书签解析失败」无法播放：改用文件夹书签＋相对路径定位，已有条目自动修复"),
        ]),
        Entry(version: "1.0.1", date: "2026-11-04", items: [
            Item(category: "修复", text: "适配 iOS 27：文件导入与「文件」App 中的 Lumen 文件夹恢复正常"),
        ]),
        Entry(version: "1.0", date: "2026-11-04", items: [
            Item(category: "优化", text: "改用苹果式版本号"),
            Item(category: "优化", text: "首次启动在本机目录生成说明文件，方便在「文件」App 里找到 Lumen 文件夹"),
        ]),
        Entry(version: "5.5", date: "2026-11-04", items: [
            Item(category: "新增", text: "本机目录导入：把视频拷进「文件」App 的 Lumen 文件夹即可自动入库，也支持从其他 App 通过「打开方式」送入"),
        ]),
        Entry(version: "5.4", date: "2026-11-04", items: [
            Item(category: "修复", text: "字幕轨缺少语言标记时，按轨道名称兜底识别中文/英文/日文字幕"),
        ]),
        Entry(version: "5.3", date: "2026-11-04", items: [
            Item(category: "新增", text: "重封装缓存：同一文件第二次播放免重封装"),
            Item(category: "优化", text: "文件选择改用系统 UIKit 选择器，侧载安装下更可靠"),
            Item(category: "优化", text: "播放默认选中内封中文字幕，并记住上次的播放速度"),
        ]),
        Entry(version: "早期版本", date: "2026-11-04 之前", items: [
            Item(category: "新增", text: "基础播放、媒体库、剧集信息刮削与界面改版"),
        ]),
    ]
}

/// 更新日志页：原生 List 按版本倒序渲染，版本号＋日期作标题，条目带分类前缀
struct ChangelogView: View {
    var body: some View {
        List {
            ForEach(Changelog.entries, id: \.version) { entry in
                Section {
                    ForEach(entry.items.indices, id: \.self) { index in
                        let item = entry.items[index]
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.category)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 30, alignment: .leading)
                            Text(item.text)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } header: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.version)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .textCase(nil)
                        Text(entry.date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("更新日志")
        .navigationBarTitleDisplayMode(.inline)
    }
}
