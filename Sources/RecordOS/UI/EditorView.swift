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
    @State private var showSavedConfirmation = false
    @State private var savedConfirmationTask: Task<Void, Never>?

    private var trackStructureSignature: [TrackStructureKey] {
        session.project.tracks.map { TrackStructureKey(id: $0.id, kind: $0.kind, clips: $0.clips) }
    }

    private var trackAudioMixSignature: [TrackAudioMixKey] {
        session.project.tracks.map { TrackAudioMixKey(id: $0.id, isMuted: $0.isMuted, volume: $0.volume) }
    }

    private var isModalAlertPresented: Bool {
        session.errorMessage != nil || exportAlert != nil || exporter.isExporting
    }

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
            EditorTimelineView(session: session, playback: playback)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .modifier(
            EditorKeyboardMonitor(
                isEnabled: !isModalAlertPresented,
                onSpace: {
                    playback.togglePlayback()
                },
                onSplitAtPlayhead: {
                    session.splitAtPlayhead(MediaTime(seconds: playback.currentTime))
                },
                onSetRangeStart: {
                    session.setRangeStart(to: MediaTime(seconds: playback.currentTime))
                },
                onSetRangeEnd: {
                    session.setRangeEnd(to: MediaTime(seconds: playback.currentTime))
                },
                onDelete: {
                    handleKeyboardDelete()
                },
                onStepFrame: { delta in
                    playback.skip(by: delta)
                }
            )
        )
        .task { await rebuildPlayback(for: session.project) }
        .onChange(of: trackStructureSignature) { _, _ in
            Task { await rebuildPlayback(for: session.project) }
        }
        .onChange(of: trackAudioMixSignature) { _, _ in
            playback.updateAudioMix(for: session.project)
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
            savedConfirmationTask?.cancel()
            if session.hasUnsavedChanges {
                session.saveNow()
            }
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

    private func handleKeyboardDelete() {
        if session.hasPartialSelectedRange {
            if let jumpTime = session.deleteSelectedRange() {
                playback.seek(to: jumpTime.seconds)
            }
        } else if session.selectedClip != nil {
            if let jumpTime = session.deleteSelectedClip() {
                playback.seek(to: jumpTime.seconds)
            }
        }
    }

    private var editorHeader: some View {
        HStack(spacing: 12) {
            Button {
                if !session.hasUnsavedChanges || session.saveNow() {
                    appModel.activeEditor = nil
                }
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .help("保存并返回项目库")
            Text(session.project.name)
                .font(.headline)

            saveStatusLabel

            Spacer()

            Button {
                performSave()
            } label: {
                Label(showSavedConfirmation ? "已保存" : "保存", systemImage: showSavedConfirmation ? "checkmark.circle.fill" : "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(exporter.isExporting)
            .help("保存当前剪辑进度到项目 (⌘S)")

            if exporter.isExporting {
                HStack(spacing: 8) {
                    ProgressView(value: exporter.progress)
                        .frame(width: 110)
                    Text("导出中 \(exporter.progressPercent)%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .help("正在渲染时间线、混音与马赛克效果")
            } else {
                Button {
                    beginExport()
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!playback.hasContent)
                .help(playback.hasContent ? "导出包含剪辑、混音与马赛克的视频" : "时间线为空，暂无可导出内容")
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

    @ViewBuilder
    private var saveStatusLabel: some View {
        if showSavedConfirmation {
            Text("已保存")
                .font(.caption)
                .foregroundStyle(.green)
                .transition(.opacity)
        } else if session.hasUnsavedChanges {
            Text("有未保存的更改")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if let savedAt = session.lastSavedAt {
            Text("已保存于 \(savedAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("自动保存已开启")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func performSave() {
        guard session.saveNow() else { return }
        savedConfirmationTask?.cancel()
        withAnimation(.easeInOut(duration: 0.15)) {
            showSavedConfirmation = true
        }
        savedConfirmationTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                showSavedConfirmation = false
            }
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
        panel.message = "选择导出视频的保存位置（包含当前剪辑、音轨混音与马赛克效果）"
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
                Text("可用 I / O 键或拖动蓝色分割点确定选区，按 S 在播放头分割；删除范围会自动波纹收拢后续片段，并在左侧轨道头独立调节音轨静音与音量。")
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

private struct TrackStructureKey: Equatable {
    let id: UUID
    let kind: TrackKind
    let clips: [TimelineClip]
}

private struct TrackAudioMixKey: Equatable {
    let id: UUID
    let isMuted: Bool
    let volume: Float
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

            transportBar
                .padding(.horizontal, 22)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.035))
    }

    private var transportBar: some View {
        HStack(spacing: 8) {
            Button {
                playback.skip(by: -5)
            } label: {
                Image(systemName: "gobackward.5")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .help("后退 5 秒 (⇧←)")
            .disabled(!playback.hasContent)

            Button(action: playback.togglePlayback) {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor, in: Circle())
            }
            .buttonStyle(.plain)
            .help(playback.isPlaying ? "暂停 (空格)" : "播放 (空格)")
            .disabled(!playback.hasContent)

            Button {
                playback.skip(by: 5)
            } label: {
                Image(systemName: "goforward.5")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .help("前进 5 秒 (⇧→)")
            .disabled(!playback.hasContent)

            Text("\(playback.currentTime.formattedDuration) / \(playback.duration.formattedDuration)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)

            Spacer(minLength: 6)

            Button("起点") {
                session.setRangeStart(to: MediaTime(seconds: playback.currentTime))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!playback.hasContent)
            .help("将前分割点设为当前播放头 (I)")

            Button("终点") {
                session.setRangeEnd(to: MediaTime(seconds: playback.currentTime))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!playback.hasContent)
            .help("将后分割点设为当前播放头 (O)")

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

            Button("分割") {
                session.splitAtPlayhead(MediaTime(seconds: playback.currentTime))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("b", modifiers: [.command])
            .disabled(!session.canSplit(at: MediaTime(seconds: playback.currentTime)))
            .help("在当前播放头处分割片段 (S / ⌘B)")

            Button("按选区切分") {
                session.splitAtRangeMarkers()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!session.hasInteriorSplitMarkers)
            .help("按进度条上的前/后分割点将片段切分开")

            Button("删除范围", role: .destructive) {
                if let jumpTime = session.deleteSelectedRange() {
                    playback.seek(to: jumpTime.seconds)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!session.hasSelectedRange)
            .help("波纹删除前/后分割点之间的内容并自动收拢后续片段")

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
            .keyboardShortcut("z", modifiers: [.command])
            .disabled(!session.canUndo)
            .help("撤销上一步操作 (⌘Z)")

            Button("重做") {
                session.redo()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!session.canRedo)
            .help("重做已撤销的操作 (⇧⌘Z)")
        }
    }

    private var rangeSummary: String {
        "\(session.rangeStart.seconds.formattedDuration)–\(session.rangeEnd.seconds.formattedDuration)"
    }
}

private enum ExportAlert {
    case completed(URL)
    case failed(String)
}
