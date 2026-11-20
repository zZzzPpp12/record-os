import AVFoundation
import Foundation

struct BuiltComposition {
    let composition: AVMutableComposition
    let audioTrackIDs: [UUID: CMPersistentTrackID]
    let audioMix: AVAudioMix?
}

enum ProjectCompositionBuilder {
    /// Loaded tracks are reused across rebuilds. Editing the timeline rebuilds the
    /// composition often, and re-reading the same media file each time is wasteful.
    @MainActor private static var assetCache: [String: AVURLAsset] = [:]
    @MainActor private static var trackListCache: [String: (asset: AVURLAsset, tracks: [AVAssetTrack])] = [:]
    private static let maxCachedAssets = 16

    /// Builds the timeline composition shared by preview playback and export so
    /// both always render the same clips, video mosaics, and audio mix levels.
    @MainActor
    static func makeComposition(
        project: ProjectDocument,
        urlFor: (MediaAsset) -> URL?
    ) async -> BuiltComposition? {
        let assetsByID = Dictionary(
            project.assets.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard !assetsByID.isEmpty else { return nil }

        let composition = AVMutableComposition()
        var hasContent = false
        var audioTrackIDs: [UUID: CMPersistentTrackID] = [:]

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

            var insertedAnySegment = false
            for clip in clips {
                guard let asset = assetsByID[clip.assetID], let url = urlFor(asset) else { continue }
                let rawTrackIndex = clip.sourceTrackIndex ?? 0
                guard rawTrackIndex >= 0 else { continue }
                guard let source = await loadTrack(url: url, mediaType: mediaType, trackIndex: rawTrackIndex) else { continue }

                let range = CMTimeRange(start: clip.sourceStart.cmTime, duration: clip.duration.cmTime)
                do {
                    try compositionTrack.insertTimeRange(range, of: source.track, at: clip.timelineStart.cmTime)
                    hasContent = true
                    insertedAnySegment = true
                } catch {
                    continue
                }
            }

            if insertedAnySegment {
                if track.kind == .audio {
                    audioTrackIDs[track.id] = compositionTrack.trackID
                }
            } else {
                composition.removeTrack(compositionTrack)
            }
        }

        guard hasContent else { return nil }
        let audioMix = makeAudioMix(for: project, composition: composition, audioTrackIDs: audioTrackIDs)
        return BuiltComposition(
            composition: composition,
            audioTrackIDs: audioTrackIDs,
            audioMix: audioMix
        )
    }

    static func makeAudioMix(
        for project: ProjectDocument,
        composition: AVMutableComposition,
        audioTrackIDs: [UUID: CMPersistentTrackID]
    ) -> AVAudioMix? {
        guard !audioTrackIDs.isEmpty else { return nil }

        var parameters: [AVMutableAudioMixInputParameters] = []
        for track in project.tracks where track.kind == .audio {
            guard let persistentID = audioTrackIDs[track.id],
                  let compositionTrack = composition.track(withTrackID: persistentID) else {
                continue
            }
            let trackParams = AVMutableAudioMixInputParameters(track: compositionTrack)
            let effectiveVolume: Float = track.isMuted
                ? 0.0
                : min(max(track.volume.isFinite ? track.volume : 1.0, 0.0), 2.0)
            trackParams.setVolume(effectiveVolume, at: .zero)
            parameters.append(trackParams)
        }

        guard !parameters.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
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
