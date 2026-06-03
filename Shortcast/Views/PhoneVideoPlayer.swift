import AVKit
import SwiftUI

/// A silent, looping video view with no playback controls — used as the
/// background of the phone-style post previews.
struct PhoneVideoPlayer: NSViewRepresentable {

    let url: URL
    /// How the video fills its frame. Previews crop-fill (`.resizeAspectFill`);
    /// the progress screen letterboxes (`.resizeAspect`) so horizontal source
    /// video isn't weirdly cropped.
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = gravity

        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.actionAtItemEnd = .advance
        context.coordinator.looper = AVPlayerLooper(
            player: queue, templateItem: AVPlayerItem(url: url))
        context.coordinator.player = queue
        view.player = queue
        queue.play()
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        coordinator.player?.pause()
        coordinator.looper?.disableLooping()
        nsView.player = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var player: AVQueuePlayer?
        var looper: AVPlayerLooper?
    }
}
