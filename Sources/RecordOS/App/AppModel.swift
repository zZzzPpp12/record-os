import Combine
import Foundation
import SwiftUI

enum AppRoute: String, CaseIterable, Identifiable {
    case record
    case library
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .record: "录制"
        case .library: "项目库"
        case .settings: "设置"
        }
    }

    var symbol: String {
        switch self {
        case .record: "record.circle"
        case .library: "square.stack.3d.up"
        case .settings: "gearshape"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var route: AppRoute = .record
    @Published var activeEditor: EditorSession?
    @Published var alertMessage: String?

    let projectStore: ProjectStore
    let recorder: ScreenRecorder
    let updateChecker: AppUpdateChecker

    private let menuBarIndicator = MenuBarRecordingIndicator()
    private var childObservers: Set<AnyCancellable> = []

    init() {
        projectStore = ProjectStore()
        recorder = ScreenRecorder()
        updateChecker = AppUpdateChecker()
        // Nested ObservableObjects do not forward their changes to AppModel,
        // so the views observing AppModel would never refresh. Forward them.
        projectStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &childObservers)
        recorder.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &childObservers)
        updateChecker.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &childObservers)
        recorder.$isRecording
            .removeDuplicates()
            .sink { [weak self] isRecording in
                guard let self else { return }
                if isRecording, let startedAt = self.recorder.recordingStartedAt {
                    self.menuBarIndicator.start(
                        startedAt: startedAt,
                        sourceTitle: self.recorder.activeTarget?.shortLabel
                    ) { [weak self] in
                        Task { await self?.stopRecordingFromBanner() }
                    }
                } else {
                    self.menuBarIndicator.stop()
                }
            }
            .store(in: &childObservers)
        recorder.$unexpectedFailureMessage
            .compactMap { $0 }
            .sink { [weak self] message in
                guard let self else { return }
                if self.route != .record {
                    self.alertMessage = message
                }
                _ = self.recorder.consumeUnexpectedFailure()
            }
            .store(in: &childObservers)
    }

    func openEditor(_ project: ProjectDocument) {
        activeEditor = EditorSession(project: project, store: projectStore)
        route = .library
    }

    func renameProject(_ project: ProjectDocument, to newName: String) {
        do {
            try projectStore.renameProject(project, to: newName)
            if activeEditor?.id == project.id,
               let updated = projectStore.projects.first(where: { $0.id == project.id }) {
                activeEditor?.syncProjectMetadata(updated)
            }
        } catch {
            alertMessage = "重命名项目失败：\(error.localizedDescription)"
        }
    }

    func deleteProject(_ project: ProjectDocument) {
        do {
            try projectStore.deleteProject(project)
            if activeEditor?.id == project.id {
                activeEditor = nil
            }
        } catch {
            alertMessage = "删除项目失败：\(error.localizedDescription)"
        }
    }

    func removeExportRecord(_ export: ProjectExport, from project: ProjectDocument) {
        var updated = project
        updated.exports.removeAll { $0.id == export.id }
        do {
            try projectStore.save(updated)
            activeEditor?.syncProjectMetadata(updated)
        } catch {
            alertMessage = "移除导出记录失败：\(error.localizedDescription)"
        }
    }

    func finishRecording(at url: URL, audioTrackNames: [String] = []) async {
        do {
            _ = try await projectStore.importRecording(at: url, audioTrackNames: audioTrackNames)
            activeEditor = nil
            route = .library
        } catch {
            alertMessage = "录制已完成，但创建项目失败：\(error.localizedDescription)"
        }
    }

    func stopRecordingFromBanner() async {
        do {
            let trackNames = recorder.audioTrackNames(for: recorder.activeAudioOptions)
            let url = try await recorder.stopRecording()
            await finishRecording(at: url, audioTrackNames: trackNames)
        } catch {
            alertMessage = "停止录制失败：\(error.localizedDescription)"
        }
    }
}
