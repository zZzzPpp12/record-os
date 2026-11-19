import AVFoundation
import Foundation

enum ProjectCompositionBuilder {
    /// Loaded tracks are reused across rebuilds. Editing the timeline rebuilds the
    /// composition often, and re-reading the same media file each time is wasteful.
    @MainActor private static var assetCache: [String: AVURLAsset] = [:]
    @MainActor private static var trackListCache: [String: (asset: AVURLAsset, tracks: [AVAssetTrack])] = [:]
    private static let maxCachedAssets = 16

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
                let rawTrackIndex = clip.sourceTrackIndex ?? 0
                guard rawTrackIndex >= 0 else { continue }
                guard let source = await loadTrack(url: url, mediaType: mediaType, trackIndex: rawTrackIndex) else { continue }

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
        mediaType: AVMediaType,
        trackIndex: Int
    ) async -> (asset: AVURLAsset, track: AVAssetTrack)? {
        let cacheKey = "\(url.path)|\(mediaType.rawValue)"
        if let cached = trackListCache[cacheKey] {
            guard cached.tracks.indices.contains(trackIndex) else { return nil }
            return (cached.asset, cached.tracks[trackIndex])
        }

        if assetCache.count >= maxCachedAssets {
            assetCache.removeAll()
            trackListCache.removeAll()
        }

        let asset: AVURLAsset
        if let cachedAsset = assetCache[url.path] {
            asset = cachedAsset
        } else {
            asset = AVURLAsset(url: url)
            assetCache[url.path] = asset
        }

        // Keep the AVURLAsset alive together with its tracks: a track whose asset
        // is released can no longer be inserted into a composition.
        guard let tracks = try? await asset.loadTracks(withMediaType: mediaType) else {
            return nil
        }
        trackListCache[cacheKey] = (asset: asset, tracks: tracks)
        guard tracks.indices.contains(trackIndex) else {
            return nil
        }
        return (asset: asset, track: tracks[trackIndex])
    }
}
