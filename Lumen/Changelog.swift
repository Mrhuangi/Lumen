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
        Entry(version: "1.4", date: "2026-11-06", items: [
            Item(category: "修复", text: "横屏播放时画面被挤成窄条：播放页呈现方式已修正，横竖屏排版与视频画面完整贴合"),
            Item(category: "修复", text: "横屏下字幕、音轨、选集面板撑满全屏：现只占下半屏，不再遮住整个画面"),
            Item(category: "优化", text: "媒体库继续观看改用单集剧照卡：带播放键、已看时间与总时长，标题显示剧名与第几季第几集"),
            Item(category: "优化", text: "最近添加与剧集改用海报卡：显示官方海报与评分角标，副标题显示季数或年份"),
            Item(category: "新增", text: "每个分区新增「全部」入口，可查看该分区全部内容"),
            Item(category: "修复", text: "媒体库底部内容被悬浮栏遮挡、继续观看左侧文字被裁切，现已修复"),
        ]),
        Entry(version: "1.3", date: "2026-11-06", items: [
            Item(category: "修复", text: "内封中文字幕显示为方框：已内置完整中文字体，简体、繁体中文字幕正常显示"),
            Item(category: "修复", text: "点开宽屏视频不自动横屏：现进入播放即按视频宽高定向，竖屏视频保持竖屏"),
            Item(category: "修复", text: "音轨信息不完整：现标注编码、声道与全景声（如 E-AC3 · 5.1 · Atmos）"),
            Item(category: "优化", text: "播放标题改为剧名与分集名，不再显示原始文件名"),
            Item(category: "优化", text: "字幕菜单区分简体中文与繁体中文，并标注字幕格式（ASS / SRT / PGS 等）"),
            Item(category: "修复", text: "看到结尾的视频再次打开会停在片尾：播完的剧集下次从头播放，未看完的照常续播"),
            Item(category: "优化", text: "选择记忆更可靠：音轨、主副字幕组合、字号与倍速按剧集自动沿用"),
            Item(category: "优化", text: "解码与渲染管线调优，长时间播放发热降低"),
            Item(category: "修复", text: "导入文件或文件夹失败时没有任何提示：现会说明失败原因"),
        ]),
        Entry(version: "1.2.1", date: "2026-11-05", items: [
            Item(category: "修复", text: "续播过的视频再次打开时黑屏、进度归零，现已修复：重播会从上次看到的位置继续"),
            Item(category: "修复", text: "小屏机型上播放界面两侧按钮被屏幕边缘裁切，现已修复：标题、关闭按钮与底部按钮完整显示"),
            Item(category: "修复", text: "视频无法打开时没有任何提示，现会明确显示「无法播放这个文件」"),
        ]),
        Entry(version: "1.2", date: "2026-11-05", items: [
            Item(category: "新增", text: "打开即播：点开视频直接播放，不再先等待重封装；重封装保留为「原生模式」，可在播放器更多设置里手动开启"),
            Item(category: "修复", text: "播放控件（包括关闭按钮）常驻不隐藏：现已统一显隐，播放中 3.5 秒无操作自动隐藏，点按画面唤出，暂停时保持显示"),
            Item(category: "新增", text: "双字幕：内封字幕全列表可选，主字幕与副字幕可同时显示；默认优先简体中文，选择按剧集与全局记忆"),
            Item(category: "新增", text: "加载本地字幕（SRT / ASS / SSA / VTT），字幕字号可调"),
            Item(category: "新增", text: "音轨选择标注编码格式（如 E-AC3、AAC、DTS）与语言，选择会记住"),
            Item(category: "新增", text: "跳过片头片尾：片头与片尾时长可设，开播自动跳过片头，片尾可跳过或自动连播下一集"),
            Item(category: "新增", text: "章节标记与章节跳转、带剧照的选集面板、拖动进度时显示画面预览；上一集 / 下一集与快退 / 快进按钮可在设置里开关"),
            Item(category: "新增", text: "界面语言跟随系统语言（简体中文 / English）"),
        ]),
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
                            Text(LocalizedStringKey(item.category))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 30, alignment: .leading)
                            Text(LocalizedStringKey(item.text))
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
                        Text(LocalizedStringKey(entry.date))
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
