import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var previewProject: ProjectDocument?
    @State private var projectPendingDelete: ProjectDocument?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeading(title: "项目库", subtitle: "播放预览与剪辑分开操作。")

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
                                onPlay: { previewProject = project },
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
        .sheet(item: $previewProject) { project in
            ProjectPreviewView(project: project, mediaURL: mediaURL(for: project))
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
                    if previewProject?.id == target.id {
                        previewProject = nil
                    }
                    model.deleteProject(target)
                    projectPendingDelete = nil
                }
            }
            Button("取消", role: .cancel) {
                projectPendingDelete = nil
            }
        } message: {
            Text("这会永久删除该项目的工程文件和本地录屏视频，无法撤销。")
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

    private func mediaURL(for project: ProjectDocument) -> URL? {
        guard let clip = project.tracks.first(where: { $0.kind == .video })?.clips.first,
              let asset = project.assets.first(where: { $0.id == clip.assetID }) else {
            return nil
        }
        return model.projectStore.mediaURL(for: asset, in: project)
    }
}

private struct ProjectRow: View {
    let project: ProjectDocument
    let onPlay: () -> Void
    let onEdit: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void

    @State private var isHoveringTitle = false
    @State private var isEditingTitle = false
    @State private var draftTitle = ""
    @State private var skipNextFocusLossCommit = false
    @FocusState private var titleFieldFocused: Bool

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.11))
                .frame(width: 72, height: 48)
                .overlay {
                    Image(systemName: "play.rectangle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            VStack(alignment: .leading, spacing: 4) {
                titleArea
                Text("\(project.canvasWidth) × \(project.canvasHeight) · \(project.frameRate) fps · \(project.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(project.duration.seconds.formattedDuration)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Button(action: onPlay) {
                Label("播放", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("播放项目视频")
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
