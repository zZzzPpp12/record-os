import Foundation
import SwiftUI

@MainActor
final class EditorSession: ObservableObject, Identifiable {
    @Published private(set) var project: ProjectDocument
    @Published var selectedClipID: UUID?
    @Published var selectedMosaicID: UUID?
    @Published var isMosaicDrawMode = false
    @Published var rangeStart = MediaTime.zero
    @Published var rangeEnd = MediaTime.zero
    @Published private(set) var hasUnsavedChanges = false
    @Published private(set) var lastSavedAt: Date?
    @Published private(set) var errorMessage: String?

    let id: UUID
    private let store: ProjectStore
    private let maxHistoryCount = 50
    private var undoStack: [ProjectDocument] = []
    private var redoStack: [ProjectDocument] = []
    private var activeCheckpointProject: ProjectDocument?

    init(project: ProjectDocument, store: ProjectStore) {
        self.project = project
        self.id = project.id
        self.store = store
        self.selectedClipID = project.tracks.first(where: { $0.kind == .video })?.clips.first?.id
        self.selectedMosaicID = project.mosaicRegions.first?.id
        self.rangeStart = .zero
        self.rangeEnd = project.duration
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var hasSelectedRange: Bool { rangeEnd > rangeStart }

    var hasPartialSelectedRange: Bool {
        hasSelectedRange && (rangeStart > .zero || rangeEnd < project.duration)
    }

    var hasInteriorSplitMarkers: Bool {
        let points = [rangeStart, rangeEnd]
        return project.tracks.contains { track in
            track.clips.contains { clip in
                points.contains { $0 > clip.timelineStart && $0 < clip.timelineEnd }
            }
        }
    }

    func canSplit(at time: MediaTime) -> Bool {
        guard time > .zero && time < project.duration else { return false }
        return project.tracks.contains { track in
            track.clips.contains { clip in
                time > clip.timelineStart && time < clip.timelineEnd
            }
        }
    }

    var selectedClip: TimelineClip? {
        guard let selectedClipID else { return nil }
        for track in project.tracks {
            if let clip = track.clips.first(where: { $0.id == selectedClipID }) {
                return clip
            }
        }
        return nil
    }

    var selectedRangeLength: MediaTime { rangeEnd - rangeStart }

    var selectedMosaic: MosaicRegion? {
        guard let selectedMosaicID else { return nil }
        return project.mosaicRegions.first(where: { $0.id == selectedMosaicID })
    }

    func selectClip(id: UUID?) {
        selectedClipID = id
    }

    func setRangeStart(to time: MediaTime) {
        let duration = project.duration
        guard duration > .zero else {
            resetRange()
            return
        }
        let minGap = min(MediaTime(seconds: 0.1), duration)
        let clamped = time.clamped(min: .zero, max: max(.zero, duration - minGap))
        rangeStart = clamped
        if rangeEnd < clamped + minGap {
            rangeEnd = duration
        }
    }

    func setRangeEnd(to time: MediaTime) {
        let duration = project.duration
        guard duration > .zero else {
            resetRange()
            return
        }
        let minGap = min(MediaTime(seconds: 0.1), duration)
        let clamped = time.clamped(min: minGap, max: duration)
        rangeEnd = clamped
        if rangeStart > clamped - minGap {
            rangeStart = .zero
        }
    }

    func addMosaicRegion(rect: NormalizedRect) {
        guard hasSelectedRange else {
            errorMessage = "请先拖动前后两个分割点选择需要打码的时间段。"
            return
        }
        let clampedRect = rect.clamped()
        let region = MosaicRegion(
            startTime: rangeStart,
            endTime: rangeEnd,
            rect: clampedRect,
            pixelScale: MosaicRegion.defaultPixelScale
        )
        var next = project
        next.mosaicRegions.append(region)
        commit(next)
        selectedMosaicID = region.id
        isMosaicDrawMode = false
    }

    func updateMosaicRegion(
        id: UUID,
        rect: NormalizedRect? = nil,
        startTime: MediaTime? = nil,
        endTime: MediaTime? = nil,
        pixelScale: Double? = nil,
        recordUndo: Bool = true
    ) {
        guard let index = project.mosaicRegions.firstIndex(where: { $0.id == id }) else { return }
        var updated = project
        var region = updated.mosaicRegions[index]
        if let rect {
            region.rect = rect.clamped()
        }
        if let startTime {
            let maxStart = region.endTime - MediaTime(seconds: 0.1)
            region.startTime = min(max(.zero, startTime), max(.zero, maxStart))
        }
        if let endTime {
            let minEnd = region.startTime + MediaTime(seconds: 0.1)
            region.endTime = max(min(project.duration, endTime), min(project.duration, minEnd))
        }
        if let pixelScale {
            region.pixelScale = min(max(pixelScale, 8), 64)
        }
        guard region != updated.mosaicRegions[index] else { return }
        updated.mosaicRegions[index] = region

        if recordUndo {
            commit(updated)
        } else {
            // Interactive drag: update in memory only so we don't rewrite
            // project.json on every mouse move. The edit session persists on end.
            project = updated
            hasUnsavedChanges = true
        }
    }

    func beginMosaicUndoCheckpoint() {
        beginInteractiveCheckpoint()
    }

    func endMosaicEditSession() {
        endInteractiveCheckpoint()
    }

    func deleteMosaicRegion(id: UUID) {
        var next = project
        next.mosaicRegions.removeAll(where: { $0.id == id })
        guard next.mosaicRegions != project.mosaicRegions else { return }
        commit(next)
        if selectedMosaicID == id {
            selectedMosaicID = next.mosaicRegions.first?.id
        }
    }

    func toggleTrackMute(trackID: UUID) {
        guard let index = project.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        var next = project
        next.tracks[index].isMuted.toggle()
        commit(next)
    }

    func beginTrackVolumeCheckpoint() {
        beginInteractiveCheckpoint()
    }

    func updateTrackVolume(trackID: UUID, volume: Float, recordUndo: Bool = false) {
        guard let index = project.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        let clamped = min(max(volume.isFinite ? volume : 1.0, 0.0), 2.0)
        var next = project
        let didChangeVolume = abs(next.tracks[index].volume - clamped) > 0.001
        let shouldUnmute = next.tracks[index].isMuted && clamped > 0.001
        guard didChangeVolume || shouldUnmute else { return }
        next.tracks[index].volume = clamped
        if shouldUnmute {
            next.tracks[index].isMuted = false
        }

        if recordUndo {
            commit(next)
        } else {
            project = next
            hasUnsavedChanges = true
        }
    }

    func endTrackVolumeEditSession() {
        endInteractiveCheckpoint()
    }

    @discardableResult
    func deleteSelectedRange() -> MediaTime? {
        guard hasSelectedRange else {
            errorMessage = "请先拖动两个游标选择要删除的范围。"
            return nil
        }
        return deleteTimeRange(start: rangeStart, end: rangeEnd)
    }

    @discardableResult
    func deleteSelectedClip() -> MediaTime? {
        guard let selectedClipID else {
            errorMessage = "请先在时间线上选择一个片段。"
            return nil
        }
        for track in project.tracks {
            if let clip = track.clips.first(where: { $0.id == selectedClipID }) {
                if track.kind == .audio {
                    removeSingleClip(trackID: track.id, clipID: clip.id)
                    return nil
                }
                return deleteTimeRange(start: clip.timelineStart, end: clip.timelineEnd)
            }
        }
        errorMessage = "请先在时间线上选择一个片段。"
        return nil
    }

    func removeSingleClip(trackID: UUID, clipID: UUID) {
        guard let trackIndex = project.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        var next = project
        next.tracks[trackIndex].clips.removeAll(where: { $0.id == clipID })
        guard next.tracks != project.tracks else { return }
        commit(next)
        clampRangeToProjectDuration()
        refreshSelection()
    }

    @discardableResult
    func rippleDeleteTimeRange(start: MediaTime, end: MediaTime) -> MediaTime? {
        deleteTimeRange(start: start, end: end)
    }

    @discardableResult
    private func deleteTimeRange(start: MediaTime, end: MediaTime) -> MediaTime? {
        guard end > start else { return nil }

        var next = project
        for index in next.tracks.indices {
            next.tracks[index].clips = Self.clipsByRemoving(
                rangeStart: start,
                rangeEnd: end,
                from: next.tracks[index].clips,
                ripple: true
            )
        }
        next.mosaicRegions = Self.mosaicsByRemoving(
            rangeStart: start,
            rangeEnd: end,
            from: next.mosaicRegions,
            ripple: true
        )
        guard next.tracks != project.tracks || next.mosaicRegions != project.mosaicRegions else {
            errorMessage = "所选范围内没有可删除的内容。"
            return nil
        }

        commit(next)
        resetRange()
        selectClipNearest(to: start)
        refreshMosaicSelection()
        return min(start, project.duration)
    }

    func keepOnlySelectedRange() {
        guard hasSelectedRange else {
            errorMessage = "请先拖动两个游标选择要保留的范围。"
            return
        }

        var next = project
        for index in next.tracks.indices {
            next.tracks[index].clips = Self.clipsByKeeping(
                rangeStart: rangeStart,
                rangeEnd: rangeEnd,
                from: next.tracks[index].clips,
                shiftBy: rangeStart
            )
        }
        next.mosaicRegions = Self.mosaicsByKeeping(
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            from: next.mosaicRegions,
            shiftBy: rangeStart
        )
        guard next.tracks != project.tracks || next.mosaicRegions != project.mosaicRegions else { return }

        commit(next)
        resetRange()
        refreshSelection()
    }

    func splitAtRangeMarkers() {
        guard hasSelectedRange else {
            errorMessage = "请先拖动前后两个分割点。"
            return
        }

        let splitPoints = [rangeStart, rangeEnd]
            .filter { $0 > .zero && $0 < project.duration }
            .reduce(into: [MediaTime]()) { result, point in
                if !result.contains(point) {
                    result.append(point)
                }
            }
            .sorted()

        guard !splitPoints.isEmpty else {
            errorMessage = "把前分割点或后分割点拖到视频中间后再分割。"
            return
        }

        var next = project
        for index in next.tracks.indices {
            next.tracks[index].clips = Self.clipsBySplitting(
                at: splitPoints,
                from: next.tracks[index].clips
            )
        }
        guard next.tracks != project.tracks else {
            errorMessage = "分割点未落在片段内部。"
            return
        }

        commit(next)
        if let anchor = splitPoints.first {
            selectClipNearest(to: anchor)
        } else {
            refreshSelection()
        }
    }

    func splitAtPlayhead(_ time: MediaTime) {
        guard time > .zero && time < project.duration else {
            errorMessage = "请将播放头移动到片段内部后再分割。"
            return
        }

        var next = project
        for index in next.tracks.indices {
            next.tracks[index].clips = Self.clipsBySplitting(
                at: [time],
                from: next.tracks[index].clips
            )
        }
        guard next.tracks != project.tracks else {
            errorMessage = "当前播放头未落在任何片段内部。"
            return
        }

        commit(next)
        selectClipNearest(to: time)
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(project)
        project = previous
        persist()
        resetRange()
        refreshSelection()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        if undoStack.count > maxHistoryCount {
            undoStack.removeFirst(undoStack.count - maxHistoryCount)
        }
        project = next
        persist()
        resetRange()
        refreshSelection()
    }

    func clearError() {
        errorMessage = nil
    }

    @discardableResult
    func saveNow() -> Bool {
        if let base = activeCheckpointProject {
            activeCheckpointProject = nil
            if base != project {
                pushUndo(base)
                redoStack.removeAll()
                return persist()
            }
            hasUnsavedChanges = false
            return true
        }
        return persist()
    }

    func syncProjectMetadata(_ updated: ProjectDocument) {
        project.name = updated.name
        project.updatedAt = updated.updatedAt
        project.exports = updated.exports
    }

    /// Records an exported video file so the library can tell source media and
    /// edited output apart. This is metadata only, so it stays out of the undo stack.
    func recordExport(at url: URL) {
        var next = project
        let export = ProjectExport(
            filePath: url.path,
            fileName: url.lastPathComponent,
            duration: project.duration
        )
        next.exports.insert(export, at: 0)
        next.exports = Array(next.exports.prefix(20))
        project = next
        persist()
    }

    func removeExportRecord(id: UUID) {
        guard project.exports.contains(where: { $0.id == id }) else { return }
        var next = project
        next.exports.removeAll { $0.id == id }
        project = next
        persist()
    }

    private func beginInteractiveCheckpoint() {
        if activeCheckpointProject == nil {
            activeCheckpointProject = project
        }
    }

    private func endInteractiveCheckpoint() {
        if let base = activeCheckpointProject {
            activeCheckpointProject = nil
            if base != project {
                pushUndo(base)
                redoStack.removeAll()
                persist()
            } else {
                hasUnsavedChanges = false
            }
            return
        }
        persist()
    }

    private func pushUndo(_ snapshot: ProjectDocument) {
        undoStack.append(snapshot)
        if undoStack.count > maxHistoryCount {
            undoStack.removeFirst(undoStack.count - maxHistoryCount)
        }
    }

    private func resetRange() {
        rangeStart = .zero
        rangeEnd = project.duration
    }

    private func clampRangeToProjectDuration() {
        let duration = project.duration
        rangeStart = rangeStart.clamped(max: duration)
        rangeEnd = rangeEnd.clamped(max: duration)
        if rangeEnd < rangeStart {
            rangeStart = .zero
            rangeEnd = duration
        }
    }

    private func selectClipNearest(to time: MediaTime) {
        let preferredTracks = project.tracks.filter { $0.kind == .video } + project.tracks.filter { $0.kind != .video }
        for track in preferredTracks {
            let sorted = track.clips.sorted { $0.timelineStart < $1.timelineStart }
            if let exactOrAfter = sorted.first(where: { $0.timelineStart >= time || ($0.timelineStart <= time && $0.timelineEnd > time) }) {
                selectedClipID = exactOrAfter.id
                return
            }
            if let last = sorted.last {
                selectedClipID = last.id
                return
            }
        }
        selectedClipID = nil
    }

    private func refreshSelection() {
        let allClipIDs = Set(project.tracks.flatMap(\.clips).map(\.id))
        if let selectedClipID, allClipIDs.contains(selectedClipID) {
            // Preserve current selection if the clip still exists.
        } else {
            selectedClipID = project.tracks.first(where: { $0.kind == .video })?.clips.first?.id
                ?? project.tracks.flatMap(\.clips).first?.id
        }
        refreshMosaicSelection()
    }

    private func refreshMosaicSelection() {
        if let currentMosaic = selectedMosaicID,
           !project.mosaicRegions.contains(where: { $0.id == currentMosaic }) {
            selectedMosaicID = project.mosaicRegions.first?.id
        } else if selectedMosaicID == nil {
            selectedMosaicID = project.mosaicRegions.first?.id
        }
    }

    private func commit(_ updated: ProjectDocument) {
        pushUndo(project)
        redoStack.removeAll()
        project = updated
        persist()
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            try store.save(project)
            hasUnsavedChanges = false
            lastSavedAt = .now
            return true
        } catch {
            hasUnsavedChanges = true
            errorMessage = "保存项目失败：\(error.localizedDescription)"
            return false
        }
    }

    private static func clipsByRemoving(
        rangeStart: MediaTime,
        rangeEnd: MediaTime,
        from clips: [TimelineClip],
        ripple: Bool
    ) -> [TimelineClip] {
        let removedDuration = rangeEnd - rangeStart
        var result: [TimelineClip] = []
        for clip in clips {
            let clipStart = clip.timelineStart
            let clipEnd = clip.timelineEnd

            if clipEnd <= rangeStart {
                result.append(clip)
                continue
            }

            if clipStart >= rangeEnd {
                var kept = clip
                if ripple {
                    kept.timelineStart = (clipStart - removedDuration).clamped(max: clipStart)
                }
                result.append(kept)
                continue
            }

            let trimsLeftEdge = clipStart < rangeStart
            let trimsRightEdge = clipEnd > rangeEnd

            if trimsLeftEdge && trimsRightEdge {
                var head = clip
                head.duration = rangeStart - clipStart
                result.append(head)

                var tail = clip
                tail.id = UUID()
                tail.timelineStart = ripple ? rangeStart : rangeEnd
                tail.sourceStart = clip.sourceStart + (rangeEnd - clipStart)
                tail.duration = clipEnd - rangeEnd
                result.append(tail)
            } else if trimsLeftEdge {
                var head = clip
                head.duration = rangeStart - clipStart
                result.append(head)
            } else if trimsRightEdge {
                var tail = clip
                tail.id = UUID()
                tail.timelineStart = ripple ? rangeStart : rangeEnd
                tail.sourceStart = clip.sourceStart + (rangeEnd - clipStart)
                tail.duration = clipEnd - rangeEnd
                result.append(tail)
            }
        }
        return result
    }

    private static func clipsByKeeping(
        rangeStart: MediaTime,
        rangeEnd: MediaTime,
        from clips: [TimelineClip],
        shiftBy offset: MediaTime
    ) -> [TimelineClip] {
        var result: [TimelineClip] = []
        for clip in clips {
            let clipStart = clip.timelineStart
            let clipEnd = clip.timelineEnd

            if clipEnd <= rangeStart || clipStart >= rangeEnd {
                continue
            }

            var kept = clip
            if clipStart < rangeStart {
                let delta = rangeStart - clipStart
                kept.sourceStart = clip.sourceStart + delta
                kept.timelineStart = rangeStart
                kept.duration = min(clipEnd, rangeEnd) - rangeStart
            } else {
                kept.timelineStart = clipStart
                kept.duration = min(clipEnd, rangeEnd) - clipStart
            }

            kept.timelineStart = kept.timelineStart - offset
            if kept.duration > .zero, kept.timelineStart >= .zero {
                result.append(kept)
            }
        }
        return result
    }

    private static func clipsBySplitting(
        at splitPoints: [MediaTime],
        from clips: [TimelineClip]
    ) -> [TimelineClip] {
        var result: [TimelineClip] = []
        for clip in clips {
            let clipStart = clip.timelineStart
            let clipEnd = clip.timelineEnd
            let internalPoints = splitPoints.filter { $0 > clipStart && $0 < clipEnd }
            if internalPoints.isEmpty {
                result.append(clip)
                continue
            }

            let boundaries = [clipStart] + internalPoints + [clipEnd]
            for index in 0..<(boundaries.count - 1) {
                let segStart = boundaries[index]
                let segEnd = boundaries[index + 1]
                let segDuration = segEnd - segStart
                guard segDuration > .zero else { continue }

                var segment = clip
                if index > 0 {
                    segment.id = UUID()
                }
                segment.timelineStart = segStart
                segment.sourceStart = clip.sourceStart + (segStart - clipStart)
                segment.duration = segDuration
                result.append(segment)
            }
        }
        return result
    }

    private static func mosaicsByRemoving(
        rangeStart: MediaTime,
        rangeEnd: MediaTime,
        from regions: [MosaicRegion],
        ripple: Bool
    ) -> [MosaicRegion] {
        let removedDuration = rangeEnd - rangeStart
        var result: [MosaicRegion] = []
        for region in regions {
            if region.endTime <= rangeStart {
                result.append(region)
                continue
            }

            if region.startTime >= rangeEnd {
                var shifted = region
                if ripple {
                    shifted.startTime = (region.startTime - removedDuration).clamped(max: region.startTime)
                    shifted.endTime = (region.endTime - removedDuration).clamped(max: region.endTime)
                }
                if shifted.endTime > shifted.startTime {
                    result.append(shifted)
                }
                continue
            }

            let trimsLeft = region.startTime < rangeStart
            let trimsRight = region.endTime > rangeEnd

            if trimsLeft && trimsRight {
                if ripple {
                    let mergedEnd = (region.endTime - removedDuration).clamped(max: region.endTime)
                    if mergedEnd > region.startTime {
                        var merged = region
                        merged.endTime = mergedEnd
                        result.append(merged)
                    }
                } else {
                    var head = region
                    head.endTime = rangeStart
                    result.append(head)

                    var tail = region
                    tail.id = UUID()
                    tail.startTime = rangeEnd
                    if tail.endTime > tail.startTime {
                        result.append(tail)
                    }
                }
            } else if trimsLeft {
                var head = region
                head.endTime = rangeStart
                result.append(head)
            } else if trimsRight {
                var tail = region
                tail.id = UUID()
                tail.startTime = ripple ? rangeStart : rangeEnd
                tail.endTime = ripple ? (region.endTime - removedDuration) : region.endTime
                if tail.endTime > tail.startTime {
                    result.append(tail)
                }
            }
        }
        return result
    }

    private static func mosaicsByKeeping(
        rangeStart: MediaTime,
        rangeEnd: MediaTime,
        from regions: [MosaicRegion],
        shiftBy offset: MediaTime
    ) -> [MosaicRegion] {
        var result: [MosaicRegion] = []
        for region in regions {
            if region.endTime <= rangeStart || region.startTime >= rangeEnd {
                continue
            }
            var kept = region
            kept.startTime = max(region.startTime, rangeStart) - offset
            kept.endTime = min(region.endTime, rangeEnd) - offset
            if kept.endTime > kept.startTime {
                result.append(kept)
            }
        }
        return result
    }
}
