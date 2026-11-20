import AVFoundation
import Foundation

@MainActor
final class ProjectExporter: ObservableObject {
    @Published private(set) var isExporting = false
    @Published private(set) var progress: Double = 0

    var progressPercent: Int { Int((progress * 100).rounded()) }

    func export(
        project: ProjectDocument,
        to destinationURL: URL,
        urlFor: (MediaAsset) -> URL?
    ) async -> ExportOutcome {
        guard !isExporting else { return .failure("已有导出任务在进行中。") }
        isExporting = true
        progress = 0
        defer { isExporting = false }

        do {
            guard let built = await ProjectCompositionBuilder.makeComposition(
                project: project,
                urlFor: urlFor
            ) else {
                throw ProjectExportError.emptyTimeline
            }
            let composition = built.composition
            guard let renderInfo = await VideoMosaicCompositor.renderInfo(
                for: composition,
                frameRate: project.frameRate
            ) else {
                throw ProjectExportError.noVideoTrack
            }
            // The same mosaic compositor used for preview is attached to the
            // export session, so redactions are burned into the exported file.
            let videoComposition = await VideoMosaicCompositor.makeVideoComposition(
                for: composition,
                mosaicRegions: project.mosaicRegions,
                renderInfo: renderInfo
            )

            try? FileManager.default.removeItem(at: destinationURL)

            guard let session = AVAssetExportSession(
                asset: composition,
                presetName: AVAssetExportPresetHighestQuality
            ) else {
                throw ProjectExportError.sessionUnavailable
            }
            session.videoComposition = videoComposition
            session.audioMix = built.audioMix

            let monitor = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.progress = Double(session.progress)
                    try? await Task.sleep(for: .milliseconds(120))
                }
            }
            defer { monitor.cancel() }

            try await session.export(to: destinationURL, as: .mov)

            progress = 1
            return .success(destinationURL)
        } catch {
            return .failure("导出失败：\(error.localizedDescription)")
        }
    }
}

enum ExportOutcome {
    case success(URL)
    case failure(String)
}

enum ProjectExportError: LocalizedError {
    case emptyTimeline
    case noVideoTrack
    case sessionUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyTimeline:
            "时间线为空，没有可导出的视频内容。"
        case .noVideoTrack:
            "找不到视频轨道，无法导出。"
        case .sessionUnavailable:
            "无法创建导出会话，请重试。"
        }
    }
}
