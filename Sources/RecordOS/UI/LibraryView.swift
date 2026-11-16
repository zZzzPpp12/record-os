import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeading(title: "项目库", subtitle: "录制素材和剪辑项目都保存在本机。")

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
                            Button {
                                model.openProject(project)
                            } label: {
                                ProjectRow(project: project)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(28)
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
}

private struct ProjectRow: View {
    let project: ProjectDocument

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
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }
}
