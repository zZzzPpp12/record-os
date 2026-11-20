# RecordOS

原生 macOS 录屏与轻量剪辑应用的功能框架。

## 当前包含

- SwiftUI 应用壳与录制、项目库、设置导航
- ScreenCaptureKit 全屏、独立窗口与交互框选区域录制（MOV / H.264），录制中在菜单栏显示动态红点与时长
- 支持系统声音与麦克风音频采集及设备选择（写入同一 MOV 源文件）
- 本地项目库与 JSON 项目文件
- 视频预览、可视化时间线（时间标尺、缩放、可拖动全局播放头与真实时间片段定位）
- 播放头分割（`S` / `⌘B`）、`I`/`O` 快捷选区、波纹删除（自动闭合间隙并同步偏移后续片段与打码）、片段级删除、撤销与重做（`⌘Z` / `⇧⌘Z`）与自动保存
- 多音轨独立混音控制：在轨道头实时静音与调节音量（`0%–200%`），预览与导出一致
- 视频画面内任意区域马赛克打码，可按时段生效并随剪辑同步
- 将剪辑、音轨混音与马赛克效果导出为本地 MOV 视频
- 项目库中区分「源文件」与「剪辑文件」，可分别播放、定位和移除记录
- 清晰分层的 Capture、Project、Editing、UI 模块

## 构建

需要 Xcode 26 和 macOS 15 SDK：

```sh
xcodegen generate
xcodebuild -project RecordOS.xcodeproj -scheme RecordOS -configuration Debug build
```

首次录制时，macOS 会请求屏幕录制权限；开启麦克风录制时会请求麦克风权限。当前采集能力已支持整个屏幕、应用窗口与屏幕框选区域录制。

## 数据位置

项目默认保存在 `~/Library/Application Support/RecordOS/Projects/`，可在「设置 → 存储位置」中更换为任意文件夹（支持迁移已有项目）。每个项目包含一个 `project.json` 和 `Media/` 源媒体目录。
