import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var pendingRoot: URL?
    @State private var errorMessage: String?

    private var storageRootPath: String {
        model.projectStore.rootURL.path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeading(title: "设置", subtitle: "管理本地项目位置和当前原型信息。")

            GroupBox("存储位置") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("录屏源文件与项目工程保存在：")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(storageRootPath)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    HStack(spacing: 14) {
                        Button("更改位置…") {
                            chooseStorageFolder()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("在 Finder 中打开") {
                            NSWorkspace.shared.open(model.projectStore.projectsDirectoryURL)
                        }
                        .buttonStyle(.link)

                        Button("恢复默认位置") {
                            requestRootChange(to: ProjectStore.defaultRootURL())
                        }
                        .buttonStyle(.link)
                        .disabled(storageRootPath == ProjectStore.defaultRootURL().path)
                    }

                    Text("每个项目的录屏文件保存在所选位置下的 Projects/<项目ID>/Media 目录中；更改位置时可选择是否迁移已有项目。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            GroupBox("当前录制原型") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("ScreenCaptureKit 全屏 / 窗口 / 框选区域采集", systemImage: "display")
                    Label("支持系统声音与麦克风独立开关与设备选择", systemImage: "mic")
                    Label("MOV 容器 / H.264 编码 / 30 fps", systemImage: "film")
                    Label("项目结构版本 1", systemImage: "doc.text")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            Spacer()
        }
        .padding(28)
        .alert("存储位置", isPresented: errorAlertPresented) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            "切换存储位置？",
            isPresented: migrationDialogPresented,
            titleVisibility: .visible
        ) {
            Button("移动现有项目") { applyPendingRoot(migrate: true) }
            Button("仅切换位置") { applyPendingRoot(migrate: false) }
            Button("取消", role: .cancel) { pendingRoot = nil }
        } message: {
            Text(migrationMessage)
        }
    }

    private var migrationMessage: String {
        guard let pendingRoot else { return "" }
        return """
        新位置：\(pendingRoot.path)
        是否把现有 \(model.projectStore.projects.count) 个项目迁移到新位置？选择“仅切换位置”时，旧项目会保留在原目录，但不会显示在项目库中。
        """
    }

    private var errorAlertPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var migrationDialogPresented: Binding<Bool> {
        Binding(
            get: { pendingRoot != nil },
            set: { if !$0 { pendingRoot = nil } }
        )
    }

    private func chooseStorageFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择此文件夹"
        panel.message = "选择用于保存录屏项目与视频的文件夹"
        panel.directoryURL = model.projectStore.rootURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        requestRootChange(to: url)
    }

    private func requestRootChange(to url: URL) {
        let target = url.standardizedFileURL
        guard target.path != model.projectStore.rootURL.standardizedFileURL.path else { return }
        if model.projectStore.projects.isEmpty {
            applyRoot(target, migrate: false)
        } else {
            pendingRoot = target
        }
    }

    private func applyPendingRoot(migrate: Bool) {
        guard let root = pendingRoot else { return }
        pendingRoot = nil
        applyRoot(root, migrate: migrate)
    }

    private func applyRoot(_ url: URL, migrate: Bool) {
        do {
            try model.projectStore.changeStorageRoot(to: url, migrateExisting: migrate)
            model.activeEditor = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
