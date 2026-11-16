import Foundation
import CoreMedia

struct MediaTime: Codable, Hashable, Comparable {
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

    var timelineEnd: MediaTime { timelineStart + duration }
}

struct TimelineTrack: Codable, Identifiable, Hashable {
    var id: UUID
    var kind: TrackKind
    var name: String
    var clips: [TimelineClip]
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

    var duration: MediaTime {
        let endTimes = tracks.flatMap(\.clips).map(\.timelineEnd)
        return endTimes.max() ?? .zero
    }
}
