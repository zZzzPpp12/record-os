import SwiftUI

struct EditorTimelineView: View {
    @ObservedObject var session: EditorSession
    let playback: EditorPlaybackModel

    @State private var pixelsPerSecond: Double = 36
    @State private var availableCanvasWidth: CGFloat = 680

    private let leftHeaderWidth: CGFloat = 196
    private let rulerHeight: CGFloat = 24
    private let videoRowHeight: CGFloat = 34
    private let audioRowHeight: CGFloat = 46
    private let mosaicRowHeight: CGFloat = 30
    private let rowSpacing: CGFloat = 6

    private var timelineDuration: Double {
        max(session.project.duration.seconds, playback.duration, 0.1)
    }

    private var canvasWidth: CGFloat {
        max(availableCanvasWidth, CGFloat(timelineDuration * pixelsPerSecond) + 48)
    }

    private var tracksTotalHeight: CGFloat {
        let trackSum = session.project.tracks.reduce(CGFloat.zero) { total, track in
            total + rowHeight(for: track) + rowSpacing
        }
        let mosaicHeight = session.project.mosaicRegions.isEmpty ? 0 : (mosaicRowHeight + rowSpacing)
        return rulerHeight + rowSpacing + trackSum + mosaicHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            timelineToolbar
            timelineGrid
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(height: containerHeight)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
    }

    private var containerHeight: CGFloat {
        let trackRows = session.project.tracks.reduce(CGFloat.zero) { $0 + rowHeight(for: $1) + rowSpacing }
        let mosaicRows = session.project.mosaicRegions.isEmpty ? 0 : (mosaicRowHeight + rowSpacing)
        let ideal = rulerHeight + rowSpacing + trackRows + mosaicRows + 56
        return min(290, max(168, ideal))
    }

    private var timelineToolbar: some View {
        HStack(spacing: 10) {
            Text("时间线")
                .font(.subheadline.weight(.semibold))

            Text("空格 播放 · S 分割 · I/O 选区 · ⌫ 波纹删除 · ⌘Z/⇧⌘Z 撤销重做")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            HStack(spacing: 6) {
                Button {
                    pixelsPerSecond = max(8, pixelsPerSecond / 1.35)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("缩小时间线")

                Slider(value: $pixelsPerSecond, in: 8...200)
                    .frame(width: 96)
                    .help("拖动缩放时间线")

                Button {
                    pixelsPerSecond = min(200, pixelsPerSecond * 1.35)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("放大时间线")

                Button("适应窗口") {
                    fitToWindow()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("自动缩放时间线以完整显示全片")
            }
        }
    }

    private var timelineGrid: some View {
        GeometryReader { outerGeo in
            let measuredCanvas = max(240, outerGeo.size.width - leftHeaderWidth - 1)
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    leftHeadersColumn
                        .frame(width: leftHeaderWidth, alignment: .topLeading)

                    Divider()

                    ScrollView(.horizontal) {
                        ZStack(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: rowSpacing) {
                                TimelineRulerView(
                                    duration: timelineDuration,
                                    pixelsPerSecond: pixelsPerSecond,
                                    canvasWidth: canvasWidth,
                                    height: rulerHeight,
                                    onScrub: { seconds in
                                        playback.seek(to: seconds)
                                    },
                                    onScrubStateChanged: { editing in
                                        playback.setScrubbing(editing)
                                    }
                                )

                                ForEach(session.project.tracks) { track in
                                    TimelineTrackLaneView(
                                        track: track,
                                        selectedClipID: session.selectedClipID,
                                        pixelsPerSecond: pixelsPerSecond,
                                        canvasWidth: canvasWidth,
                                        rowHeight: rowHeight(for: track),
                                        canSplitAtPlayhead: session.canSplit(at: MediaTime(seconds: playback.currentTime)),
                                        onSelectClip: { clip in
                                            session.selectClip(id: clip.id)
                                            playback.seek(to: clip.timelineStart.seconds)
                                        },
                                        onRippleDeleteClip: { clip in
                                            if let jumpTime = session.rippleDeleteTimeRange(start: clip.timelineStart, end: clip.timelineEnd) {
                                                playback.seek(to: jumpTime.seconds)
                                            }
                                        },
                                        onRemoveSingleClip: { clip in
                                            session.removeSingleClip(trackID: track.id, clipID: clip.id)
                                        },
                                        onSplitAtPlayhead: {
                                            session.splitAtPlayhead(MediaTime(seconds: playback.currentTime))
                                        }
                                    )
                                }

                                if !session.project.mosaicRegions.isEmpty {
                                    TimelineMosaicLaneView(
                                        regions: session.project.mosaicRegions,
                                        selectedMosaicID: session.selectedMosaicID,
                                        pixelsPerSecond: pixelsPerSecond,
                                        canvasWidth: canvasWidth,
                                        rowHeight: mosaicRowHeight,
                                        onSelectRegion: { region in
                                            session.selectedMosaicID = region.id
                                            session.rangeStart = region.startTime
                                            session.rangeEnd = region.endTime
                                            playback.seek(to: region.startTime.seconds)
                                        }
                                    )
                                }
                            }

                            rangeHighlightOverlay
                            playheadOverlay
                        }
                        .frame(width: canvasWidth, alignment: .leading)
                        .coordinateSpace(name: "timelineCanvas")
                    }
                }
            }
            .onAppear {
                availableCanvasWidth = measuredCanvas
                fitToWindow(for: measuredCanvas)
            }
            .onChange(of: measuredCanvas) { _, newWidth in
                availableCanvasWidth = newWidth
            }
        }
    }

    private var leftHeadersColumn: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            HStack {
                Text("轨道")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(playback.currentTime.formattedDuration)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: rulerHeight)

            ForEach(session.project.tracks) { track in
                TimelineTrackHeaderRow(
                    track: track,
                    height: rowHeight(for: track),
                    onToggleMute: {
                        session.toggleTrackMute(trackID: track.id)
                    },
                    onBeginVolumeEdit: {
                        session.beginTrackVolumeCheckpoint()
                    },
                    onUpdateVolume: { volume in
                        session.updateTrackVolume(trackID: track.id, volume: volume, recordUndo: false)
                    },
                    onEndVolumeEdit: {
                        session.endTrackVolumeEditSession()
                    }
                )
            }

            if !session.project.mosaicRegions.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkerboard.rectangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("打码")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .frame(height: mosaicRowHeight)
            }
        }
        .padding(.trailing, 8)
    }

    @ViewBuilder
    private var rangeHighlightOverlay: some View {
        if session.hasPartialSelectedRange {
            let startX = CGFloat(session.rangeStart.seconds * pixelsPerSecond)
            let endX = CGFloat(session.rangeEnd.seconds * pixelsPerSecond)
            let width = max(2, endX - startX)
            Rectangle()
                .fill(Color.accentColor.opacity(0.09))
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.accentColor.opacity(0.6)).frame(width: 1)
                }
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Color.accentColor.opacity(0.6)).frame(width: 1)
                }
                .frame(width: width, height: max(40, tracksTotalHeight - rulerHeight))
                .offset(x: startX, y: rulerHeight)
                .allowsHitTesting(false)
        }
    }

    private var playheadOverlay: some View {
        let playheadX = CGFloat(min(max(0, playback.currentTime), timelineDuration) * pixelsPerSecond)
        return ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.red)
                .frame(width: 1.5, height: max(40, tracksTotalHeight))
                .allowsHitTesting(false)

            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .frame(width: 18, height: rulerHeight, alignment: .top)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("timelineCanvas"))
                        .onChanged { value in
                            playback.setScrubbing(true)
                            let target = min(max(0, Double(value.location.x) / max(pixelsPerSecond, 1)), timelineDuration)
                            playback.seek(to: target)
                        }
                        .onEnded { _ in
                            playback.setScrubbing(false)
                        }
                )
                .help("拖动播放头")
        }
        .frame(width: 18, height: max(40, tracksTotalHeight), alignment: .top)
        .offset(x: playheadX - 9, y: 0)
    }

    private func rowHeight(for track: TimelineTrack) -> CGFloat {
        track.kind == .audio ? audioRowHeight : videoRowHeight
    }

    private func fitToWindow(for widthOverride: CGFloat? = nil) {
        let targetWidth = max(120, (widthOverride ?? availableCanvasWidth) - 48)
        let ideal = Double(targetWidth) / max(timelineDuration, 0.5)
        pixelsPerSecond = min(max(ideal, 8), 200)
    }
}

private struct TimelineTrackHeaderRow: View {
    let track: TimelineTrack
    let height: CGFloat
    let onToggleMute: () -> Void
    let onBeginVolumeEdit: () -> Void
    let onUpdateVolume: (Float) -> Void
    let onEndVolumeEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: track.kind == .video ? "film" : "waveform")
                    .font(.caption2)
                    .foregroundStyle(track.kind == .audio && track.isMuted ? .orange : .secondary)

                Text(track.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(track.kind == .audio && track.isMuted ? .secondary : .primary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if track.kind == .audio {
                    Button(action: onToggleMute) {
                        Image(systemName: track.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.caption2)
                            .foregroundStyle(track.isMuted ? Color.orange : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(track.isMuted ? "取消静音" : "静音此音轨")
                } else {
                    Text("\(track.clips.count) 段")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            if track.kind == .audio {
                HStack(spacing: 6) {
                    Slider(
                        value: Binding(
                            get: { Double(track.volume) },
                            set: { newValue in
                                onUpdateVolume(Float(newValue))
                            }
                        ),
                        in: 0...2,
                        step: 0.05,
                        onEditingChanged: { editing in
                            if editing {
                                onBeginVolumeEdit()
                            } else {
                                onEndVolumeEdit()
                            }
                        }
                    )
                    .controlSize(.mini)
                    .opacity(track.isMuted ? 0.55 : 1)

                    Text("\(Int((track.isMuted ? 0 : track.volume * 100).rounded()))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(height: height, alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

private struct TimelineRulerView: View {
    let duration: Double
    let pixelsPerSecond: Double
    let canvasWidth: CGFloat
    let height: CGFloat
    let onScrub: (Double) -> Void
    let onScrubStateChanged: (Bool) -> Void

    var body: some View {
        Canvas { context, size in
            let majorStep = chooseMajorStep(pixelsPerSecond: pixelsPerSecond)
            let minorCount = 5
            let minorStep = majorStep / Double(minorCount)
            let drawMinor = minorStep * pixelsPerSecond >= 8

            let baseline = Path { path in
                path.move(to: CGPoint(x: 0, y: size.height - 0.5))
                path.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            }
            context.stroke(baseline, with: .color(.secondary.opacity(0.25)), lineWidth: 1)

            let maxTickTime = max(duration, Double(size.width) / max(pixelsPerSecond, 1))
            var index = 0
            while true {
                let tickTime = Double(index) * minorStep
                if tickTime > maxTickTime { break }
                let x = CGFloat(tickTime * pixelsPerSecond)
                let isMajor = index % minorCount == 0

                if isMajor {
                    let tickPath = Path { path in
                        path.move(to: CGPoint(x: x, y: size.height - 10))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    context.stroke(tickPath, with: .color(.secondary.opacity(0.55)), lineWidth: 1)

                    let label = Text(tickTime.formattedDuration)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    context.draw(label, at: CGPoint(x: x + 4, y: 7), anchor: .topLeading)
                } else if drawMinor {
                    let tickPath = Path { path in
                        path.move(to: CGPoint(x: x, y: size.height - 5))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    context.stroke(tickPath, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
                }
                index += 1
            }
        }
        .frame(width: canvasWidth, height: height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("timelineCanvas"))
                .onChanged { value in
                    onScrubStateChanged(true)
                    let target = min(max(0, Double(value.location.x) / max(pixelsPerSecond, 1)), duration)
                    onScrub(target)
                }
                .onEnded { _ in
                    onScrubStateChanged(false)
                }
        )
        .help("点击或拖动标尺定位播放头")
    }

    private func chooseMajorStep(pixelsPerSecond: Double) -> Double {
        let candidates: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        for step in candidates where step * pixelsPerSecond >= 68 {
            return step
        }
        return 300
    }
}

private struct TimelineTrackLaneView: View {
    let track: TimelineTrack
    let selectedClipID: UUID?
    let pixelsPerSecond: Double
    let canvasWidth: CGFloat
    let rowHeight: CGFloat
    let canSplitAtPlayhead: Bool
    let onSelectClip: (TimelineClip) -> Void
    let onRippleDeleteClip: (TimelineClip) -> Void
    let onRemoveSingleClip: (TimelineClip) -> Void
    let onSplitAtPlayhead: () -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
                .frame(width: canvasWidth, height: rowHeight)

            ForEach(track.clips) { clip in
                let x = CGFloat(clip.timelineStart.seconds * pixelsPerSecond)
                let width = max(6, CGFloat(clip.duration.seconds * pixelsPerSecond))
                let isSelected = selectedClipID == clip.id
                let baseColor: Color = track.kind == .audio ? .teal : .accentColor
                let fillOpacity: Double = {
                    if track.kind == .audio && track.isMuted {
                        return isSelected ? 0.36 : 0.2
                    }
                    return isSelected ? 0.92 : 0.52
                }()

                Button {
                    onSelectClip(clip)
                } label: {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(baseColor.opacity(fillOpacity))
                        .frame(width: width, height: rowHeight - 6)
                        .overlay(alignment: .leading) {
                            if width >= 54 {
                                HStack(spacing: 4) {
                                    Text(track.kind == .audio ? track.name : "屏幕录制")
                                        .font(.caption2.weight(.medium))
                                        .lineLimit(1)
                                    if track.kind == .audio && track.isMuted {
                                        Text("已静音")
                                            .font(.system(size: 10))
                                            .opacity(0.85)
                                    } else if width >= 115 {
                                        Text(clip.duration.seconds.formattedDuration)
                                            .font(.system(size: 10, design: .monospaced))
                                            .opacity(0.85)
                                    }
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                            }
                        }
                        .overlay {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(Color.white.opacity(0.92), lineWidth: 1.8)
                            }
                        }
                }
                .buttonStyle(.plain)
                .offset(x: x)
                .contextMenu {
                    Button("在播放头分割 (S)", action: onSplitAtPlayhead)
                        .disabled(!canSplitAtPlayhead)
                    Button("波纹删除此片段时段", role: .destructive) {
                        onRippleDeleteClip(clip)
                    }
                    if track.kind == .audio {
                        Button("仅移除此音轨片段（保留画面）", role: .destructive) {
                            onRemoveSingleClip(clip)
                        }
                    }
                    if track.kind == .video && track.clips.count > 1 {
                        Button("仅移除此画面片段（不偏移音轨）", role: .destructive) {
                            onRemoveSingleClip(clip)
                        }
                    }
                }
                .help("\(track.kind == .audio ? track.name : "屏幕录制")：\(clip.timelineStart.seconds.formattedDuration) – \(clip.timelineEnd.seconds.formattedDuration)（时长 \(clip.duration.seconds.formattedDuration)）")
            }
        }
        .frame(width: canvasWidth, height: rowHeight, alignment: .leading)
    }
}

private struct TimelineMosaicLaneView: View {
    let regions: [MosaicRegion]
    let selectedMosaicID: UUID?
    let pixelsPerSecond: Double
    let canvasWidth: CGFloat
    let rowHeight: CGFloat
    let onSelectRegion: (MosaicRegion) -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
                .frame(width: canvasWidth, height: rowHeight)

            ForEach(Array(regions.enumerated()), id: \.element.id) { index, region in
                let x = CGFloat(region.startTime.seconds * pixelsPerSecond)
                let width = max(10, CGFloat(region.duration.seconds * pixelsPerSecond))
                let isSelected = selectedMosaicID == region.id

                Button {
                    onSelectRegion(region)
                } label: {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isSelected ? Color.orange : Color.orange.opacity(0.58))
                        .frame(width: width, height: rowHeight - 6)
                        .overlay(alignment: .leading) {
                            if width >= 44 {
                                Text("马赛克 \(index + 1)")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .lineLimit(1)
                            }
                        }
                        .overlay {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                            }
                        }
                }
                .buttonStyle(.plain)
                .offset(x: x)
                .help("选中马赛克 \(index + 1)（\(region.startTime.seconds.formattedDuration) – \(region.endTime.seconds.formattedDuration)）")
            }
        }
        .frame(width: canvasWidth, height: rowHeight, alignment: .leading)
    }
}
