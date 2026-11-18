import AVFoundation
import Foundation

@MainActor
final class EditorPlaybackModel: ObservableObject {
    let player = AVPlayer()

    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isScrubbing = false
    @Published private(set) var hasContent = false

    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    private var generation = 0
    private var observersInstalled = false
    private var playbackRange: ClosedRange<Double>?
    private var currentComposition: AVMutableComposition?
    private var currentRenderInfo: (size: CGSize, fps: Int32)?

    init() {
        installObserversIfNeeded()
    }

    func setPlaybackRange(_ range: ClosedRange<Double>?) {
        playbackRange = range
    }

    func teardown() {
        player.pause()
        isPlaying = false
        if let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
            self.timeObserverToken = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        observersInstalled = false
    }

    private func installObserversIfNeeded() {
        guard !observersInstalled else { return }
        observersInstalled = true

        let interval = CMTime(value: 1, timescale: 20)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                let seconds = time.seconds
                guard seconds.isFinite else { return }
                if let limit = self.playbackRange,
                   self.isPlaying,
                   seconds >= limit.upperBound - 0.02 {
                    self.player.pause()
                    self.isPlaying = false
                    self.currentTime = limit.upperBound
                    return
                }
                self.currentTime = max(0, seconds)
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.player.currentItem != nil else { return }
                self.isPlaying = false
                self.currentTime = self.duration
            }
        }
    }

    func rebuild(project: ProjectDocument, urlFor: @escaping (MediaAsset) -> URL?) async {
        installObserversIfNeeded()
        generation += 1
        let buildGeneration = generation
        let targetTime = currentTime
        let wasPlaying = isPlaying

        let composition = await ProjectCompositionBuilder.makeComposition(project: project, urlFor: urlFor)
        guard buildGeneration == generation else { return }

        guard let composition else {
            currentComposition = nil
            currentRenderInfo = nil
            player.pause()
            player.replaceCurrentItem(with: nil)
            hasContent = false
            isPlaying = false
            currentTime = 0
            duration = 0
            return
        }

        currentComposition = composition
        let renderInfo = await VideoMosaicCompositor.renderInfo(
            for: composition,
            frameRate: project.frameRate
        )
        currentRenderInfo = renderInfo
        let item = AVPlayerItem(asset: composition)
        if let renderInfo,
           let videoComposition = await VideoMosaicCompositor.makeVideoComposition(
               for: composition,
               mosaicRegions: project.mosaicRegions,
               renderInfo: renderInfo
           ) {
            item.videoComposition = videoComposition
        }
        guard buildGeneration == generation else { return }
        player.replaceCurrentItem(with: item)
        hasContent = true

        let compositionSeconds = composition.duration.seconds
        duration = compositionSeconds.isFinite && compositionSeconds > 0
            ? compositionSeconds
            : project.duration.seconds

        let seekTarget = min(max(0, targetTime), duration)
        currentTime = seekTarget
        await player.seek(
            to: CMTime(seconds: seekTarget, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )

        if wasPlaying, duration > 0 {
            play()
        }
    }

    func updateVideoComposition(mosaicRegions: [MosaicRegion]) async {
        guard let item = player.currentItem,
              let composition = currentComposition,
              let renderInfo = currentRenderInfo else { return }
        generation += 1
        let updateGeneration = generation
        let videoComposition = await VideoMosaicCompositor.makeVideoComposition(
            for: composition,
            mosaicRegions: mosaicRegions,
            renderInfo: renderInfo
        )
        guard updateGeneration == generation, player.currentItem === item else { return }
        let pausedTime = currentTime
        item.videoComposition = videoComposition
        if !isPlaying {
            await player.seek(
                to: CMTime(seconds: pausedTime, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
    }

    func togglePlayback() {
        if isPlaying {
            pause()
            return
        }
        if let limit = playbackRange {
            if currentTime < limit.lowerBound - 0.05 || currentTime >= limit.upperBound - 0.05 {
                seek(to: limit.lowerBound)
            }
        } else if duration > 0, currentTime >= duration - 0.05 {
            seek(to: 0)
        }
        play()
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func play() {
        guard hasContent else { return }
        if let limit = playbackRange, currentTime < limit.lowerBound - 0.05 {
            seek(to: limit.lowerBound)
        }
        player.play()
        isPlaying = true
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func seek(to seconds: Double) {
        let clamped = min(max(0, seconds), max(duration, 0))
        currentTime = clamped
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func updateScrub(to value: Double) {
        currentTime = value
        if !isScrubbing {
            seek(to: value)
        }
    }

    func setScrubbing(_ editing: Bool) {
        isScrubbing = editing
        if !editing {
            seek(to: currentTime)
        }
    }
}
