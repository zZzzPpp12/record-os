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

    init() {
        projectStore = ProjectStore()
        recorder = ScreenRecorder()
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

    func finishRecording(at url: URL) async {
        do {
            _ = try await projectStore.importRecording(at: url)
            activeEditor = nil
            route = .library
        } catch {
            alertMessage = "录制已完成，但创建项目失败：\(error.localizedDescription)"
        }
    }

    func stopRecordingFromBanner() async {
        do {
            let url = try await recorder.stopRecording()
            await finishRecording(at: url)
        } catch {
            alertMessage = "停止录制失败：\(error.localizedDescription)"
        }
    }
}
