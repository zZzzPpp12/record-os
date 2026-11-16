import AVFoundation
import Foundation

@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [ProjectDocument] = []

    private let fileManager: FileManager
    private let rootURL: URL
    private let projectsURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        rootURL = supportURL.appendingPathComponent("RecordOS", isDirectory: true)
        projectsURL = rootURL.appendingPathComponent("Projects", isDirectory: true)
        try? fileManager.createDirectory(at: projectsURL, withIntermediateDirectories: true)
        reload()
    }

    var projectsDirectoryURL: URL { projectsURL }

    func reload() {
        guard let folders = try? fileManager.contentsOfDirectory(
            at: projectsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            projects = []
            return
        }

        projects = folders.compactMap { folder in
            let fileURL = folder.appendingPathComponent("project.json")
            guard let data = try? Data(contentsOf: fileURL),
                  let project = try? JSONDecoder.recordOS.decode(ProjectDocument.self, from: data) else {
                return nil
            }
            return project
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    func projectFolder(for projectID: UUID) -> URL {
        projectsURL.appendingPathComponent(projectID.uuidString, isDirectory: true)
    }

    func mediaURL(for asset: MediaAsset, in project: ProjectDocument) -> URL {
        projectFolder(for: project.id).appendingPathComponent(asset.relativePath)
    }

    func save(_ project: ProjectDocument) throws {
        var updated = project
        updated.updatedAt = .now
        let folder = projectFolder(for: updated.id)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONEncoder.recordOS.encode(updated)
        try data.write(to: folder.appendingPathComponent("project.json"), options: .atomic)
        if let index = projects.firstIndex(where: { $0.id == updated.id }) {
            projects[index] = updated
        } else {
            projects.append(updated)
        }
        projects.sort { $0.updatedAt > $1.updatedAt }
    }

    func importRecording(at sourceURL: URL) async throws -> ProjectDocument {
        let id = UUID()
        let projectName = "录制 \(Date.now.formatted(date: .numeric, time: .shortened))"
        let folder = projectFolder(for: id)
        let mediaFolder = folder.appendingPathComponent("Media", isDirectory: true)
        try fileManager.createDirectory(at: mediaFolder, withIntermediateDirectories: true)

        let destinationURL = mediaFolder.appendingPathComponent("Screen Recording.mov")
        try fileManager.moveItem(at: sourceURL, to: destinationURL)

        let assetReader = AVURLAsset(url: destinationURL)
        let duration = (try? await assetReader.load(.duration)) ?? .zero
        let audioTracks = (try? await assetReader.loadTracks(withMediaType: .audio)) ?? []
        let videoTracks = (try? await assetReader.loadTracks(withMediaType: .video)) ?? []
        var canvasWidth = 1920
        var canvasHeight = 1080
        if let videoTrack = videoTracks.first,
           let naturalSize = try? await videoTrack.load(.naturalSize) {
            canvasWidth = max(1, Int(abs(naturalSize.width)))
            canvasHeight = max(1, Int(abs(naturalSize.height)))
        }
        let assetID = UUID()
        let clipDuration = MediaTime.from(duration)
        let videoClip = TimelineClip(
            id: UUID(),
            assetID: assetID,
            timelineStart: .zero,
            sourceStart: .zero,
            duration: clipDuration
        )
        let mediaAsset = MediaAsset(
            id: assetID,
            displayName: "屏幕录制",
            relativePath: "Media/Screen Recording.mov",
            duration: clipDuration,
            hasAudio: !audioTracks.isEmpty
        )
        var tracks = [
            TimelineTrack(id: UUID(), kind: .video, name: "视频 1", clips: [videoClip])
        ]
        if !audioTracks.isEmpty {
            tracks.append(TimelineTrack(
                id: UUID(),
                kind: .audio,
                name: "音频 1",
                clips: [TimelineClip(
                    id: UUID(),
                    assetID: assetID,
                    timelineStart: .zero,
                    sourceStart: .zero,
                    duration: clipDuration
                )]
            ))
        }

        let project = ProjectDocument(
            id: id,
            version: ProjectDocument.currentVersion,
            name: projectName,
            createdAt: .now,
            updatedAt: .now,
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight,
            frameRate: 30,
            assets: [mediaAsset],
            tracks: tracks
        )
        try save(project)
        return projects.first(where: { $0.id == project.id }) ?? project
    }
}

private extension JSONEncoder {
    static var recordOS: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var recordOS: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
