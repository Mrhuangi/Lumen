# 流光 v4 · UI 设计说明

设计依据：Apple HIG（iOS 26 Liquid Glass）与 WWDC25/26 场次、GitHub 开源客户端
（Swiftfin 为首要范本；KSPlayer 为 GPL 只借鉴交互不抄代码）逐项核实后的综合方案。
完整图文版见设计方案页（Muse 产物「流光 UI 设计方案」），调研底稿在
`~/workspace/research_notes/liuguang-player-ui-apple-design-research-20261104-0748/`。

## 基线

- 最低系统 iOS 26（部署目标 26.0）。目标机：iPhone SE 3（iOS 27.2，4.7″ LCD 375×667pt）
  与 iPhone 16 Pro Max（iOS 26.6.1，6.9″ OLED 440×956pt，灵动岛，120Hz）。
- 不依赖任何 iOS 27 专属 API；27 的玻璃外观精修由系统对系统组件自动生效。
- 全 App 深色、纯黑底；玻璃只用于导航层（标签栏、工具栏、重封装卡），内容层（海报）不用玻璃。

## 信息架构

- 2 个 Tab：媒体库、搜索（Tab(role: .search)）。标签栏滚动时自动收起（tabBarMinimizeBehavior）。
- 设置走工具栏「…」菜单 → 设置页（Form 分组，≤ 约 8 项）：自动续播、
  外挂字幕字号、清除续播记录、清除重封装缓存、关于。
- 导入走工具栏「＋」菜单：导入文件 / 添加网址。工具栏预算遵循小屏纪律：标题 + 2 个图标按钮。

## 媒体库

- 「继续观看」横排卡（16:9 占位图 + 底部进度条 + 已看百分比），有点播进度 2%–95% 的条目才出现。
- 全部影片：海报网格，列数用 GridItem(.adaptive(minimum: 100, maximum: 170)) 按容器宽度自适应
  ——两机竖屏同为 3 列（16PM 海报更大），横屏 5–6 列成墙。不用 size class 分机型（两机竖屏同为 compact×regular）。
- 无真实海报，用按片名生成的 2:3 标题占位图（深色双色调渐变 + 流光三线 + 片名），与设计方案页中的占位样式一致。
- 徽章永远带文字（如「本地 · MKV · 外挂字幕」），出现在卡片/行内，不放玻璃上。
- 操作：点按播放；长按上下文菜单（播放、外挂字幕增删改、删除）；列表模式支持左滑删除。
- 排序：最近播放 / 最近添加 / 片名。显示：网格 / 列表。

## 双尺寸与无障碍

- 安全区一律运行时读取，不写死数值；SE 无灵动岛、16PM 横屏灵动岛侧置均由系统播放器与安全区处理。
- Dynamic Type：正文用语义字体样式；无障碍字号下媒体库网格自动降为列表（最坏组合 SE×AX5 的验收线）。
- SE 的 LCD 对比度较低：导航玻璃只用 .regular、次级文字用语义色，不写死低透明度白。
- Reduce Transparency / Increase Contrast / Reduce Motion 全交系统玻璃自动适配，App 不自绘替代材质。

## 播放

- 零自绘 Chrome：全托 AVPlayerViewController（字幕/音轨菜单、PiP、AirPlay、续播均为系统行为）。
- 仅保留两件自有元素：左上标题 + 格式徽章（材质胶囊）、右上关闭按钮；外挂字幕叠加层字号可在设置调。
- MKV 重封装进度：居中玻璃卡（流光三线 + 片名 + 百分比 + 进度条），完成即自动开播；
  警告（如图形字幕跳过、双层 DV）以系统 alert 在开播后呈现。

##  token 速记

- 间距：页边距 16、海报间距 12、区段间距 24；圆角：海报 10、卡片 24。
- 字体：标题 .title3 semibold（区段）、片名 .subheadline semibold（海报内）、说明 .caption/.caption2 + .secondary。
- 图标符号：SF Symbols（film.stack、magnifyingglass、plus、ellipsis.circle、gearshape、captions.bubble）。
