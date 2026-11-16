import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeading(title: "设置", subtitle: "管理本地项目位置和当前原型信息。")

            GroupBox("存储") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("项目保存在 ~/Library/Application Support/RecordOS/Projects")
                        .font(.callout)
                        .textSelection(.enabled)
                    Button("在 Finder 中打开项目目录") {
                        NSWorkspace.shared.open(model.projectStore.projectsDirectoryURL)
                    }
                    .buttonStyle(.link)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            GroupBox("当前录制原型") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("ScreenCaptureKit 全屏采集", systemImage: "display")
                    Label("MOV 容器 / H.264 编码 / 30 fps", systemImage: "film")
                    Label("项目结构版本 1", systemImage: "doc.text")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            Spacer()
        }
        .padding(28)
    }
}
