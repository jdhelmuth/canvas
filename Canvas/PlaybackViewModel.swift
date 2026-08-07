import Foundation
import UIKit
import AVFoundation

@MainActor
final class PlaybackViewModel: ObservableObject {
    /// The media and all of its visible companions are published as one
    /// value. Publishing the asset first used to remove the outgoing frame
    /// while the next image was still loading, which left SwiftUI with no
    /// outgoing view to animate against.
    struct DisplayedFrame: Identifiable {
        let id = UUID()
        let asset: CanvasMediaItem
        let image: UIImage
        let layoutImages: [UIImage]
        let layoutAssets: [CanvasMediaItem]
        let transitionSeed: UInt64
        let gestureDirection: Int
    }

    @Published private(set) var isPlaying = true
    @Published private(set) var displayedFrame: DisplayedFrame?
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

    var currentAsset: CanvasMediaItem? { displayedFrame?.asset }
    var currentImage: UIImage? { displayedFrame?.image }
    var layoutImages: [UIImage] { displayedFrame?.layoutImages ?? [] }
    var layoutAssets: [CanvasMediaItem] { displayedFrame?.layoutAssets ?? [] }

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
        queue = QueueBuilder.build(assets, mode: settings.queueMode, repeatEnabled: settings.repeatEnabled, previousIDs: previousIDs, recentAvoidance: settings.recentAvoidance, shuffleSeed: Int.random(in: Int.min...Int.max))
        queueCount = queue.count
        currentIndex = min(currentIndex, max(0, queue.count - 1))
        await loadCurrent(generation: generation, transitionSeed: 1, gestureDirection: 0)
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

    /// Horizontal gestures and timed steps navigate by displayed groups for
    /// stills, including one-photo groups adjacent to a pair or collage.
    /// Video and Live Photo surfaces remain one media item because they are
    /// rendered as a single UIKit surface.
    @discardableResult
    func navigateByDisplayedGroup(direction: Int, gestureDirection: Int = 0) -> Bool {
        // Even a one-photo frame needs group-aware navigation: its previous
        // queue item may be the second tile of the portrait pair immediately
        // before it. Non-photo media remain single-surface boundaries.
        guard currentAsset?.kind == .photo else {
            return advance(direction: direction, gestureDirection: gestureDirection)
        }
        let imageSizes = queue.map { CGSize(width: $0.pixelWidth, height: $0.pixelHeight) }
        let singleMediaIndices = Set(queue.indices.filter { PlaybackMediaSurfacePolicy.usesSingleTile(for: queue[$0].kind) })
        let targetSize = canvasSize.width > 0 && canvasSize.height > 0
            ? canvasSize
            : UIScreen.main.bounds.size
        guard let target = PlaybackAdvancePolicy.destinationIndex(
            imageSizes: imageSizes,
            currentIndex: currentIndex,
            direction: direction,
            layout: settings.layout,
            canvasSize: targetSize,
            repeatEnabled: settings.repeatEnabled,
            usesDisplayedGroup: true,
            singleMediaIndices: singleMediaIndices
        ) else {
            // A grouped slideshow has no valid forward destination at the
            // end when repeat is off. Do not fall back to the next raw item;
            // that would expose the second tile of the current group.
            return false
        }
        return advance(direction: direction, targetIndex: target, gestureDirection: gestureDirection)
    }

    @discardableResult
    private func advance(direction: Int, targetIndex: Int? = nil, gestureDirection: Int = 0) -> Bool {
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
        let transitionSeed = UInt64.random(in: UInt64.min...UInt64.max)
        currentIndex = nextIndex
        if PlaybackAdvancePolicy.shouldShuffleAfterAdvance(
            direction: direction,
            targetIndex: targetIndex,
            currentIndex: currentIndex,
            shuffleEachLoop: settings.shuffleEachLoop
        ) {
            queue = QueueBuilder.build(
                queue,
                mode: settings.queueMode,
                repeatEnabled: true,
                previousIDs: previousIDs,
                recentAvoidance: settings.recentAvoidance,
                shuffleSeed: Int.random(in: Int.min...Int.max)
            )
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.loadCurrent(
                generation: generation,
                transitionSeed: transitionSeed,
                gestureDirection: gestureDirection
            )
            guard !Task.isCancelled, self.loadGeneration == generation else { return }
            self.startTimer()
        }
        return true
    }

    private func loadCurrent(generation: Int, transitionSeed: UInt64, gestureDirection: Int) async {
        guard !Task.isCancelled, loadGeneration == generation else { return }
        guard let asset = queue.indices.contains(currentIndex) ? queue[currentIndex] : nil, let library, let loader else { return }
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
            // Build the complete displayed group before publishing any of it.
            // Publishing the primary image first and appending a portrait
            // companion after an await changes LayoutCanvas from one tile to
            // two while its entrance transition is still active. SwiftUI can
            // then leave the group at an intermediate horizontal offset,
            // exposing a black strip along the leading edge.
            var loadedImages = [image]
            var loadedAssets = [asset]
            let companions = PlaybackMediaSurfacePolicy.allowsCompanions(for: asset.kind)
                ? companionAssets(after: asset)
                : []
            for companion in companions {
                guard !Task.isCancelled, loadGeneration == generation else { return }
                if let companionImage = await loader.image(for: companion, service: library, size: CGSize(width: 1000, height: 1000)) {
                    guard !Task.isCancelled, loadGeneration == generation else { return }
                    loadedImages.append(companionImage)
                    loadedAssets.append(companion)
                }
            }
            guard !Task.isCancelled, loadGeneration == generation else { return }
            // Commit the complete group in one publication. The previous
            // frame remains visible until this point, so every transition has
            // a real outgoing and incoming surface to animate.
            displayedFrame = DisplayedFrame(
                asset: asset,
                image: image,
                layoutImages: loadedImages,
                layoutAssets: loadedAssets,
                transitionSeed: transitionSeed,
                gestureDirection: gestureDirection
            )
            loader.prefetch(Array(queue.dropFirst(currentIndex + 1).prefix(4)), service: library, size: CGSize(width: 700, height: 700))
        } else {
            displayedFrame = nil
            errorMessage = "This item is unavailable or still downloading from iCloud."
        }
    }

    private func companionAssets(after asset: CanvasMediaItem) -> [CanvasMediaItem] {
        guard settings.layout != .single, settings.layout != .fitBlurred, settings.layout != .intelligentFill, settings.layout != .solidBackground else { return [] }
        let imageSizes = queue.map { CGSize(width: $0.pixelWidth, height: $0.pixelHeight) }
        let singleMediaIndices = Set(queue.indices.filter { PlaybackMediaSurfacePolicy.usesSingleTile(for: queue[$0].kind) })
        let targetSize = canvasSize.width > 0 && canvasSize.height > 0
            ? canvasSize
            : UIScreen.main.bounds.size
        let group = PlaybackGroupResolver.selection(
            imageSizes: imageSizes,
            currentIndex: currentIndex,
            layout: settings.layout,
            canvasSize: targetSize,
            singleMediaIndices: singleMediaIndices
        )
        guard group.indices.first == currentIndex else { return [] }
        return group.indices.dropFirst().compactMap { queue.indices.contains($0) ? queue[$0] : nil }
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
            if !Task.isCancelled {
                // Timed transitions must replace the displayed group as a
                // whole, just like a swipe, rather than advancing one tile.
                self.navigateByDisplayedGroup(direction: 1)
            }
        }
    }
}
