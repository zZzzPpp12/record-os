import AVFoundation
import Foundation

enum ProjectCompositionBuilder {
    /// Builds the timeline composition shared by preview playback and export so
    /// both always render the same clips in the same order.
    @MainActor
    static func makeComposition(
        project: ProjectDocument,
        urlFor: (MediaAsset) -> URL?
    ) async -> AVMutableComposition? {
        let assetsByID = Dictionary(
            project.assets.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard !assetsByID.isEmpty else { return nil }

        let composition = AVMutableComposition()
        var loadedTracks: [String: (asset: AVURLAsset, track: AVAssetTrack)] = [:]
        var hasContent = false

        for track in project.tracks {
            let mediaType: AVMediaType = track.kind == .video ? .video : .audio
            let clips = track.clips
                .filter { $0.duration > .zero }
                .sorted { $0.timelineStart < $1.timelineStart }
            guard !clips.isEmpty,
                  let compositionTrack = composition.addMutableTrack(
                    withMediaType: mediaType,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                  ) else {
                continue
            }

            for clip in clips {
                guard let asset = assetsByID[clip.assetID], let url = urlFor(asset) else { continue }
                let cacheKey = url.path + "|" + mediaType.rawValue
                let source: (asset: AVURLAsset, track: AVAssetTrack)?
                if let cached = loadedTracks[cacheKey] {
                    source = cached
                } else {
                    // Keep the AVURLAsset alive together with its track: a track
                    // whose asset is released can no longer be inserted.
                    let avAsset = AVURLAsset(url: url)
                    if let avTrack = try? await avAsset.loadTracks(withMediaType: mediaType).first {
                        source = (avAsset, avTrack)
                        loadedTracks[cacheKey] = source
                    } else {
                        source = nil
                    }
                }
                guard let source else { continue }

                let range = CMTimeRange(start: clip.sourceStart.cmTime, duration: clip.duration.cmTime)
                do {
                    try compositionTrack.insertTimeRange(range, of: source.track, at: clip.timelineStart.cmTime)
                    hasContent = true
                } catch {
                    continue
                }
            }
        }

        return hasContent ? composition : nil
    }
}
