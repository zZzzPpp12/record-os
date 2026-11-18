# RecordOS

原生 macOS 录屏与轻量剪辑应用的功能框架。

## 当前包含

- SwiftUI 应用壳与录制、项目库、设置导航
- ScreenCaptureKit 全屏录制入口（MOV / H.264），录制中在菜单栏显示动态红点与时长
- 本地项目库与 JSON 项目文件
- 视频预览、双分割点区间剪辑（删除/仅保留/切分）、撤销与自动保存
- 视频画面内任意区域马赛克打码，可按时段生效并随剪辑同步
- 将剪辑与马赛克效果导出为本地 MOV 视频
- 项目库中区分「源文件」与「剪辑文件」，可分别播放、定位和移除记录
- 清晰分层的 Capture、Project、Editing、UI 模块

## 构建

需要 Xcode 26 和 macOS 15 SDK：

```sh
xcodegen generate
xcodebuild -project RecordOS.xcodeproj -scheme RecordOS -configuration Debug build
```

首次录制时，macOS 会请求屏幕录制权限。当前采集原型录制所选显示器并保存到应用支持目录下；窗口/区域选择和音轨拆分是后续功能。

## 数据位置

项目默认保存在 `~/Library/Application Support/RecordOS/Projects/`，可在「设置 → 存储位置」中更换为任意文件夹（支持迁移已有项目）。每个项目包含一个 `project.json` 和 `Media/` 源媒体目录。
