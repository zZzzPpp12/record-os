import AVKit
import SwiftUI

@MainActor
final class PreviewPlaybackModel: ObservableObject {
    let player = AVPlayer()

    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isScrubbing = false
    @Published private(set) var playbackRate: Double = 1
    @Published private(set) var hasMedia = false

    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    private var hasLoaded = false

    func load(url: URL, fallbackDuration: Double) {
        guard !hasLoaded else { return }
        hasLoaded = true

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        hasMedia = true
        duration = fallbackDuration
        currentTime = 0

        let interval = CMTime(value: 1, timescale: 20)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                let seconds = time.seconds
                if seconds.isFinite {
                    self.currentTime = max(0, seconds)
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = false
                self.currentTime = self.duration
            }
        }

        Task {
            if let loaded = try? await item.asset.load(.duration),
               loaded.seconds.isFinite,
               loaded.seconds > 0 {
                duration = loaded.seconds
            }
        }

        play()
    }

    func teardown() {
        player.pause()
        if let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
            self.timeObserverToken = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    func togglePlayback() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if duration > 0, currentTime >= duration - 0.1 {
                seek(to: 0)
            }
            play()
        }
    }

    func replay() {
        seek(to: 0)
        play()
    }

    func skip(by seconds: Double) {
        let target = min(max(0, currentTime + seconds), max(duration, 0))
        currentTime = target
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
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

    func setPlaybackRate(_ rate: Double) {
        playbackRate = rate
        if isPlaying {
            player.rate = Float(rate)
        }
    }

    private func play() {
        player.play()
        player.rate = Float(playbackRate)
        isPlaying = true
    }

    private func seek(to seconds: Double) {
        let clamped = min(max(0, seconds), max(duration, 0))
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }
}

struct ProjectPreviewView: View {
    let project: ProjectDocument
    let mediaURL: URL?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var playback = PreviewPlaybackModel()

    private var displayDuration: Double {
        playback.duration > 0 ? playback.duration : project.duration.seconds
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                if playback.hasMedia {
                    NativePlayerSurface(player: playback.player)
                        .padding(20)
                } else {
                    ContentUnavailableView(
                        "无法播放这个项目",
                        systemImage: "play.slash",
                        description: Text("找不到项目对应的视频文件。")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.94))

            Divider()
            playbackControls
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear(perform: loadPlayer)
        .onDisappear(perform: playback.teardown)
    }

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Label("返回项目库", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)

            Spacer()
            Text(project.name)
                .font(.headline)
            Spacer()

            Button("完成") { dismiss() }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var playbackControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Text(playback.currentTime.formattedDuration)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(width: 64, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { playback.currentTime },
                        set: { playback.updateScrub(to: $0) }
                    ),
                    in: 0...max(displayDuration, 0.1),
                    onEditingChanged: { playback.setScrubbing($0) }
                )
                .disabled(!playback.hasMedia)

                Text(displayDuration.formattedDuration)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)
            }

            HStack(spacing: 18) {
                Button {
                    playback.skip(by: -10)
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .help("后退 10 秒")
                .disabled(!playback.hasMedia)

                Button(action: playback.togglePlayback) {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(Color.accentColor, in: Circle())
                }
                .buttonStyle(.plain)
                .help(playback.isPlaying ? "暂停" : "播放")
                .disabled(!playback.hasMedia)

                Button {
                    playback.skip(by: 10)
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .help("前进 10 秒")
                .disabled(!playback.hasMedia)

                Spacer()

                Menu {
                    ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { rate in
                        Button {
                            playback.setPlaybackRate(rate)
                        } label: {
                            if rate == playback.playbackRate {
                                Label("\(rate.formattedSpeed) 倍速", systemImage: "checkmark")
                            } else {
                                Text("\(rate.formattedSpeed) 倍速")
                            }
                        }
                    }
                } label: {
                    Label("\(playback.playbackRate.formattedSpeed)×", systemImage: "speedometer")
                        .font(.callout)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!playback.hasMedia)

                Button {
                    playback.replay()
                } label: {
                    Label("从头播放", systemImage: "arrow.counterclockwise")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .disabled(!playback.hasMedia)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func loadPlayer() {
        guard let mediaURL,
              FileManager.default.fileExists(atPath: mediaURL.path) else {
            return
        }
        playback.load(url: mediaURL, fallbackDuration: project.duration.seconds)
    }
}

private extension Double {
    var formattedSpeed: String {
        truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", self)
            : String(format: "%.1f", self)
    }
}
