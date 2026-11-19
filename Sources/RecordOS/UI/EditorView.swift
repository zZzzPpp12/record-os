import AppKit
import AVKit
import SwiftUI

struct EditorView: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject var session: EditorSession
    @State private var playback = EditorPlaybackModel()
    @StateObject private var exporter = ProjectExporter()
    @State private var mosaicUpdateTask: Task<Void, Never>?
    @State private var exportAlert: ExportAlert?

    var body: some View {
        VStack(spacing: 0) {
            editorHeader
            Divider()
            HStack(spacing: 0) {
                EditorPreviewPane(session: session, playback: playback)
                Divider()
                inspector
            }
            .frame(maxHeight: .infinity)
            Divider()
            timeline
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await rebuildPlayback(for: session.project) }
        .onChange(of: session.project.tracks) { _, _ in
            Task { await rebuildPlayback(for: session.project) }
        }
        .onChange(of: session.project.assets) { _, _ in
            Task { await rebuildPlayback(for: session.project) }
        }
        .onChange(of: session.project.mosaicRegions) { _, newRegions in
            // Coalesce rapid updates while dragging a mosaic box: rebuilding the
            // video composition on every mouse move would stutter the preview.
            mosaicUpdateTask?.cancel()
            mosaicUpdateTask = Task {
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled else { return }
                await playback.updateVideoComposition(mosaicRegions: newRegions)
            }
        }
        .onChange(of: playback.isPlaying) { _, playing in
            if playing {
                session.isMosaicDrawMode = false
            }
        }
        .onChange(of: session.rangeStart) { _, _ in updatePlaybackRange() }
        .onChange(of: session.rangeEnd) { _, _ in updatePlaybackRange() }
        .onChange(of: playback.duration) { _, _ in updatePlaybackRange() }
        .onDisappear {
            mosaicUpdateTask?.cancel()
            playback.teardown()
        }
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

            if exporter.isExporting {
                HStack(spacing: 8) {
                    ProgressView(value: exporter.progress)
                        .frame(width: 110)
                    Text("导出中 \(exporter.progressPercent)%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .help("正在渲染时间线与马赛克效果")
            } else {
                Button {
                    beginExport()
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!playback.hasContent)
                .help(playback.hasContent ? "导出包含剪辑与马赛克的视频" : "时间线为空，暂无可导出内容")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .alert(exportAlertTitle, isPresented: exportAlertPresented) {
            if case .completed(let url)? = exportAlert {
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    exportAlert = nil
                }
            }
            Button("好", role: .cancel) { exportAlert = nil }
        } message: {
            Text(exportAlertMessage)
        }
    }

    private var exportAlertPresented: Binding<Bool> {
        Binding(
            get: { exportAlert != nil },
            set: { if !$0 { exportAlert = nil } }
        )
    }

    private var exportAlertTitle: String {
        if case .failed = exportAlert { return "导出失败" }
        return "导出完成"
    }

    private var exportAlertMessage: String {
        switch exportAlert {
        case .completed(let url): url.path
        case .failed(let message): message
        case nil: ""
        }
    }

    private func beginExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(sanitizedFileName(session.project.name)).mov"
        panel.message = "选择导出视频的保存位置（包含当前剪辑与马赛克效果）"
        panel.prompt = "导出"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        playback.pause()
        session.isMosaicDrawMode = false
        Task {
            let outcome = await exporter.export(project: session.project, to: url) { asset in
                appModel.projectStore.mediaURL(for: asset, in: session.project)
            }
            switch outcome {
            case .success(let exportedURL):
                session.recordExport(at: exportedURL)
                exportAlert = .completed(exportedURL)
            case .failure(let message):
                exportAlert = .failed(message)
            }
        }
    }

    private func sanitizedFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "RecordOS 导出" : cleaned
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("检查器").font(.headline)
                Divider()
                Text("项目设置").font(.subheadline.weight(.semibold))
                propertyRow("画布", value: "\(session.project.canvasWidth) × \(session.project.canvasHeight)")
                propertyRow("帧率", value: "\(session.project.frameRate) fps")
                propertyRow("素材", value: "\(session.project.assets.count) 个")
                propertyRow("轨道", value: "\(session.project.tracks.count) 条")

                Divider()
                mosaicInspectorSection

                Divider()
                Text("拖动左右蓝色分割点确定时间段；点击「添加马赛克」后在视频画面上框选要遮挡的区域即可完成打码。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
        }
        .frame(width: 265, alignment: .leading)
    }

    @ViewBuilder
    private var mosaicInspectorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("马赛克打码").font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    playback.pause()
                    session.addMosaicRegion(rect: .defaultCentered)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(!playback.hasContent || !session.hasSelectedRange)
                .help("在当前分割点时间段快速添加一个居中马赛克框")
            }

            if session.project.mosaicRegions.isEmpty {
                Text("暂无打码区域。先用分割点选好时间段，再点击「添加马赛克」并在画面上拖动框选。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(session.project.mosaicRegions.enumerated()), id: \.element.id) { index, region in
                        let isSelected = session.selectedMosaicID == region.id
                        HStack(spacing: 8) {
                            Button {
                                session.selectedMosaicID = region.id
                                session.rangeStart = region.startTime
                                session.rangeEnd = region.endTime
                                playback.seek(to: region.startTime.seconds)
                            } label: {
                                HStack {
                                    Image(systemName: "checkerboard.rectangle")
                                        .foregroundStyle(isSelected ? .orange : .secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text("马赛克 \(index + 1)")
                                            .font(.caption.weight(.medium))
                                        Text("\(region.startTime.seconds.formattedDuration) – \(region.endTime.seconds.formattedDuration)")
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button(role: .destructive) {
                                session.deleteMosaicRegion(id: region.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption2)
                            }
                            .buttonStyle(.borderless)
                            .help("删除此马赛克")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isSelected ? Color.orange.opacity(0.14) : Color(nsColor: .controlBackgroundColor))
                        )
                    }
                }

                if let selected = session.selectedMosaic {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("颗粒强度")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(selected.pixelScale)) px")
                                .font(.system(.caption, design: .monospaced))
                        }
                        Slider(
                            value: Binding(
                                get: { selected.pixelScale },
                                set: { newValue in
                                    session.updateMosaicRegion(
                                        id: selected.id,
                                        pixelScale: newValue,
                                        recordUndo: false
                                    )
                                }
                            ),
                            in: 8...64,
                            step: 2,
                            onEditingChanged: { editing in
                                if editing {
                                    session.beginMosaicUndoCheckpoint()
                                } else {
                                    session.endMosaicEditSession()
                                }
                            }
                        )

                        HStack(spacing: 8) {
                            Button("应用当前分割点时段") {
                                session.updateMosaicRegion(
                                    id: selected.id,
                                    startTime: session.rangeStart,
                                    endTime: session.rangeEnd
                                )
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .disabled(!session.hasSelectedRange)
                            .help("把选中马赛克的时间范围更新为进度条当前的起止分割点")

                            Button("跳到起点") {
                                playback.seek(to: selected.startTime.seconds)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("时间线").font(.subheadline.weight(.semibold))
                Spacer()
                Text("拖动前/后分割点选择范围 · 支持分段马赛克打码 · 非破坏式编辑 · 自动保存")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(session.project.tracks) { track in
                        HStack(spacing: 8) {
                            Text(track.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .leading)
                            ForEach(track.clips) { clip in
                                clipButton(for: clip, track: track)
                            }
                        }
                        .frame(height: 32)
                    }

                    if !session.project.mosaicRegions.isEmpty {
                        mosaicTimelineRow
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(height: timelineHeight)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
    }

    private var timelineHeight: CGFloat {
        let trackRows = max(1, session.project.tracks.count)
        let mosaicRows = session.project.mosaicRegions.isEmpty ? 0 : 1
        let totalRows = trackRows + mosaicRows
        return min(240, max(142, CGFloat(totalRows) * 39 + 54))
    }

    private var mosaicTimelineRow: some View {
        let totalDuration = max(session.project.duration.seconds, 0.1)
        let trackWidth = max(240, totalDuration * 28)

        return HStack(spacing: 8) {
            Text("打码")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(0.05))
                    .frame(width: trackWidth, height: 28)

                ForEach(Array(session.project.mosaicRegions.enumerated()), id: \.element.id) { index, region in
                    let startRatio = region.startTime.seconds / totalDuration
                    let lengthRatio = max(region.duration.seconds / totalDuration, 0.02)
                    let blockX = startRatio * trackWidth
                    let blockWidth = max(26, lengthRatio * trackWidth)
                    let isSelected = session.selectedMosaicID == region.id

                    Button {
                        session.selectedMosaicID = region.id
                        session.rangeStart = region.startTime
                        session.rangeEnd = region.endTime
                        playback.seek(to: region.startTime.seconds)
                    } label: {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isSelected ? Color.orange : Color.orange.opacity(0.55))
                            .frame(width: blockWidth, height: 24)
                            .overlay(alignment: .leading) {
                                Text("马赛克 \(index + 1)")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .lineLimit(1)
                            }
                            .overlay {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 5)
                                        .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .offset(x: blockX)
                    .help("选中马赛克 \(index + 1)（\(region.startTime.seconds.formattedDuration) – \(region.endTime.seconds.formattedDuration)）")
                }
            }
        }
        .frame(height: 30)
    }

    private func clipButton(for clip: TimelineClip, track: TimelineTrack) -> some View {
        Button {
            session.selectedClipID = clip.id
            playback.seek(to: clip.timelineStart.seconds)
        } label: {
            RoundedRectangle(cornerRadius: 5)
                .fill(session.selectedClipID == clip.id ? Color.accentColor : Color.accentColor.opacity(0.42))
                .frame(width: max(110, clip.duration.seconds * 28), height: 28)
                .overlay(alignment: .leading) {
                    Text(clipLabel(for: track))
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

    private func clipLabel(for track: TimelineTrack) -> String {
        track.kind == .audio ? track.name : "屏幕录制"
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

private struct EditorPreviewPane: View {
    @ObservedObject var session: EditorSession
    let playback: EditorPlaybackModel

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                if playback.hasContent {
                    NativePlayerSurface(player: playback.player)
                        .overlay {
                            MosaicOverlayEditor(
                                videoSize: CGSize(
                                    width: max(session.project.canvasWidth, 1),
                                    height: max(session.project.canvasHeight, 1)
                                ),
                                regions: session.project.mosaicRegions,
                                selectedRegionID: $session.selectedMosaicID,
                                currentTime: playback.currentTime,
                                isDrawMode: session.isMosaicDrawMode,
                                onCreateRegion: { rect in
                                    session.addMosaicRegion(rect: rect)
                                },
                                onBeginEdit: {
                                    session.beginMosaicUndoCheckpoint()
                                },
                                onUpdateRect: { id, rect in
                                    session.updateMosaicRegion(id: id, rect: rect, recordUndo: false)
                                },
                                onEndEdit: {
                                    session.endMosaicEditSession()
                                },
                                onSelectRegion: { id in
                                    session.selectedMosaicID = id
                                }
                            )
                        }
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

            if session.isMosaicDrawMode {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.dashed")
                        .foregroundStyle(.orange)
                    Text("框选打码模式：直接在上方视频画面拖动框选需要打码的区域（时间段为 \(session.rangeStart.seconds.formattedDuration) – \(session.rangeEnd.seconds.formattedDuration)）")
                        .font(.caption)
                        .foregroundStyle(.primary)
                    Spacer()
                    Button("取消框选") {
                        session.isMosaicDrawMode = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                .padding(.horizontal, 18)
            }

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
                },
                onScrubStateChanged: { scrubbing in
                    playback.setScrubbing(scrubbing)
                }
            )
            .padding(.horizontal, 18)

            HStack(spacing: 10) {
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

                Spacer(minLength: 6)

                Text(rangeSummary)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Button {
                    if session.isMosaicDrawMode {
                        session.isMosaicDrawMode = false
                    } else {
                        playback.pause()
                        session.isMosaicDrawMode = true
                    }
                } label: {
                    Label(session.isMosaicDrawMode ? "框选中…" : "添加马赛克", systemImage: "checkerboard.rectangle")
                }
                .buttonStyle(.borderedProminent)
                .tint(session.isMosaicDrawMode ? .orange : .accentColor)
                .controlSize(.small)
                .disabled(!playback.hasContent || !session.hasSelectedRange)
                .help("在画面上框选区域，对当前分割点时间段打马赛克")

                Button("切分") {
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
        "分割点 \(session.rangeStart.seconds.formattedDuration) – \(session.rangeEnd.seconds.formattedDuration)"
    }
}

private enum ExportAlert {
    case completed(URL)
    case failed(String)
}
