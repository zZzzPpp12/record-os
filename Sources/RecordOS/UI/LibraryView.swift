import AppKit
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var preview: PreviewTarget?
    @State private var projectPendingDelete: ProjectDocument?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeading(title: "项目库", subtitle: "每个项目区分「源文件」与「剪辑文件」，播放预览与剪辑分开操作。")

            if model.projectStore.projects.isEmpty {
                ContentUnavailableView {
                    Label("还没有项目", systemImage: "film.stack")
                } description: {
                    Text("完成一次录制后，项目会显示在这里。")
                } actions: {
                    Button("去录制") { model.route = .record }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.projectStore.projects) { project in
                            ProjectRow(
                                project: project,
                                sourceFileName: sourceFileName(for: project),
                                sourceURL: mediaURL(for: project),
                                onPlaySource: {
                                    if let url = mediaURL(for: project) {
                                        preview = PreviewTarget(
                                            project: project,
                                            url: url,
                                            title: "源文件 · \(sourceFileName(for: project))"
                                        )
                                    }
                                },
                                onPlayExport: { export in
                                    preview = PreviewTarget(
                                        project: project,
                                        url: export.url,
                                        title: "剪辑文件 · \(export.fileName)"
                                    )
                                },
                                onReveal: { url in
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                },
                                onRemoveExport: { export in
                                    model.removeExportRecord(export, from: project)
                                },
                                onEdit: { model.openEditor(project) },
                                onRename: { newName in
                                    model.renameProject(project, to: newName)
                                },
                                onDelete: {
                                    projectPendingDelete = project
                                }
                            )
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .sheet(item: $preview) { target in
            ProjectPreviewView(
                project: target.project,
                mediaURL: target.url,
                mediaTitle: target.title
            )
        }
        .confirmationDialog(
            "确定要删除「\(projectPendingDelete?.name ?? "")」吗？",
            isPresented: Binding(
                get: { projectPendingDelete != nil },
                set: { if !$0 { projectPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除项目", role: .destructive) {
                if let target = projectPendingDelete {
                    if preview?.project.id == target.id {
                        preview = nil
                    }
                    model.deleteProject(target)
                    projectPendingDelete = nil
                }
            }
            Button("取消", role: .cancel) {
                projectPendingDelete = nil
            }
        } message: {
            Text("这会永久删除该项目的工程文件和本地录屏视频，无法撤销。已导出的视频文件如果保存在其他位置则不受影响。")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.route = .record
                } label: {
                    Label("新录制", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func sourceFileName(for project: ProjectDocument) -> String {
        guard let clip = project.tracks.first(where: { $0.kind == .video })?.clips.first,
              let asset = project.assets.first(where: { $0.id == clip.assetID }) else {
            return "录像源文件"
        }
        return (asset.relativePath as NSString).lastPathComponent
    }

    private func mediaURL(for project: ProjectDocument) -> URL? {
        guard let clip = project.tracks.first(where: { $0.kind == .video })?.clips.first,
              let asset = project.assets.first(where: { $0.id == clip.assetID }) else {
            return nil
        }
        return model.projectStore.mediaURL(for: asset, in: project)
    }
}

private struct PreviewTarget: Identifiable {
    let project: ProjectDocument
    let url: URL
    let title: String

    var id: String { "\(project.id.uuidString)-\(url.path)" }
}

private struct ProjectRow: View {
    let project: ProjectDocument
    let sourceFileName: String
    let sourceURL: URL?
    let onPlaySource: () -> Void
    let onPlayExport: (ProjectExport) -> Void
    let onReveal: (URL) -> Void
    let onRemoveExport: (ProjectExport) -> Void
    let onEdit: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void

    @State private var isHoveringTitle = false
    @State private var isEditingTitle = false
    @State private var isExpanded = false
    @State private var missingExportIDs: Set<UUID> = []
    @State private var draftTitle = ""
    @State private var skipNextFocusLossCommit = false
    @FocusState private var titleFieldFocused: Bool

    private var latestExport: ProjectExport? { project.exports.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "收起文件列表" : "展开源文件与剪辑文件")

                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.11))
                    .frame(width: 72, height: 48)
                    .overlay {
                        Image(systemName: "play.rectangle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                VStack(alignment: .leading, spacing: 4) {
                    titleArea
                    HStack(spacing: 6) {
                        Text("\(project.canvasWidth) × \(project.canvasHeight) · \(project.frameRate) fps · \(project.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        fileCountBadges
                    }
                }
                Spacer()
                Text(project.duration.seconds.formattedDuration)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button(action: onPlaySource) {
                    Label("播放", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(sourceURL == nil)
                .help("播放源文件（未经剪辑的原始录屏）")
                Button(action: onEdit) {
                    Label("剪辑", systemImage: "scissors")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("打开独立剪辑页面")
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("删除项目")
            }

            if isExpanded {
                fileList
                    .padding(.leading, 26)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .onHover { hovering in
            if !hovering && isEditingTitle {
                commitRename()
            }
        }
        .onChange(of: titleFieldFocused) { _, focused in
            if !focused && isEditingTitle {
                if skipNextFocusLossCommit {
                    skipNextFocusLossCommit = false
                    return
                }
                commitRename()
            }
        }
        .onChange(of: project.name) { _, newName in
            if !isEditingTitle {
                draftTitle = newName
            }
        }
        .task(id: project.exports) {
            // Stat each exported file once per change instead of on every redraw.
            let missing = project.exports.filter { !$0.fileExists }.map(\.id)
            missingExportIDs = Set(missing)
        }
    }

    private var fileCountBadges: some View {
        HStack(spacing: 5) {
            badge(text: "源文件", tint: .accentColor)
            badge(
                text: latestExport == nil ? "未导出" : "剪辑文件 \(project.exports.count)",
                tint: latestExport == nil ? .secondary : .orange
            )
        }
    }

    private func badge(text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 6) {
            fileRow(
                symbol: "film",
                kindLabel: "源文件",
                tint: .accentColor,
                name: sourceFileName,
                detail: "\(project.duration.seconds.formattedDuration) · 未经剪辑的录屏原片",
                isMissing: false,
                playAction: sourceURL == nil ? nil : onPlaySource,
                revealURL: sourceURL
            )

            if project.exports.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "scissors")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text("剪辑文件")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .leading)
                    Text("尚未导出。在剪辑页点击「导出」后会生成包含剪辑与马赛克的成片。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 7))
            } else {
                ForEach(project.exports) { export in
                    let isMissing = missingExportIDs.contains(export.id)
                    fileRow(
                        symbol: "scissors",
                        kindLabel: "剪辑文件",
                        tint: .orange,
                        name: export.fileName,
                        detail: "\(export.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(export.duration.seconds.formattedDuration)",
                        isMissing: isMissing,
                        playAction: isMissing ? nil : { onPlayExport(export) },
                        revealURL: isMissing ? nil : export.url,
                        removeAction: { onRemoveExport(export) }
                    )
                }
            }
        }
    }

    private func fileRow(
        symbol: String,
        kindLabel: String,
        tint: Color,
        name: String,
        detail: String,
        isMissing: Bool,
        playAction: (() -> Void)?,
        revealURL: URL?,
        removeAction: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(kindLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(isMissing ? "文件已移动或删除" : detail)
                    .font(.system(size: 10))
                    .foregroundStyle(isMissing ? Color.red : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("播放", action: playAction ?? {})
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(playAction == nil)
            Button {
                if let revealURL { onReveal(revealURL) }
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(revealURL == nil)
            .help("在 Finder 中显示")
            if let removeAction {
                Button(role: .destructive, action: removeAction) {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("从项目记录中移除这个导出文件（不会删除磁盘上的文件）")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder
    private var titleArea: some View {
        if isEditingTitle {
            TextField("项目名称", text: $draftTitle)
                .textFieldStyle(.roundedBorder)
                .font(.body.weight(.medium))
                .frame(maxWidth: 320)
                .focused($titleFieldFocused)
                .onSubmit {
                    commitRename()
                }
                .onExitCommand {
                    cancelRename()
                }
        } else {
            HStack(spacing: 6) {
                Text(project.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Button {
                    beginRename()
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .opacity(isHoveringTitle ? 1 : 0)
                .allowsHitTesting(isHoveringTitle)
                .animation(.easeInOut(duration: 0.12), value: isHoveringTitle)
                .help("重命名项目")
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                isHoveringTitle = hovering
            }
        }
    }

    private func beginRename() {
        skipNextFocusLossCommit = false
        draftTitle = project.name
        isEditingTitle = true
        DispatchQueue.main.async {
            titleFieldFocused = true
        }
    }

    private func commitRename() {
        guard isEditingTitle else { return }
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditingTitle = false
        isHoveringTitle = false
        titleFieldFocused = false
        if !trimmed.isEmpty && trimmed != project.name {
            onRename(trimmed)
        }
    }

    private func cancelRename() {
        skipNextFocusLossCommit = true
        isEditingTitle = false
        isHoveringTitle = false
        titleFieldFocused = false
        draftTitle = project.name
    }
}
