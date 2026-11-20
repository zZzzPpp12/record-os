import Foundation
import CoreMedia

struct MediaTime: Codable, Hashable, Comparable, Sendable {
    var value: Int64
    var timescale: Int32

    static let zero = MediaTime(value: 0, timescale: 600)

    init(value: Int64, timescale: Int32) {
        self.value = value
        self.timescale = max(timescale, 1)
    }

    init(seconds: Double, timescale: Int32 = 600) {
        self.init(value: Int64((seconds * Double(timescale)).rounded()), timescale: timescale)
    }

    var seconds: Double {
        Double(value) / Double(max(timescale, 1))
    }

    var cmTime: CMTime {
        CMTime(value: value, timescale: timescale)
    }

    static func from(_ time: CMTime) -> MediaTime {
        guard time.isNumeric, time.timescale > 0 else { return .zero }
        return MediaTime(value: time.value, timescale: time.timescale)
    }

    static func < (lhs: MediaTime, rhs: MediaTime) -> Bool {
        CMTimeCompare(lhs.cmTime, rhs.cmTime) < 0
    }

    static func + (lhs: MediaTime, rhs: MediaTime) -> MediaTime {
        .from(CMTimeAdd(lhs.cmTime, rhs.cmTime))
    }

    static func - (lhs: MediaTime, rhs: MediaTime) -> MediaTime {
        .from(CMTimeSubtract(lhs.cmTime, rhs.cmTime))
    }

    func clamped(min minValue: MediaTime = .zero, max maxValue: MediaTime) -> MediaTime {
        if self < minValue { return minValue }
        if self > maxValue { return maxValue }
        return self
    }
}

/// Normalized rectangle in top-left video frame coordinates ([0, 1]).
struct NormalizedRect: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let defaultCentered = NormalizedRect(x: 0.35, y: 0.35, width: 0.3, height: 0.18)

    func clamped(minSize: Double = 0.03) -> NormalizedRect {
        let clampedWidth = min(max(width, minSize), 1.0)
        let clampedHeight = min(max(height, minSize), 1.0)
        let clampedX = min(max(x, 0.0), 1.0 - clampedWidth)
        let clampedY = min(max(y, 0.0), 1.0 - clampedHeight)
        return NormalizedRect(x: clampedX, y: clampedY, width: clampedWidth, height: clampedHeight)
    }
}

struct MosaicRegion: Codable, Identifiable, Hashable, Sendable {
    static let defaultPixelScale: Double = 28

    var id: UUID
    var startTime: MediaTime
    var endTime: MediaTime
    var rect: NormalizedRect
    var pixelScale: Double

    init(
        id: UUID = UUID(),
        startTime: MediaTime,
        endTime: MediaTime,
        rect: NormalizedRect,
        pixelScale: Double = MosaicRegion.defaultPixelScale
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.rect = rect.clamped()
        self.pixelScale = min(max(pixelScale, 8), 64)
    }

    var duration: MediaTime { endTime - startTime }

    func isActive(at seconds: Double) -> Bool {
        let start = startTime.seconds
        let end = endTime.seconds
        return seconds >= start - 0.01 && seconds <= end + 0.01
    }
}

enum TrackKind: String, Codable, CaseIterable {
    case video
    case audio

    var title: String {
        switch self {
        case .video: "画面"
        case .audio: "声音"
        }
    }
}

struct MediaAsset: Codable, Identifiable, Hashable {
    var id: UUID
    var displayName: String
    var relativePath: String
    var duration: MediaTime
    var hasAudio: Bool
}

struct TimelineClip: Codable, Identifiable, Hashable {
    var id: UUID
    var assetID: UUID
    var timelineStart: MediaTime
    var sourceStart: MediaTime
    var duration: MediaTime
    var sourceTrackIndex: Int?

    var timelineEnd: MediaTime { timelineStart + duration }
}

struct TimelineTrack: Codable, Identifiable, Hashable {
    var id: UUID
    var kind: TrackKind
    var name: String
    var clips: [TimelineClip]
    var isMuted: Bool
    var volume: Float

    init(
        id: UUID,
        kind: TrackKind,
        name: String,
        clips: [TimelineClip],
        isMuted: Bool = false,
        volume: Float = 1.0
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.clips = clips
        self.isMuted = isMuted
        self.volume = min(max(volume, 0.0), 2.0)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case name
        case clips
        case isMuted
        case volume
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(TrackKind.self, forKey: .kind)
        name = try container.decode(String.self, forKey: .name)
        clips = try container.decode([TimelineClip].self, forKey: .clips)
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        let decodedVolume = try container.decodeIfPresent(Float.self, forKey: .volume) ?? 1.0
        volume = min(max(decodedVolume.isFinite ? decodedVolume : 1.0, 0.0), 2.0)
    }
}

/// A video file produced by exporting the edited timeline (with mosaics baked in).
struct ProjectExport: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var filePath: String
    var fileName: String
    var createdAt: Date
    var duration: MediaTime

    init(
        id: UUID = UUID(),
        filePath: String,
        fileName: String,
        createdAt: Date = .now,
        duration: MediaTime
    ) {
        self.id = id
        self.filePath = filePath
        self.fileName = fileName
        self.createdAt = createdAt
        self.duration = duration
    }

    var url: URL { URL(fileURLWithPath: filePath) }

    var fileExists: Bool { FileManager.default.fileExists(atPath: filePath) }
}

struct ProjectDocument: Codable, Identifiable, Hashable {
    static let currentVersion = 1

    var id: UUID
    var version: Int
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var canvasWidth: Int
    var canvasHeight: Int
    var frameRate: Int
    var assets: [MediaAsset]
    var tracks: [TimelineTrack]
    var mosaicRegions: [MosaicRegion]
    var exports: [ProjectExport]

    init(
        id: UUID,
        version: Int,
        name: String,
        createdAt: Date,
        updatedAt: Date,
        canvasWidth: Int,
        canvasHeight: Int,
        frameRate: Int,
        assets: [MediaAsset],
        tracks: [TimelineTrack],
        mosaicRegions: [MosaicRegion] = [],
        exports: [ProjectExport] = []
    ) {
        self.id = id
        self.version = version
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.frameRate = frameRate
        self.assets = assets
        self.tracks = tracks
        self.mosaicRegions = mosaicRegions
        self.exports = exports
    }

    enum CodingKeys: String, CodingKey {
        case id
        case version
        case name
        case createdAt
        case updatedAt
        case canvasWidth
        case canvasHeight
        case frameRate
        case assets
        case tracks
        case mosaicRegions
        case exports
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        version = try container.decode(Int.self, forKey: .version)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        canvasWidth = try container.decode(Int.self, forKey: .canvasWidth)
        canvasHeight = try container.decode(Int.self, forKey: .canvasHeight)
        frameRate = try container.decode(Int.self, forKey: .frameRate)
        assets = try container.decode([MediaAsset].self, forKey: .assets)
        tracks = try container.decode([TimelineTrack].self, forKey: .tracks)
        mosaicRegions = try container.decodeIfPresent([MosaicRegion].self, forKey: .mosaicRegions) ?? []
        exports = try container.decodeIfPresent([ProjectExport].self, forKey: .exports) ?? []
    }

    var duration: MediaTime {
        let endTimes = tracks.flatMap(\.clips).map(\.timelineEnd)
        return endTimes.max() ?? .zero
    }
}
