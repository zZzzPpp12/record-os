import AVKit
import SwiftUI

/// Wrap AppKit's AVPlayerView directly. SwiftUI's VideoPlayer crashes on the
/// current macOS build while creating its representable metadata, so this keeps
/// the preview native without depending on the SwiftUI AVKit wrapper.
struct NativePlayerSurface: NSViewRepresentable {
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
