import AVKit
import SwiftUI

struct EditorView: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject var session: EditorSession
    @StateObject private var playback = EditorPlaybackModel()

    var body: some View {
        VStack(spacing: 0) {
            editorHeader
            Divider()
            HStack(spacing: 0) {
                preview
                Divider()
                inspector
            }
            .frame(maxHeight: .infinity)
            Divider()
            timeline
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await rebuildPlayback(for: session.project) }
        .onChange(of: session.project) { _, newProject in
            Task { await rebuildPlayback(for: newProject) }
        }
        .onReceive(playback.$currentTime) { value in
            guard playback.hasContent else { return }
            if abs(session.playhead.seconds - value) > 0.02 {
                session.playhead = MediaTime(seconds: value)
            }
        }
        .onDisappear { playback.teardown() }
        .alert("剪辑操作", isPresented: Binding(
            get: { session.errorMessage != nil },
            set: { if !$0 { session.clearError() } }
        )) {
            Button("好", role: .cancel) { session.clearError() }
        } message: {
            Text(session.errorMessage ?? "")
        }
    }

    private var editorHeader: some View {
        HStack(spacing: 12) {
            Button {
                appModel.activeEditor = nil
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .help("返回项目库")
            Text(session.project.name)
                .font(.headline)
            Spacer()
            Button("导出") {}
                .buttonStyle(.borderedProminent)
                .disabled(true)
                .help("导出渲染将在下一阶段接入")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
    }

    private var preview: some View {
        VStack(spacing: 12) {
            Group {
                if playback.hasContent {
                    NativePlayerSurface(player: playback.player)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                } else {
                    ContentUnavailableView(
                        "没有可预览的剪辑",
                        systemImage: "play.rectangle",
                        description: Text("时间线为空，或媒体文件已不存在。")
                    )
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 10) {
                Text(playback.currentTime.formattedDuration)
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 64, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { playback.currentTime },
                        set: { value in
                            session.playhead = MediaTime(seconds: value)
                            playback.updateScrub(to: value)
                        }
                    ),
                    in: 0...max(playback.duration, 0.1),
                    onEditingChanged: { playback.setScrubbing($0) }
                )
                .disabled(!playback.hasContent)

                Text(playback.duration.formattedDuration)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)
            }
            .padding(.horizontal, 22)

            HStack(spacing: 18) {
                Button {
                    playback.skip(by: -5)
                } label: {
                    Image(systemName: "gobackward.5")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .help("后退 5 秒")
                .disabled(!playback.hasContent)

                Button(action: playback.togglePlayback) {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor, in: Circle())
                }
                .buttonStyle(.plain)
                .help(playback.isPlaying ? "暂停" : "播放")
                .disabled(!playback.hasContent)

                Button {
                    playback.skip(by: 5)
                } label: {
                    Image(systemName: "goforward.5")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .help("前进 5 秒")
                .disabled(!playback.hasContent)

                Spacer()

                Text("预览的是剪辑后的时间线结果")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.035))
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("检查器").font(.headline)
            Divider()
            Text("项目设置").font(.subheadline.weight(.semibold))
            propertyRow("画布", value: "\(session.project.canvasWidth) × \(session.project.canvasHeight)")
            propertyRow("帧率", value: "\(session.project.frameRate) fps")
            propertyRow("素材", value: "\(session.project.assets.count) 个")
            Spacer()
            Text("片段操作").font(.subheadline.weight(.semibold))
            Button {
                session.splitAtPlayhead()
            } label: {
                Label("在播放头处分割", systemImage: "scissors")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(session.selectedClipID == nil)
            Button(role: .destructive) {
                session.deleteSelectedClip()
            } label: {
                Label("删除选中片段", systemImage: "trash")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(session.selectedClipID == nil)
            Button {
                session.undo()
            } label: {
                Label("撤销", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!session.canUndo)
        }
        .buttonStyle(.plain)
        .padding(18)
        .frame(width: 245, alignment: .leading)
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("时间线").font(.subheadline.weight(.semibold))
                Spacer()
                Text("点击片段可选中并定位播放头 · 非破坏式编辑 · 项目自动保存")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(session.project.tracks) { track in
                        HStack(spacing: 8) {
                            Text(track.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .leading)
                            ForEach(track.clips) { clip in
                                clipButton(for: clip)
                            }
                        }
                        .frame(height: 32)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(height: 142)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
    }

    private func clipButton(for clip: TimelineClip) -> some View {
        Button {
            session.selectedClipID = clip.id
            session.playhead = clip.timelineStart
            playback.seek(to: clip.timelineStart.seconds)
        } label: {
            RoundedRectangle(cornerRadius: 5)
                .fill(session.selectedClipID == clip.id ? Color.accentColor : Color.accentColor.opacity(0.42))
                .frame(width: max(110, clip.duration.seconds * 28), height: 28)
                .overlay(alignment: .leading) {
                    Text(clipLabel(for: clip))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.leading, 8)
                        .lineLimit(1)
                }
                .overlay {
                    if session.selectedClipID == clip.id {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .help("选中片段并定位到 \(clip.timelineStart.seconds.formattedDuration)")
    }

    private func clipLabel(for clip: TimelineClip) -> String {
        let trackKind = session.project.tracks
            .first(where: { track in track.clips.contains(where: { $0.id == clip.id }) })?
            .kind
        return trackKind == .audio ? "系统声音" : "屏幕录制"
    }

    private func propertyRow(_ name: String, value: String) -> some View {
        HStack {
            Text(name).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.caption)
    }

    private func rebuildPlayback(for project: ProjectDocument) async {
        await playback.rebuild(project: project) { asset in
            appModel.projectStore.mediaURL(for: asset, in: project)
        }
    }
}
