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
        .onChange(of: session.rangeStart) { _, _ in updatePlaybackRange() }
        .onChange(of: session.rangeEnd) { _, _ in updatePlaybackRange() }
        .onChange(of: playback.duration) { _, _ in updatePlaybackRange() }
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
        VStack(spacing: 10) {
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

            TimelineRangeSlider(
                duration: max(playback.duration, 0.1),
                rangeStart: Binding(
                    get: { session.rangeStart.seconds },
                    set: { session.rangeStart = MediaTime(seconds: $0) }
                ),
                rangeEnd: Binding(
                    get: { session.rangeEnd.seconds },
                    set: { session.rangeEnd = MediaTime(seconds: $0) }
                ),
                playhead: playback.currentTime,
                onSeek: { value in
                    playback.seek(to: value)
                    session.playhead = MediaTime(seconds: value)
                },
                onScrubStateChanged: { scrubbing in
                    playback.setScrubbing(scrubbing)
                }
            )
            .padding(.horizontal, 18)

            HStack(spacing: 12) {
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
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
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

                Text("\(playback.currentTime.formattedDuration) / \(playback.duration.formattedDuration)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)

                Spacer(minLength: 8)

                Text(rangeSummary)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Button("在分割点切分") {
                    session.splitAtRangeMarkers()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!session.hasInteriorSplitMarkers)
                .help("按进度条上的前/后分割点将片段切分开")

                Button("删除范围", role: .destructive) {
                    session.deleteSelectedRange()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!session.hasSelectedRange)
                .help("删除前/后分割点之间的内容")

                Button("仅保留所选") {
                    session.keepOnlySelectedRange()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!session.hasSelectedRange)
                .help("只保留前/后分割点之间的内容")

                Button("撤销") {
                    session.undo()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!session.canUndo)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.035))
    }

    private var rangeSummary: String {
        "分割点 \(session.rangeStart.seconds.formattedDuration) – \(session.rangeEnd.seconds.formattedDuration) · 长度 \(session.selectedRangeLength.seconds.formattedDuration)"
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("检查器").font(.headline)
            Divider()
            Text("项目设置").font(.subheadline.weight(.semibold))
            propertyRow("画布", value: "\(session.project.canvasWidth) × \(session.project.canvasHeight)")
            propertyRow("帧率", value: "\(session.project.frameRate) fps")
            propertyRow("素材", value: "\(session.project.assets.count) 个")
            propertyRow("轨道", value: "\(session.project.tracks.count) 条")
            Spacer()
            Text("拖动进度条左右两个蓝色分割点设定范围，点击进度条可在范围内跳转。支持「在分割点切分」「删除范围」或「仅保留所选」，播放时会在后分割点自动暂停。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 245, alignment: .leading)
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("时间线").font(.subheadline.weight(.semibold))
                Spacer()
                Text("拖动前/后分割点选择范围 · 点击片段可定位 · 非破坏式编辑 · 自动保存")
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
        updatePlaybackRange()
    }

    private func updatePlaybackRange() {
        let end = min(session.rangeEnd.seconds, playback.duration)
        let start = max(0, min(session.rangeStart.seconds, end))
        guard playback.duration > 0, end - start > 0.01 else {
            playback.setPlaybackRange(nil)
            return
        }
        playback.setPlaybackRange(start...end)
    }
}
