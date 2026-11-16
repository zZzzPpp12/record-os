import AVKit
import SwiftUI

struct EditorView: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject var session: EditorSession

    @State private var player: AVPlayer?

    private var selectedAssetURL: URL? {
        guard let asset = session.selectedAsset else { return nil }
        return appModel.projectStore.mediaURL(for: asset, in: session.project)
    }

    var body: some View {
        VStack(spacing: 0) {
            editorHeader
            Divider()
            HStack(spacing: 0) {
                preview
                Divider()
                inspector
            }
            .frame(maxHeight: .infinity)
            Divider()
            timeline
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: loadPlayer)
        .onChange(of: session.selectedClipID) { loadPlayer() }
        .alert("剪辑操作", isPresented: Binding(
            get: { session.errorMessage != nil },
            set: { if !$0 { session.clearError() } }
        )) {
            Button("好", role: .cancel) { session.clearError() }
        } message: {
            Text(session.errorMessage ?? "")
        }
    }

    private var editorHeader: some View {
        HStack(spacing: 12) {
            Button {
                appModel.activeEditor = nil
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .help("返回项目库")
            Text(session.project.name)
                .font(.headline)
            Spacer()
            Button("导出") {}
                .buttonStyle(.borderedProminent)
                .disabled(true)
                .help("导出渲染将在下一阶段接入")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
    }

    private var preview: some View {
        VStack(spacing: 10) {
            if let player {
                NativePlayerSurface(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .padding(18)
            } else {
                ContentUnavailableView("没有可预览的媒体", systemImage: "play.rectangle")
            }
            HStack(spacing: 14) {
                Button {
                    player?.seek(to: session.playhead.cmTime)
                } label: {
                    Image(systemName: "backward.end.fill")
                }
                .buttonStyle(.plain)
                Button {
                    if player?.timeControlStatus == .playing { player?.pause() }
                    else { player?.play() }
                } label: {
                    Image(systemName: "playpause.fill")
                }
                .buttonStyle(.plain)
                Text(session.playhead.seconds.formattedDuration)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(session.project.duration.seconds.formattedDuration)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.035))
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("检查器").font(.headline)
            Divider()
            Text("项目设置").font(.subheadline.weight(.semibold))
            propertyRow("画布", value: "\(session.project.canvasWidth) × \(session.project.canvasHeight)")
            propertyRow("帧率", value: "\(session.project.frameRate) fps")
            propertyRow("素材", value: "\(session.project.assets.count) 个")
            Spacer()
            Text("片段操作").font(.subheadline.weight(.semibold))
            Button {
                session.splitAtPlayhead()
            } label: {
                Label("在播放头处分割", systemImage: "scissors")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(session.selectedClipID == nil)
            Button(role: .destructive) {
                session.deleteSelectedClip()
            } label: {
                Label("删除选中片段", systemImage: "trash")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(session.selectedClipID == nil)
            Button {
                session.undo()
            } label: {
                Label("撤销", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!session.canUndo)
        }
        .buttonStyle(.plain)
        .padding(18)
        .frame(width: 245, alignment: .leading)
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("时间线").font(.subheadline.weight(.semibold))
                Spacer()
                Text("非破坏式编辑 · 项目自动保存")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(session.project.tracks) { track in
                        HStack(spacing: 8) {
                            Text(track.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .leading)
                            ForEach(track.clips) { clip in
                                Button {
                                    session.selectedClipID = clip.id
                                    session.playhead = clip.timelineStart
                                    player?.seek(to: clip.sourceStart.cmTime)
                                } label: {
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(session.selectedClipID == clip.id ? Color.accentColor : Color.accentColor.opacity(0.42))
                                        .frame(width: max(110, clip.duration.seconds * 28), height: 28)
                                        .overlay(alignment: .leading) {
                                            Text(track.kind == .video ? "屏幕录制" : "系统声音")
                                                .font(.caption2.weight(.medium))
                                                .foregroundStyle(.white)
                                                .padding(.leading, 8)
                                        }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(height: 32)
                    }
                    if session.project.duration.seconds > 0 {
                        Slider(
                            value: Binding(
                                get: { session.playhead.seconds },
                                set: { value in
                                    session.playhead = MediaTime(seconds: value)
                                    player?.seek(to: session.playhead.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
                                }
                            ),
                            in: 0...session.project.duration.seconds
                        )
                        .frame(maxWidth: 420)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(height: 142)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
    }

    private func propertyRow(_ name: String, value: String) -> some View {
        HStack {
            Text(name).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.caption)
    }

    private func loadPlayer() {
        guard let selectedAssetURL else {
            player = nil
            return
        }
        player = AVPlayer(url: selectedAssetURL)
    }
}

/// Wrap AppKit's AVPlayerView directly. SwiftUI's VideoPlayer crashes on the
/// current macOS build while creating its representable metadata, so this keeps
/// the preview native without depending on the SwiftUI AVKit wrapper.
private struct NativePlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}
