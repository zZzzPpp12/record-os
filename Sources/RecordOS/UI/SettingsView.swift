import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var pendingRoot: URL?
    @State private var errorMessage: String?

    private var storageRootPath: String {
        model.projectStore.rootURL.path
    }

    private var updater: AppUpdateChecker {
        model.updateChecker
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeading(title: "设置", subtitle: "管理本地项目存储目录与应用版本更新。")

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

            versionAndUpdateSection

            Spacer()
        }
        .padding(28)
        .task {
            await updater.checkIfNeededOnAppear()
        }
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

    private var versionAndUpdateSection: some View {
        GroupBox("应用版本") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("RecordOS \(updater.currentVersion.displayLabel)")
                                .font(.system(.body, design: .monospaced).weight(.semibold))
                            versionBadge
                        }
                        updateStatusSummary
                    }

                    Spacer()

                    updateActionButtons
                }

                if case .downloading(let info, let progress) = updater.status {
                    VStack(alignment: .leading, spacing: 6) {
                        if let progress {
                            ProgressView(value: progress)
                            Text("正在下载 \(info.installerAsset?.name ?? "更新安装包") · \(Int((progress * 100).rounded()))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        } else {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在下载 \(info.installerAsset?.name ?? "更新安装包")…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 2)
                }

                if let release = updater.availableRelease, !release.releaseNotes.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("v\(release.version) 更新内容")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ScrollView {
                            Text(release.releaseNotes)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 110)
                    }
                }

                HStack(spacing: 12) {
                    if let checkedAt = updater.lastCheckedAt {
                        Text("上次检测：\(checkedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("支持从 GitHub Releases 自动检测新版安装包。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("查看版本发布页") {
                        updater.openReleasesPage()
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var versionBadge: some View {
        switch updater.status {
        case .updateAvailable(let info), .downloading(let info, _), .downloaded(let info, _):
            Text("发现新版本 v\(info.version)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.14), in: Capsule())
        case .upToDate:
            Text("已是最新")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.green)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.13), in: Capsule())
        case .checking, .idle, .failed:
            EmptyView()
        }
    }

    @ViewBuilder
    private var updateStatusSummary: some View {
        switch updater.status {
        case .idle:
            Text("尚未检测远端更新。")
                .font(.callout)
                .foregroundStyle(.secondary)

        case .checking:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("正在检测是否有新版本安装包…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case .upToDate(let latestVersion):
            if let latestVersion {
                Text("当前使用的是最新版本（远端最新 v\(latestVersion)）。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("当前使用的是最新版本。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case .updateAvailable(let info):
            if let asset = info.installerAsset {
                Text("可下载更新包：\(asset.name)（\(asset.formattedSize)）")
                    .font(.callout)
                    .foregroundStyle(.primary)
            } else {
                Text("远端已发布 v\(info.version)，点击「立即更新」前往发布页下载安装包。")
                    .font(.callout)
                    .foregroundStyle(.primary)
            }

        case .downloading(let info, _):
            Text("正在获取 RecordOS v\(info.version) 安装包…")
                .font(.callout)
                .foregroundStyle(.secondary)

        case .downloaded(_, let fileURL):
            HStack(spacing: 8) {
                Text("安装包已下载至「下载」文件夹：\(fileURL.lastPathComponent)")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("在 Finder 中显示") {
                    updater.revealInstallerInFinder(fileURL)
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }

        case .failed(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var updateActionButtons: some View {
        HStack(spacing: 10) {
            switch updater.status {
            case .downloading:
                Button("取消下载") {
                    updater.cancelDownload()
                }
                .buttonStyle(.bordered)

            case .downloaded(_, let fileURL):
                Button("检查更新") {
                    Task { await updater.checkForUpdates(userInitiated: true) }
                }
                .buttonStyle(.bordered)

                Button {
                    updater.openInstaller(at: fileURL)
                } label: {
                    Label("立即安装", systemImage: "arrow.down.app.fill")
                }
                .buttonStyle(.borderedProminent)

            case .updateAvailable:
                Button("重新检测") {
                    Task { await updater.checkForUpdates(userInitiated: true) }
                }
                .buttonStyle(.bordered)

                Button {
                    updater.performUpdate()
                } label: {
                    Label("立即更新", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)

            case .idle, .checking, .upToDate, .failed:
                Button("检查更新") {
                    Task { await updater.checkForUpdates(userInitiated: true) }
                }
                .buttonStyle(.bordered)
                .disabled(updater.isBusy)

                Button {
                    updater.performUpdate()
                } label: {
                    Label("立即更新", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(true)
                .help("检测到新版本安装包后可点击立即下载更新")
            }
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
