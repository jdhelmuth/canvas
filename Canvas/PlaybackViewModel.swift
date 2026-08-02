import Foundation
import UIKit
import AVFoundation

@MainActor
final class PlaybackViewModel: ObservableObject {
    @Published private(set) var isPlaying = true
    @Published private(set) var currentImage: UIImage?
    @Published private(set) var layoutImages: [UIImage] = []
    @Published private(set) var layoutAssets: [CanvasMediaItem] = []
    @Published private(set) var currentAsset: CanvasMediaItem?
    @Published private(set) var progress = 0.0
    @Published private(set) var errorMessage: String?
    @Published private(set) var queueCount = 0
    @Published private(set) var currentIndex = 0
    @Published private(set) var elapsed = 0.0
    private var library: PhotoLibraryService?
    private var googlePhotos: GooglePhotosService?
    private var loader: AssetImageLoader?
    private var settings: CanvasSettings = .init()
    private var queue: [CanvasMediaItem] = []
    private var timerTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var previousIDs: [String] = []
    private var configured = false
    private var currentMediaDuration: Double = 0
    private var playbackAllowed = true
    private var canvasSize: CGSize = .zero
    private var loadGeneration = 0

    func configure(library: PhotoLibraryService, googlePhotos: GooglePhotosService, loader: AssetImageLoader, settings: CanvasSettings) {
        guard !configured else { return }
        self.library = library; self.googlePhotos = googlePhotos; self.loader = loader; self.settings = settings; configured = true
        Task { await reload() }
    }

    func reload(settings updatedSettings: CanvasSettings? = nil) async {
        guard let library else { return }
        timerTask?.cancel()
        loadTask?.cancel()
        loadGeneration &+= 1
        let generation = loadGeneration
        if let updatedSettings { settings = updatedSettings }
        let appleItems = library.mediaItems(for: settings.selectedAlbums, filters: settings.filters)
        let googleItems = googlePhotos?.items(for: settings.selectedAlbums, filters: settings.filters) ?? []
        let assets = MediaIdentityMatcher.deduplicated(appleItems + googleItems)
        queue = QueueBuilder.build(assets, mode: settings.queueMode, repeatEnabled: settings.repeatEnabled, previousIDs: previousIDs, recentAvoidance: settings.recentAvoidance, shuffleSeed: Int(Date().timeIntervalSince1970))
        queueCount = queue.count
        currentIndex = min(currentIndex, max(0, queue.count - 1))
        await loadCurrent(generation: generation)
        guard !Task.isCancelled, loadGeneration == generation else { return }
        startTimer()
    }

    /// Applies a settings edit to an already-presented frame. Duration edits
    /// restart only the current timer; queue/filter/layout edits rebuild the
    /// queue and image companions so the control changes the actual frame,
    /// not just the settings screen.
    func updateSettings(_ updatedSettings: CanvasSettings) async {
        let requiresReload = settings.selectedAlbums != updatedSettings.selectedAlbums
            || settings.filters != updatedSettings.filters
            || settings.queueMode != updatedSettings.queueMode
            || settings.recentAvoidance != updatedSettings.recentAvoidance
            || settings.layout != updatedSettings.layout
        settings = updatedSettings
        if requiresReload {
            await reload(settings: updatedSettings)
        } else {
            startTimer()
        }
    }

    /// Schedules and power limits gate the frame without changing the user's
    /// play/pause preference. The timer is cancelled while gated so a hidden
    /// slideshow cannot advance items behind the waiting screen.
    func setPlaybackAllowed(_ allowed: Bool) {
        playbackAllowed = allowed
        if allowed {
            startTimer()
        } else {
            timerTask?.cancel()
        }
    }

    func togglePlaying() { isPlaying.toggle(); if isPlaying { startTimer() } else { timerTask?.cancel() } }
    @discardableResult func next() -> Bool { advance(direction: 1) }
    @discardableResult func previous() -> Bool { advance(direction: -1) }

    /// Updates the actual fullscreen canvas used by LayoutCanvas. Keeping the
    /// size here lets a gesture resolve the same orientation-aware group that
    /// is currently visible, including after rotation.
    func updateCanvasSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        canvasSize = size
    }

    /// Horizontal gestures navigate by the displayed group when a pair or
    /// collage is actually present. Video and Live Photo surfaces remain one
    /// media item because they are rendered as a single UIKit surface.
    @discardableResult
    func navigateByDisplayedGroup(direction: Int) -> Bool {
        guard currentAsset?.kind == .photo, layoutAssets.count > 1 else {
            return advance(direction: direction)
        }
        let imageSizes = queue.map { CGSize(width: $0.pixelWidth, height: $0.pixelHeight) }
        let targetSize = canvasSize.width > 0 && canvasSize.height > 0
            ? canvasSize
            : UIScreen.main.bounds.size
        guard let target = PlaybackGroupResolver.nextGroupIndex(
            imageSizes: imageSizes,
            currentIndex: currentIndex,
            direction: direction,
            layout: settings.layout,
            canvasSize: targetSize,
            repeatEnabled: settings.repeatEnabled
        ) else {
            // A grouped slideshow has no valid forward destination at the
            // end when repeat is off. Do not fall back to the next raw item;
            // that would expose the second tile of the current group.
            return false
        }
        return advance(direction: direction, targetIndex: target)
    }

    @discardableResult
    private func advance(direction: Int, targetIndex: Int? = nil) -> Bool {
        guard playbackAllowed, !queue.isEmpty else { return false }
        timerTask?.cancel()
        loadTask?.cancel()
        loadGeneration &+= 1
        let generation = loadGeneration
        if let currentAsset { previousIDs.append(currentAsset.id); if previousIDs.count > 30 { previousIDs.removeFirst() } }
        let nextIndex: Int?
        if let targetIndex, queue.indices.contains(targetIndex) {
            nextIndex = targetIndex
        } else {
            nextIndex = PlaybackIndexResolver.nextIndex(current: currentIndex, count: queue.count, direction: direction, repeatEnabled: settings.repeatEnabled)
        }
        guard let nextIndex else {
            isPlaying = false
            timerTask?.cancel()
            return false
        }
        currentIndex = nextIndex
        if direction > 0, currentIndex == 0, settings.shuffleEachLoop { queue.shuffle() }
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.loadCurrent(generation: generation)
            guard !Task.isCancelled, self.loadGeneration == generation else { return }
            self.startTimer()
        }
        return true
    }

    private func loadCurrent(generation: Int) async {
        guard !Task.isCancelled, loadGeneration == generation else { return }
        guard let asset = queue.indices.contains(currentIndex) ? queue[currentIndex] : nil, let library, let loader else { return }
        currentAsset = asset
        currentImage = nil
        layoutImages = []
        layoutAssets = []
        elapsed = 0
        errorMessage = nil
        currentMediaDuration = asset.appleAsset?.duration ?? 0
        if currentMediaDuration <= 0, asset.kind == .video, let url = asset.localURL {
            if let time = try? await AVURLAsset(url: url).load(.duration), time.isNumeric {
                currentMediaDuration = time.seconds
            }
        }
        guard !Task.isCancelled, loadGeneration == generation else { return }
        let image = await loader.image(for: asset, service: library, size: CGSize(width: 1800, height: 1800))
        guard !Task.isCancelled, loadGeneration == generation else { return }
        if let image {
            currentImage = image
            layoutImages = [image]
            layoutAssets = [asset]
            let companions = companionAssets(after: asset)
            for companion in companions {
                guard !Task.isCancelled, loadGeneration == generation else { return }
                if let companionImage = await loader.image(for: companion, service: library, size: CGSize(width: 1000, height: 1000)) {
                    guard !Task.isCancelled, loadGeneration == generation else { return }
                    layoutImages.append(companionImage)
                    layoutAssets.append(companion)
                }
            }
            loader.prefetch(Array(queue.dropFirst(currentIndex + 1).prefix(4)), service: library, size: CGSize(width: 700, height: 700))
        } else { errorMessage = "This item is unavailable or still downloading from iCloud." }
    }

    private func companionAssets(after asset: CanvasMediaItem) -> [CanvasMediaItem] {
        guard settings.layout != .single, settings.layout != .fitBlurred, settings.layout != .intelligentFill, settings.layout != .solidBackground else { return [] }
        let desired: Int
        switch settings.layout { case .collageThree: desired = 2; case .gridFour: desired = 3; default: desired = 1 }
        guard desired > 0 else { return [] }
        var candidates: [CanvasMediaItem] = []
        for offset in 1..<queue.count where currentIndex + offset < queue.count {
            candidates.append(queue[currentIndex + offset])
            if candidates.count >= max(desired * 4, 8) { break }
        }

        // Automatic and smart-pair layouts should never put a portrait next
        // to a landscape merely because it happened to be next in the queue.
        // Keep looking until a same-orientation companion is found; if there
        // is none, LayoutCanvas will render the current item safely as one
        // aspect-fit tile.
        if settings.layout == .automatic || settings.layout == .portraitPair {
            let currentOrientation = PairLayoutResolver.orientation(for: CGSize(width: asset.pixelWidth, height: asset.pixelHeight))
            return candidates.filter {
                PairLayoutResolver.orientation(for: CGSize(width: $0.pixelWidth, height: $0.pixelHeight)) == currentOrientation
            }.prefix(desired).map { $0 }
        }
        return Array(candidates.prefix(desired))
    }

    private func startTimer() {
        timerTask?.cancel()
        guard playbackAllowed, isPlaying, !queue.isEmpty else { return }
        let duration: Double
        if let asset = currentAsset, asset.kind == .video {
            let appleDuration = asset.appleAsset?.duration ?? 0
            let mediaDuration = appleDuration > 0 ? appleDuration : currentMediaDuration
            duration = (settings.playFullVideo || settings.videoDuration <= 0) && mediaDuration > 0
                ? mediaDuration
                : max(settings.videoDuration, 1)
        } else if currentAsset?.kind == .livePhoto {
            duration = settings.livePhotoDuration
        } else {
            duration = settings.photoDuration
        }
        timerTask = Task { [weak self] in
            guard let self else { return }
            let tick = 0.1
            while !Task.isCancelled && self.elapsed < duration {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
                self.elapsed += tick
                self.progress = min(self.elapsed / max(duration, 0.1), 1)
            }
            if !Task.isCancelled { self.next() }
        }
    }
}
