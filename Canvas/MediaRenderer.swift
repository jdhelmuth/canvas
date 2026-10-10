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
#if DEBUG
    var diagnosticTick = 0
#endif
    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = framingMode == .fitWithBorder ? .scaleAspectFit : .scaleAspectFill
        view.clipsToBounds = true
        // Slideshow controls own playback; the default long-press recognizer
        // otherwise bypasses the coordinator's single-play lifecycle.
        view.playbackGestureRecognizer.isEnabled = false
        return view
    }
    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        let coordinator = context.coordinator
#if DEBUG
        LivePhotoDiagnostics.record("update", view: view, detail: "playing=\(isPlaying) loop=\(loop) active=\(coordinator.playbackState.phase)")
#endif
        view.delegate = coordinator
        view.contentMode = framingMode == .fitWithBorder ? .scaleAspectFit : .scaleAspectFill
        VideoAudioState.apply(to: view, muted: muted)
        coordinator.loop = loop
        coordinator.isPlaying = isPlaying
        if !isPlaying {
            coordinator.stopPlayback(view)
        }
        let identifier = asset.localIdentifier
        guard coordinator.loadedID != identifier else {
            if isPlaying { coordinator.startPlaybackIfNeeded(view) }
            return
        }
        let generation = coordinator.beginLoading(assetID: identifier, view: view)
        let options = PHLivePhotoRequestOptions(); options.isNetworkAccessAllowed = true; options.deliveryMode = .highQualityFormat
        // Always load an uncropped Live Photo. PHLivePhotoView owns the one
        // intentional fit/fill transform through its contentMode above. Using
        // aspectFill at both stages makes common iPhone Live Photos appear far
        // more zoomed on an iPad than the selected framing mode calls for.
        let requestID = PHImageManager.default().requestLivePhoto(
            for: asset,
            targetSize: UIScreen.main.bounds.size,
            contentMode: PhotoKitSourceFramingPolicy.contentMode,
            options: options
        ) { [weak view, weak coordinator] photo, info in
            DispatchQueue.main.async {
                guard let view, let coordinator,
                      LivePhotoPlaybackPolicy.acceptsLoadedPhoto(
                          assetID: identifier,
                          currentAssetID: coordinator.loadedID,
                          requestGeneration: generation,
                          currentGeneration: coordinator.requestGeneration
                      ) else { return }
                guard (info?[PHImageResultIsDegradedKey] as? Bool) != true else { return }
                coordinator.requestID = nil
                guard (info?[PHImageCancelledKey] as? Bool) != true,
                      info?[PHImageErrorKey] == nil,
                      let photo, view.livePhoto == nil else { return }
                view.livePhoto = photo
#if DEBUG
                LivePhotoDiagnostics.record("loaded", view: view)
#endif
                if coordinator.isPlaying { coordinator.startPlaybackIfNeeded(view) }
            }
        }
        coordinator.requestID = requestID
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    static func dismantleUIView(_ uiView: PHLivePhotoView, coordinator: Coordinator) {
        coordinator.invalidate(uiView)
    }

    final class Coordinator: NSObject, PHLivePhotoViewDelegate {
        var loadedID: String?
        var requestID: PHImageRequestID?
        var requestGeneration = 0
        var loop = false
        var isPlaying = false
        var playbackState = LivePhotoPlaybackState()

        func beginLoading(assetID: String, view: PHLivePhotoView) -> Int {
            cancelPendingRequest()
            requestGeneration &+= 1
            loadedID = assetID
            view.delegate = nil
            view.stopPlayback()
            playbackState = LivePhotoPlaybackState()
            view.delegate = self
            view.livePhoto = nil
            return requestGeneration
        }

        func startPlaybackIfNeeded(_ view: PHLivePhotoView) {
            guard playbackState.startIfNeeded(isPlaying: isPlaying, loop: loop,
                                               hasLivePhoto: view.livePhoto != nil) else { return }
#if DEBUG
            LivePhotoDiagnostics.record("start", view: view)
#endif
            view.startPlayback(with: .full)
        }

        func stopPlayback(_ view: PHLivePhotoView) {
            guard playbackState.stopIfNeeded() else { return }
            view.stopPlayback()
        }

        func invalidate(_ view: PHLivePhotoView) {
            cancelPendingRequest()
            requestGeneration &+= 1
            loadedID = nil
            isPlaying = false
            loop = false
            view.delegate = nil
            view.stopPlayback()
            view.livePhoto = nil
            playbackState = LivePhotoPlaybackState()
        }

        private func cancelPendingRequest() {
            if let requestID {
                PHImageManager.default().cancelImageRequest(requestID)
                self.requestID = nil
            }
        }

        func livePhotoView(_ livePhotoView: PHLivePhotoView, didEndPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
            guard playbackState.didEnd() else { return }
#if DEBUG
            LivePhotoDiagnostics.record("end", view: livePhotoView)
#endif
            startPlaybackIfNeeded(livePhotoView)
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

#if DEBUG
/// Opt-in, read-only device exercise. It never creates a playback queue or saves settings.
@MainActor
enum LivePhotoDiagnostics {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--canvas-live-photo-check") }
    static var caseName = ""
    static let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("live-photo-check", isDirectory: true)
    static func record(_ event: String, view: PHLivePhotoView, detail: String = "") {
        guard enabled else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let size = view.livePhoto?.size ?? .zero
        let line = "\(Date().timeIntervalSince1970) \(caseName) \(event) bounds=\(view.bounds.size) intrinsic=\(view.intrinsicContentSize) photo=\(size) mode=\(view.contentMode.rawValue) \(detail)\n"
        let file = directory.appendingPathComponent("events.txt")
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: file) {
            try? handle.seekToEnd(); try? handle.write(contentsOf: Data(line.utf8)); try? handle.close()
        }
    }
    static func capture(_ name: String) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first(where: \.isKeyWindow) else { return }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? image.pngData()?.write(to: directory.appendingPathComponent("\(name).png"))
    }
}

struct LivePhotoDiagnosticView: View {
    @EnvironmentObject private var store: AppStore
    @State private var assets: [PHAsset] = []
    @State private var tick = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var body: some View {
        GeometryReader { proxy in
            let caseIndex = tick / 12
            let phase = tick % 12
            let finished = caseIndex >= assets.count * 4
            let index = assets.isEmpty ? 0 : (caseIndex / 4) % assets.count
            let fit = caseIndex % 2 == 0
            let portrait = caseIndex % 4 >= 2
            let size = portrait ? CGSize(width: proxy.size.height * 0.72, height: proxy.size.height) : proxy.size
            ZStack {
                Color.black
                if !assets.isEmpty && !finished {
                    LivePhotoAssetView(asset: assets[index], isPlaying: phase >= 2 && phase != 6,
                        loop: false, muted: true, framingMode: fit ? .fitWithBorder : .fillZoom,
                        diagnosticTick: tick)
                        .id(caseIndex)
                        .frame(width: size.width, height: size.height)
                }
                VStack {
                    Text(finished ? "Live Photo check complete" : "Live Photo \(caseIndex + 1) · \(fit ? "Fit" : "Fill") · \(portrait ? "portrait" : "landscape") · \(phase)")
                        .padding(8).background(.black.opacity(0.7))
                    Spacer()
                }.foregroundStyle(.white)
            }.frame(width: proxy.size.width, height: proxy.size.height)
            .onReceive(timer) { _ in
                guard !finished else { return }
                LivePhotoDiagnostics.caseName = "case-\(caseIndex)"
                if [1, 3, 5, 7, 10].contains(phase) {
                    LivePhotoDiagnostics.capture("case-\(caseIndex)-second-\(phase)")
                }
                tick += 1
            }
        }.ignoresSafeArea()
        .task {
            UIApplication.shared.isIdleTimerDisabled = true
            var candidates: [PHAsset] = []
            var seen = Set<String>()
            for album in store.settings.selectedAlbums where album.source == .applePhotos {
                guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album.id], options: nil).firstObject else { continue }
                let options = PHFetchOptions()
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                PHAsset.fetchAssets(in: collection, options: options).enumerateObjects { asset, _, _ in
                    if asset.mediaSubtypes.contains(.photoLive), seen.insert(asset.localIdentifier).inserted { candidates.append(asset) }
                }
            }
            let portrait = candidates.first { $0.pixelWidth < $0.pixelHeight }
            let landscape = candidates.first { $0.pixelWidth > $0.pixelHeight }
            assets = [portrait, landscape].compactMap { $0 }
            LivePhotoDiagnostics.caseName = "case-0"
        }
    }
}
#endif
