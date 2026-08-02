import SwiftUI
import Photos
import PhotosUI
import AVKit

@MainActor
enum VideoAudioState {
    static func apply(to player: AVPlayer, muted: Bool, volume: Double) {
        player.isMuted = muted
        player.volume = muted ? 0 : Float(volume)
    }

    static func apply(to livePhotoView: PHLivePhotoView, muted: Bool) {
        livePhotoView.isMuted = muted
    }
}

private final class AVPlayerSurfaceView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private struct AVPlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    let framingMode: MediaFramingMode
    func makeUIView(context: Context) -> AVPlayerSurfaceView {
        let view = AVPlayerSurfaceView()
        view.playerLayer.videoGravity = framingMode == .fitWithBorder ? .resizeAspect : .resizeAspectFill
        view.playerLayer.player = player
        return view
    }
    func updateUIView(_ view: AVPlayerSurfaceView, context: Context) {
        view.playerLayer.player = player
        view.playerLayer.videoGravity = framingMode == .fitWithBorder ? .resizeAspect : .resizeAspectFill
    }
}

struct LivePhotoAssetView: UIViewRepresentable {
    let asset: PHAsset
    let isPlaying: Bool
    let loop: Bool
    let muted: Bool
    let framingMode: MediaFramingMode
    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = framingMode == .fitWithBorder ? .scaleAspectFit : .scaleAspectFill
        view.clipsToBounds = true
        return view
    }
    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        view.delegate = context.coordinator
        view.contentMode = framingMode == .fitWithBorder ? .scaleAspectFit : .scaleAspectFill
        VideoAudioState.apply(to: view, muted: muted)
        context.coordinator.loop = loop
        context.coordinator.isPlaying = isPlaying
        let identifier = asset.localIdentifier
        guard context.coordinator.loadedID != identifier else {
            if isPlaying { view.startPlayback(with: .full) } else { view.stopPlayback() }
            return
        }
        context.coordinator.loadedID = identifier
        let options = PHLivePhotoRequestOptions(); options.isNetworkAccessAllowed = true; options.deliveryMode = .highQualityFormat
        let contentMode: PHImageContentMode = framingMode == .fitWithBorder ? .aspectFit : .aspectFill
        PHImageManager.default().requestLivePhoto(for: asset, targetSize: UIScreen.main.bounds.size, contentMode: contentMode, options: options) { photo, _ in
            DispatchQueue.main.async { view.livePhoto = photo; if isPlaying, photo != nil { view.startPlayback(with: .full) } }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, PHLivePhotoViewDelegate {
        var loadedID: String?
        var loop = false
        var isPlaying = false

        func livePhotoView(_ livePhotoView: PHLivePhotoView, didEndPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
            guard loop, isPlaying else { return }
            livePhotoView.startPlayback(with: .full)
        }
    }
}

struct VideoAssetView: View {
    let asset: PHAsset
    let isPlaying: Bool
    let muted: Bool
    let volume: Double
    let framingMode: MediaFramingMode
    @State private var player: AVPlayer?
    @State private var loadedID: String?

    var body: some View {
        Group {
            if let player {
                AVPlayerSurface(player: player, framingMode: framingMode)
                    .ignoresSafeArea()
                    .onAppear { VideoAudioState.apply(to: player, muted: muted, volume: volume); if isPlaying { player.play() } }
                    .onChange(of: isPlaying) { _, playing in playing ? player.play() : player.pause() }
                    .onChange(of: muted) { _, value in VideoAudioState.apply(to: player, muted: value, volume: volume) }
                    .onChange(of: volume) { _, value in VideoAudioState.apply(to: player, muted: muted, volume: value) }
                    .onDisappear { player.pause() }
            } else { ProgressView().tint(.white) }
        }
            .task(id: asset.localIdentifier) {
                guard loadedID != asset.localIdentifier else { return }
                let options = PHVideoRequestOptions(); options.isNetworkAccessAllowed = true; options.deliveryMode = .automatic
                let result = await withCheckedContinuation { continuation in
                    PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in continuation.resume(returning: avAsset) }
                }
                if let result {
                    let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: result))
                    VideoAudioState.apply(to: newPlayer, muted: muted, volume: volume)
                    player = newPlayer
                    loadedID = asset.localIdentifier
                    if isPlaying { newPlayer.play() }
                }
            }
    }
}

struct LocalVideoView: View {
    let url: URL
    let isPlaying: Bool
    let muted: Bool
    let volume: Double
    let framingMode: MediaFramingMode
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                AVPlayerSurface(player: player, framingMode: framingMode).ignoresSafeArea()
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: url) {
            let value = AVPlayer(url: url)
            VideoAudioState.apply(to: value, muted: muted, volume: volume)
            player = value
            if isPlaying { value.play() }
        }
        .onChange(of: isPlaying) { _, value in value ? player?.play() : player?.pause() }
        .onChange(of: muted) { _, value in if let player { VideoAudioState.apply(to: player, muted: value, volume: volume) } }
        .onChange(of: volume) { _, value in if let player { VideoAudioState.apply(to: player, muted: muted, volume: value) } }
        .onDisappear { player?.pause() }
    }
}
