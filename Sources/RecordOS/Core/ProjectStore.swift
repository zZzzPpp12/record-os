import AVFoundation
import Foundation

@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [ProjectDocument] = []
    @Published private(set) var rootURL: URL

    private let fileManager: FileManager
    private static let storageRootDefaultsKey = "RecordOS.StorageRootPath.v1"

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let defaultRoot = Self.defaultRootURL(fileManager: fileManager)
        var root = defaultRoot
        if let savedPath = UserDefaults.standard.string(forKey: Self.storageRootDefaultsKey),
           !savedPath.isEmpty {
            let candidate = URL(fileURLWithPath: savedPath, isDirectory: true)
            if fileManager.fileExists(atPath: candidate.path) {
                root = candidate
            }
        }
        rootURL = root
        let projectsDirectory = root.appendingPathComponent("Projects", isDirectory: true)
        try? fileManager.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
        reload()
    }

    static func defaultRootURL(fileManager: FileManager = .default) -> URL {
        let supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return supportURL.appendingPathComponent("RecordOS", isDirectory: true)
    }

    var projectsDirectoryURL: URL {
        rootURL.appendingPathComponent("Projects", isDirectory: true)
    }

    func changeStorageRoot(to url: URL, migrateExisting: Bool) throws {
        let newRoot = url.standardizedFileURL
        guard newRoot.path != rootURL.standardizedFileURL.path else { return }

        let newProjects = newRoot.appendingPathComponent("Projects", isDirectory: true)
        let oldProjects = projectsDirectoryURL

        if migrateExisting {
            for project in projects {
                let destination = newProjects.appendingPathComponent(project.id.uuidString, isDirectory: true)
                if fileManager.fileExists(atPath: destination.path) {
                    throw ProjectStoreError.destinationOccupied(project.name)
                }
            }
        }

        try fileManager.createDirectory(at: newProjects, withIntermediateDirectories: true)

        if migrateExisting {
            var movedPairs: [(source: URL, destination: URL)] = []
            do {
                for project in projects {
                    let source = oldProjects.appendingPathComponent(project.id.uuidString, isDirectory: true)
                    guard fileManager.fileExists(atPath: source.path) else { continue }
                    let destination = newProjects.appendingPathComponent(project.id.uuidString, isDirectory: true)
                    try fileManager.moveItem(at: source, to: destination)
                    movedPairs.append((source, destination))
                }
            } catch {
                for pair in movedPairs.reversed() {
                    try? fileManager.moveItem(at: pair.destination, to: pair.source)
                }
                throw error
            }
        }

        rootURL = newRoot
        UserDefaults.standard.set(newRoot.path, forKey: Self.storageRootDefaultsKey)
        reload()
    }

    func reload() {
        guard let folders = try? fileManager.contentsOfDirectory(
            at: projectsDirectoryURL,
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
        projectsDirectoryURL.appendingPathComponent(projectID.uuidString, isDirectory: true)
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

    func renameProject(_ project: ProjectDocument, to newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != project.name else { return }
        var updated = project
        updated.name = trimmed
        try save(updated)
    }

    func deleteProject(_ project: ProjectDocument) throws {
        let folder = projectFolder(for: project.id)
        if fileManager.fileExists(atPath: folder.path) {
            try fileManager.removeItem(at: folder)
        }
        projects.removeAll(where: { $0.id == project.id })
    }

    func importRecording(at sourceURL: URL, audioTrackNames: [String] = []) async throws -> ProjectDocument {
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
        for index in audioTracks.indices {
            let trackName = audioTrackNames.indices.contains(index)
                ? audioTrackNames[index]
                : "音频 \(index + 1)"
            tracks.append(TimelineTrack(
                id: UUID(),
                kind: .audio,
                name: trackName,
                clips: [TimelineClip(
                    id: UUID(),
                    assetID: assetID,
                    timelineStart: .zero,
                    sourceStart: .zero,
                    duration: clipDuration,
                    sourceTrackIndex: index
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

enum ProjectStoreError: LocalizedError {
    case destinationOccupied(String)

    var errorDescription: String? {
        switch self {
        case .destinationOccupied(let name):
            "目标位置已存在名为「\(name)」的项目文件夹，请选择其他文件夹。"
        }
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
