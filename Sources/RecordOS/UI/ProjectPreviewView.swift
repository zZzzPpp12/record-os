import AVKit
import SwiftUI

struct ProjectPreviewView: View {
    let project: ProjectDocument
    let mediaURL: URL?

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var isPlaying = false

    var body: some View {
        VStack(spacing: 0) {
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

            Divider()

            Group {
                if let player {
                    NativePlayerSurface(player: player)
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

            HStack {
                Button(action: togglePlayback) {
                    Label(isPlaying ? "暂停" : "播放", systemImage: isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(player == nil)

                Spacer()

                Text("时长  \(project.duration.seconds.formattedDuration)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear(perform: loadPlayer)
        .onDisappear {
            player?.pause()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard let player,
                  let item = notification.object as? AVPlayerItem,
                  item === player.currentItem else {
                return
            }
            isPlaying = false
        }
    }

    private func loadPlayer() {
        guard let mediaURL,
              FileManager.default.fileExists(atPath: mediaURL.path) else {
            return
        }
        let player = AVPlayer(url: mediaURL)
        self.player = player
        player.play()
        isPlaying = true
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }
}
