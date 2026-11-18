import AVFoundation
import Foundation

enum ProjectCompositionBuilder {
    /// Loaded tracks are reused across rebuilds. Editing the timeline rebuilds the
    /// composition often, and re-reading the same media file each time is wasteful.
    @MainActor private static var assetCache: [String: AVURLAsset] = [:]
    @MainActor private static var trackCache: [String: (asset: AVURLAsset, track: AVAssetTrack)] = [:]

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
                guard let source = await loadTrack(url: url, mediaType: mediaType) else { continue }

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

    @MainActor
    private static func loadTrack(
        url: URL,
        mediaType: AVMediaType
    ) async -> (asset: AVURLAsset, track: AVAssetTrack)? {
        let cacheKey = url.path + "|" + mediaType.rawValue
        if let cached = trackCache[cacheKey] {
            return cached
        }

        let asset: AVURLAsset
        if let cachedAsset = assetCache[url.path] {
            asset = cachedAsset
        } else {
            asset = AVURLAsset(url: url)
            assetCache[url.path] = asset
        }

        // Keep the AVURLAsset alive together with its track: a track whose asset
        // is released can no longer be inserted into a composition.
        guard let avTrack = try? await asset.loadTracks(withMediaType: mediaType).first else {
            return nil
        }
        let entry = (asset: asset, track: avTrack)
        trackCache[cacheKey] = entry
        return entry
    }
}
