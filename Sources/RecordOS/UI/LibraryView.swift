import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var previewProject: ProjectDocument?

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
                                onEdit: { model.openEditor(project) }
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
                Text(project.name).font(.body.weight(.medium)).foregroundStyle(.primary)
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
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}
