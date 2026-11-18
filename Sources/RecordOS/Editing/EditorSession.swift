import Foundation
import SwiftUI

@MainActor
final class EditorSession: ObservableObject, Identifiable {
    @Published private(set) var project: ProjectDocument
    @Published var playhead = MediaTime.zero
    @Published var selectedClipID: UUID?
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
        guard next.tracks != project.tracks else {
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
        guard next.tracks != project.tracks else { return }

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
    }

    private func resetRange() {
        rangeStart = .zero
        rangeEnd = project.duration
    }

    private func refreshSelection() {
        selectedClipID = project.tracks.first(where: { $0.kind == .video })?.clips.first?.id
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
            // Fully covered clips are dropped.
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
}
