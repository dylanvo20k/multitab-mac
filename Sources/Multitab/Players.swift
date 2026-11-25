import AVFoundation
import AVKit
import SwiftUI

/// Muted, looping video with no controls. Used for GIFs and hover previews.
final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()
    var looper: AVPlayerLooper?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

struct LoopingVideo: NSViewRepresentable {
    let url: URL
    var fill = true

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        let player = AVQueuePlayer()
        player.isMuted = true
        view.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        view.playerLayer.player = player
        view.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        player.play()
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {}

    static func dismantleNSView(_ nsView: PlayerLayerView, coordinator: ()) {
        nsView.playerLayer.player?.pause()
        nsView.looper?.disableLooping()
        nsView.playerLayer.player = nil
    }
}

/// Player view that leaves arrow keys to the gallery viewer.
final class GalleryPlayerView: AVPlayerView {
    override var acceptsFirstResponder: Bool { false }
}

/// Full video with sound and playback controls. Tries the stream with audio first,
/// then falls back to the silent mp4 if the stream fails.
struct VideoWithSound: NSViewRepresentable {
    let item: MediaItem

    final class Coordinator {
        var observation: NSKeyValueObservation?
        var endObserver: NSObjectProtocol?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> GalleryPlayerView {
        let view = GalleryPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        let player = AVPlayer()
        view.player = player
        load(item.hls ?? item.full, player: player, coordinator: context.coordinator)
        // Loop when the video ends.
        context.coordinator.endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak player] note in
            guard let player, (note.object as? AVPlayerItem) === player.currentItem else { return }
            player.seek(to: .zero)
            player.play()
        }
        player.play()
        return view
    }

    private func load(_ url: URL, player: AVPlayer, coordinator: Coordinator) {
        let playerItem = AVPlayerItem(url: url)
        let fallback = item.full
        coordinator.observation = playerItem.observe(\.status) { [weak player] it, _ in
            guard it.status == .failed, url != fallback else { return }
            DispatchQueue.main.async {
                guard let player else { return }
                player.replaceCurrentItem(with: AVPlayerItem(url: fallback))
                player.play()
            }
        }
        player.replaceCurrentItem(with: playerItem)
    }

    func updateNSView(_ nsView: GalleryPlayerView, context: Context) {}

    static func dismantleNSView(_ nsView: GalleryPlayerView, coordinator: Coordinator) {
        nsView.player?.pause()
        nsView.player = nil
        coordinator.observation = nil
        if let o = coordinator.endObserver { NotificationCenter.default.removeObserver(o) }
    }
}
