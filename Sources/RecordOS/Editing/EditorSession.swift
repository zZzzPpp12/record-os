import Foundation
import SwiftUI

@MainActor
final class EditorSession: ObservableObject, Identifiable {
    @Published private(set) var project: ProjectDocument
    @Published var playhead = MediaTime.zero
    @Published var selectedClipID: UUID?
    @Published private(set) var errorMessage: String?

    let id: UUID
    private let store: ProjectStore
    private var undoStack: [ProjectDocument] = []

    init(project: ProjectDocument, store: ProjectStore) {
        self.project = project
        self.id = project.id
        self.store = store
        self.selectedClipID = project.tracks.first(where: { $0.kind == .video })?.clips.first?.id
    }

    var selectedAsset: MediaAsset? {
        guard let selectedClipID,
              let clip = project.tracks.flatMap(\.clips).first(where: { $0.id == selectedClipID }) else { return nil }
        return project.assets.first(where: { $0.id == clip.assetID })
    }

    var canUndo: Bool { !undoStack.isEmpty }

    func splitAtPlayhead() {
        guard let selectedClipID else { return }
        guard let selectedClip = project.tracks.flatMap(\.clips).first(where: { $0.id == selectedClipID }) else { return }
        let selectedAssetID = selectedClip.assetID
        var next = project
        var didSplit = false
        var newSelection: UUID?

        for trackIndex in next.tracks.indices {
            guard let clipIndex = next.tracks[trackIndex].clips.firstIndex(where: {
                $0.assetID == selectedAssetID && $0.timelineStart < playhead && playhead < $0.timelineEnd
            }) else {
                continue
            }
            let clip = next.tracks[trackIndex].clips[clipIndex]
            let offset = playhead - clip.timelineStart
            guard offset > .zero, offset < clip.duration else { continue }

            var tail = clip
            tail.id = UUID()
            tail.timelineStart = playhead
            tail.sourceStart = tail.sourceStart + offset
            tail.duration = clip.duration - offset
            next.tracks[trackIndex].clips[clipIndex].duration = offset
            next.tracks[trackIndex].clips.insert(tail, at: clipIndex + 1)
            if next.tracks[trackIndex].kind == .video {
                newSelection = tail.id
            }
            didSplit = true
        }

        guard didSplit else {
            errorMessage = "把播放头移到片段中间后再分割。"
            return
        }
        commit(next)
        self.selectedClipID = newSelection ?? self.selectedClipID
    }

    func deleteSelectedClip() {
        guard let selectedClipID else { return }
        var next = project
        for index in next.tracks.indices {
            next.tracks[index].clips.removeAll(where: { $0.id == selectedClipID })
        }
        commit(next)
        self.selectedClipID = next.tracks.first(where: { $0.kind == .video })?.clips.first?.id
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        project = previous
        selectedClipID = previous.tracks.first(where: { $0.kind == .video })?.clips.first?.id
        persist()
    }

    func clearError() {
        errorMessage = nil
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
}
