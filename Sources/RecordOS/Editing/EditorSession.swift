import Foundation
import SwiftUI

@MainActor
final class EditorSession: ObservableObject, Identifiable {
    @Published private(set) var project: ProjectDocument
    @Published var playhead = MediaTime.zero
    @Published var selectedClipID: UUID?
    @Published var selectedMosaicID: UUID?
    @Published var isMosaicDrawMode = false
    @Published var rangeStart = MediaTime.zero
    @Published var rangeEnd = MediaTime.zero
    @Published private(set) var errorMessage: String?

    let id: UUID
    private let store: ProjectStore
    private var undoStack: [ProjectDocument] = []

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

    var hasSelectedRange: Bool { rangeEnd > rangeStart }

    var hasInteriorSplitMarkers: Bool {
        let points = [rangeStart, rangeEnd]
        return project.tracks.contains { track in
            track.clips.contains { clip in
                points.contains { $0 > clip.timelineStart && $0 < clip.timelineEnd }
            }
        }
    }

    var selectedRangeLength: MediaTime { rangeEnd - rangeStart }

    var selectedMosaic: MosaicRegion? {
        guard let selectedMosaicID else { return nil }
        return project.mosaicRegions.first(where: { $0.id == selectedMosaicID })
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
        }
    }

    func beginMosaicUndoCheckpoint() {
        if undoStack.last != project {
            undoStack.append(project)
        }
    }

    func endMosaicEditSession() {
        // Drop a no-op checkpoint if the gesture ended without changing anything.
        if undoStack.last == project, !undoStack.isEmpty {
            undoStack.removeLast()
        }
        persist()
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

    func deleteSelectedRange() {
        guard hasSelectedRange else {
            errorMessage = "请先拖动两个游标选择要删除的范围。"
            return
        }

        var next = project
        for index in next.tracks.indices {
            next.tracks[index].clips = Self.clipsByRemoving(
                rangeStart: rangeStart,
                rangeEnd: rangeEnd,
                from: next.tracks[index].clips
            )
        }
        next.mosaicRegions = Self.mosaicsByRemoving(
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            from: next.mosaicRegions
        )
        guard next.tracks != project.tracks || next.mosaicRegions != project.mosaicRegions else {
            errorMessage = "所选范围内没有可删除的内容。"
            return
        }

        commit(next)
        resetRange()
        refreshSelection()
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
        refreshSelection()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        project = previous
        persist()
        resetRange()
        refreshSelection()
    }

    func clearError() {
        errorMessage = nil
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

    private func resetRange() {
        rangeStart = .zero
        rangeEnd = project.duration
    }

    private func refreshSelection() {
        selectedClipID = project.tracks.first(where: { $0.kind == .video })?.clips.first?.id
        if let currentMosaic = selectedMosaicID,
           !project.mosaicRegions.contains(where: { $0.id == currentMosaic }) {
            selectedMosaicID = project.mosaicRegions.first?.id
        } else if selectedMosaicID == nil {
            selectedMosaicID = project.mosaicRegions.first?.id
        }
    }

    private func commit(_ updated: ProjectDocument) {
        undoStack.append(project)
        project = updated
        persist()
    }

    private func persist() {
        do {
            try store.save(project)
        } catch {
            errorMessage = "保存项目失败：\(error.localizedDescription)"
        }
    }

    private static func clipsByRemoving(
        rangeStart: MediaTime,
        rangeEnd: MediaTime,
        from clips: [TimelineClip]
    ) -> [TimelineClip] {
        var result: [TimelineClip] = []
        for clip in clips {
            let clipStart = clip.timelineStart
            let clipEnd = clip.timelineEnd

            if clipEnd <= rangeStart || clipStart >= rangeEnd {
                result.append(clip)
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
                tail.timelineStart = rangeEnd
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
                tail.timelineStart = rangeEnd
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
        from regions: [MosaicRegion]
    ) -> [MosaicRegion] {
        var result: [MosaicRegion] = []
        for region in regions {
            if region.endTime <= rangeStart || region.startTime >= rangeEnd {
                result.append(region)
                continue
            }

            let trimsLeft = region.startTime < rangeStart
            let trimsRight = region.endTime > rangeEnd

            if trimsLeft && trimsRight {
                var head = region
                head.endTime = rangeStart
                result.append(head)

                var tail = region
                tail.id = UUID()
                tail.startTime = rangeEnd
                result.append(tail)
            } else if trimsLeft {
                var head = region
                head.endTime = rangeStart
                result.append(head)
            } else if trimsRight {
                var tail = region
                tail.id = UUID()
                tail.startTime = rangeEnd
                result.append(tail)
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
