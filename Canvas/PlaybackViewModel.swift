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
    private var mediaItems: ((CanvasSettings) -> [CanvasMediaItem])?
    private var imageLoader: ((CanvasMediaItem, CGSize) async -> UIImage?)?
    private var prefetchImages: (([CanvasMediaItem], CGSize) -> Void)?
    private var sessionActive = true
    private var reloadTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private let recoveryDelay: Duration
    private var recoveryStartIndex: Int?
    @Published private(set) var isRecovering = false
    private var settings: CanvasSettings = .init()
    private var queue: [CanvasMediaItem] = []
    private var timerTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var previousIDs: [String] = []
    private var navigationHistory = PlaybackNavigationHistory()
    private var configured = false
    private var currentMediaDuration: Double = 0
    private var playbackAllowed = true
    private var canvasSize: CGSize = .zero
    private var loadGeneration = 0
    private var timerToken: UInt64 = 0
    private var reloadInFlight = false
    private var pendingReload = false
    private var pendingSettings: CanvasSettings?
    private var pendingQueueRebuild = false

    var currentAsset: CanvasMediaItem? { displayedFrame?.asset }
    var currentImage: UIImage? { displayedFrame?.image }
    var layoutImages: [UIImage] { displayedFrame?.layoutImages ?? [] }
    var layoutAssets: [CanvasMediaItem] { displayedFrame?.layoutAssets ?? [] }

    init(
        settings: CanvasSettings = .init(),
        mediaItems: ((CanvasSettings) -> [CanvasMediaItem])? = nil,
        imageLoader: ((CanvasMediaItem, CGSize) async -> UIImage?)? = nil,
        recoveryDelay: Duration = .seconds(30)
    ) {
        self.settings = settings
        self.mediaItems = mediaItems
        self.imageLoader = imageLoader
        self.recoveryDelay = recoveryDelay
    }

    deinit {
        timerTask?.cancel()
        loadTask?.cancel()
        reloadTask?.cancel()
        retryTask?.cancel()
    }

    func configure(library: PhotoLibraryService, googlePhotos: GooglePhotosService, loader: AssetImageLoader, settings: CanvasSettings) {
        guard !configured else { return }
        self.settings = settings
        mediaItems = { settings in
            MediaIdentityMatcher.deduplicated(
                library.mediaItems(for: settings.selectedAlbums, filters: settings.filters)
                + googlePhotos.items(for: settings.selectedAlbums, filters: settings.filters)
                + BundledPhotoLibrary.items(for: settings.selectedAlbums, filters: settings.filters)
            )
        }
        imageLoader = { item, size in await loader.image(for: item, service: library, size: size) }
        prefetchImages = { items, size in loader.prefetch(items, service: library, size: size) }
        configured = true
        sessionActive = true
        reloadTask = Task { [weak self] in await self?.reload() }
    }

    /// End the owning presentation, including work that is waiting on a provider.
    /// A late provider callback cannot publish into a closed slideshow.
    func stop() {
        sessionActive = false
        playbackAllowed = false
        loadGeneration &+= 1
        cancelTimer()
        loadTask?.cancel()
        loadTask = nil
        reloadTask?.cancel()
        reloadTask = nil
        retryTask?.cancel()
        retryTask = nil
        pendingReload = false
        pendingSettings = nil
        pendingQueueRebuild = false
        displayedFrame = nil
        queue = []
        queueCount = 0
        navigationHistory = PlaybackNavigationHistory()
        mediaItems = nil
        imageLoader = nil
        prefetchImages = nil
        configured = false
    }

    func refreshLibrary() async {
        await reload()
    }

    /// Coalesces provider/settings notifications while the current frame is
    /// loading. Photos can report several changes during startup; each
    /// notification must not cancel and restart the same first frame.
    func reload(settings updatedSettings: CanvasSettings? = nil, rebuildQueue: Bool = false) async {
        guard sessionActive else { return }
        if reloadInFlight {
            pendingReload = true
            if let updatedSettings { pendingSettings = updatedSettings }
            pendingQueueRebuild = pendingQueueRebuild || rebuildQueue
            return
        }

        reloadInFlight = true
        defer {
            reloadInFlight = false
            if !pendingReload || Task.isCancelled || !sessionActive {
                pendingReload = false
                pendingSettings = nil
                pendingQueueRebuild = false
            } else {
                let nextSettings = pendingSettings
                let nextQueueRebuild = pendingQueueRebuild
                pendingReload = false
                pendingSettings = nil
                pendingQueueRebuild = false
                reloadTask = Task { [weak self] in
                    await self?.reload(settings: nextSettings, rebuildQueue: nextQueueRebuild)
                }
            }
        }

        await performReload(settings: updatedSettings, rebuildQueue: rebuildQueue)
    }

    private func performReload(settings updatedSettings: CanvasSettings?, rebuildQueue: Bool) async {
        guard let mediaItems, sessionActive else { return }
        if let updatedSettings { settings = updatedSettings }

        let assets = mediaItems(settings)
        let queueCurrentAssetID = queue.indices.contains(currentIndex) ? queue[currentIndex].id : nil
        let displayedAssetID = displayedFrame?.asset.id
        let identityToPreserve = queueCurrentAssetID ?? displayedAssetID
        let candidateQueue: [CanvasMediaItem]
        if rebuildQueue {
            candidateQueue = QueueBuilder.build(
                assets,
                mode: settings.queueMode,
                repeatEnabled: settings.repeatEnabled,
                previousIDs: previousIDs,
                recentAvoidance: settings.recentAvoidance,
                shuffleSeed: Int.random(in: Int.min...Int.max)
            )
        } else {
            candidateQueue = QueueBuilder.refresh(
                queue,
                with: assets,
                mode: settings.queueMode,
                repeatEnabled: settings.repeatEnabled,
                previousIDs: previousIDs,
                recentAvoidance: settings.recentAvoidance,
                shuffleSeed: Int.random(in: Int.min...Int.max)
            )
        }
        let candidateIndex = PlaybackQueueIdentity.index(
            for: identityToPreserve,
            in: candidateQueue,
            fallbackIndex: currentIndex
        )
        let canPreserveFrame = PlaybackQueueIdentity.canPreserveDisplayedFrame(
            currentAssetID: displayedAssetID,
            queueCurrentAssetID: queueCurrentAssetID,
            displayedGroupIDs: displayedFrame?.layoutAssets.map(\.id) ?? [],
            candidateQueue: candidateQueue,
            forceReload: rebuildQueue
        )

        queue = candidateQueue
        queueCount = queue.count
        currentIndex = candidateIndex
        recoveryStartIndex = nil

        if canPreserveFrame && !isRecovering {
            // Keep the current visual frame and its transition route intact;
            // only the future queue may have changed underneath it.
            navigationHistory.reset(to: currentPosition)
            startTimer()
            return
        }

        cancelTimer()
        retryTask?.cancel()
        loadTask?.cancel()
        loadGeneration &+= 1
        let generation = loadGeneration
        navigationHistory = PlaybackNavigationHistory()

        guard !queue.isEmpty else {
            displayedFrame = nil
            errorMessage = "Choose an album with playable media to start Canvas."
            return
        }

        guard playbackAllowed else { return }
        await loadCurrent(generation: generation, transitionSeed: 1, gestureDirection: 0)
        guard !Task.isCancelled, loadGeneration == generation else { return }
        if displayedFrame != nil, queue.indices.contains(currentIndex) {
            navigationHistory.reset(to: currentPosition)
        }
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
        if requiresReload {
            await reload(settings: updatedSettings, rebuildQueue: true)
        } else {
            settings = updatedSettings
            startTimer()
        }
    }

    /// Schedules and power limits gate the frame without changing the user's
    /// play/pause preference. The timer is cancelled while gated so a hidden
    /// slideshow cannot advance items behind the waiting screen.
    func setPlaybackAllowed(_ allowed: Bool) {
        guard sessionActive else { return }
        let changed = playbackAllowed != allowed
        playbackAllowed = allowed
        if allowed {
            if changed && needsFrameLoad {
                scheduleLoad(generation: loadGeneration, transitionSeed: 1, gestureDirection: 0)
            } else {
                startTimer()
            }
        } else {
            cancelTimer()
            retryTask?.cancel()
            loadTask?.cancel()
            if changed { loadGeneration &+= 1 }
        }
    }

    private var needsFrameLoad: Bool {
        isRecovering || (queue.indices.contains(currentIndex) && queue[currentIndex].id != currentAsset?.id)
    }

    func togglePlaying() {
        guard sessionActive else { return }
        isPlaying.toggle()
        if isPlaying {
            if needsFrameLoad && playbackAllowed {
                scheduleLoad(generation: loadGeneration, transitionSeed: 1, gestureDirection: 0)
            } else { startTimer() }
        } else {
            cancelTimer()
            retryTask?.cancel()
        }
    }
    @discardableResult func next() -> Bool { navigateByDisplayedGroup(direction: 1) }
    @discardableResult func previous() -> Bool { navigateByDisplayedGroup(direction: -1) }

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
        // If the user is moving through frames that were already shown, replay
        // the recorded route before asking the current queue for a new target.
        // This is what keeps Back tied to playback history after a reshuffle.
        if navigationHistory.canMove(direction: direction) {
            return advance(direction: direction, gestureDirection: gestureDirection)
        }

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
            isPlaying = false
            cancelTimer()
            return false
        }
        return advance(direction: direction, targetIndex: target, gestureDirection: gestureDirection)
    }

    @discardableResult
    private func advance(direction: Int, targetIndex: Int? = nil, gestureDirection: Int = 0) -> Bool {
        guard sessionActive, playbackAllowed, !queue.isEmpty else { return false }
        recoveryStartIndex = nil
        cancelTimer()
        retryTask?.cancel()
        loadTask?.cancel()
        loadGeneration &+= 1
        let generation = loadGeneration
        if let currentAsset { previousIDs.append(currentAsset.id); if previousIDs.count > 30 { previousIDs.removeFirst() } }

        if let historicalPosition = navigationHistory.move(direction: direction) {
            queue = historicalPosition.queue
            queueCount = queue.count
            currentIndex = historicalPosition.currentIndex
            let transitionSeed = UInt64.random(in: UInt64.min...UInt64.max)
            scheduleLoad(
                generation: generation,
                transitionSeed: transitionSeed,
                gestureDirection: gestureDirection
            )
            return true
        }

        let nextIndex: Int?
        if let targetIndex, queue.indices.contains(targetIndex) {
            nextIndex = targetIndex
        } else {
            nextIndex = PlaybackIndexResolver.nextIndex(current: currentIndex, count: queue.count, direction: direction, repeatEnabled: settings.repeatEnabled)
        }
        guard let nextIndex else {
            isPlaying = false
            cancelTimer()
            return false
        }
        let recentlyDisplayedIDs = displayedFrame?.layoutAssets.map(\.id) ?? currentAsset.map { [$0.id] } ?? []
        let transitionSeed = UInt64.random(in: UInt64.min...UInt64.max)
        currentIndex = nextIndex
        if PlaybackAdvancePolicy.shouldShuffleAfterAdvance(
            direction: direction,
            targetIndex: targetIndex,
            currentIndex: currentIndex,
            shuffleEachLoop: settings.shuffleEachLoop
        ) {
            queue = QueueBuilder.buildNextCycle(
                queue,
                mode: settings.queueMode,
                previousIDs: recentlyDisplayedIDs,
                shuffleSeed: Int.random(in: Int.min...Int.max)
            )
            currentIndex = 0
        }
        navigationHistory.append(currentPosition)
        scheduleLoad(
            generation: generation,
            transitionSeed: transitionSeed,
            gestureDirection: gestureDirection
        )
        return true
    }

    private var currentPosition: PlaybackHistoryPosition {
        PlaybackHistoryPosition(queue: queue, currentIndex: currentIndex)
    }

    private func scheduleLoad(generation: Int, transitionSeed: UInt64, gestureDirection: Int) {
        guard sessionActive, playbackAllowed else { return }
        retryTask?.cancel()
        loadTask?.cancel()
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
    }

    private func loadCurrent(generation: Int, transitionSeed: UInt64, gestureDirection: Int) async {
        // Visit each available item at most once in a recovery pass. Keep the
        // last good frame visible while skipping unavailable primary images.
        if let recoveryStartIndex, queue.indices.contains(recoveryStartIndex) {
            currentIndex = recoveryStartIndex
        }
        let firstAttemptIndex = currentIndex
        var attempted = 0
        while attempted < queue.count {
            guard sessionActive, playbackAllowed, !Task.isCancelled, loadGeneration == generation else { return }
            if await loadFrame(generation: generation, transitionSeed: transitionSeed, gestureDirection: gestureDirection) {
                isRecovering = false
                recoveryStartIndex = nil
                errorMessage = nil
                if attempted > 0 { navigationHistory.reset(to: currentPosition) }
                return
            }
            guard sessionActive, playbackAllowed, !Task.isCancelled, loadGeneration == generation else { return }
            attempted += 1
            guard attempted < queue.count,
                  let next = PlaybackIndexResolver.nextIndex(current: currentIndex, count: queue.count, direction: 1, repeatEnabled: settings.repeatEnabled) else { break }
            currentIndex = next
        }
        guard sessionActive, !Task.isCancelled, loadGeneration == generation else { return }
        if let currentAsset, let retainedIndex = queue.firstIndex(where: { $0.id == currentAsset.id }) {
            currentIndex = retainedIndex
        }
        recoveryStartIndex = firstAttemptIndex
        isRecovering = true
        errorMessage = "Photos are temporarily unavailable. Canvas will try again shortly."
        scheduleRecovery(generation: generation)
    }

    private func scheduleRecovery(generation: Int) {
        retryTask?.cancel()
        guard sessionActive, playbackAllowed, isPlaying, !queue.isEmpty else { return }
        let delay = recoveryDelay
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.sessionActive, self.playbackAllowed, self.isPlaying,
                  self.loadGeneration == generation else { return }
            self.scheduleLoad(generation: generation, transitionSeed: 1, gestureDirection: 0)
        }
    }

    private func loadFrame(generation: Int, transitionSeed: UInt64, gestureDirection: Int) async -> Bool {
        guard !Task.isCancelled, loadGeneration == generation else { return false }
        guard let asset = queue.indices.contains(currentIndex) ? queue[currentIndex] : nil, let imageLoader else { return false }
        elapsed = 0
        progress = 0
        errorMessage = nil
        currentMediaDuration = asset.appleAsset?.duration ?? 0
        if currentMediaDuration <= 0, asset.kind == .video, let url = asset.localURL {
            if let time = try? await AVURLAsset(url: url).load(.duration), time.isNumeric {
                currentMediaDuration = time.seconds
            }
        }
        guard !Task.isCancelled, loadGeneration == generation else { return false }
        let image = await imageLoader(asset, CGSize(width: 1800, height: 1800))
        guard !Task.isCancelled, loadGeneration == generation else { return false }
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
                guard !Task.isCancelled, loadGeneration == generation else { return false }
                if let companionImage = await imageLoader(companion, CGSize(width: 1000, height: 1000)) {
                    guard !Task.isCancelled, loadGeneration == generation else { return false }
                    loadedImages.append(companionImage)
                    loadedAssets.append(companion)
                }
            }
            guard !Task.isCancelled, loadGeneration == generation else { return false }
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
            prefetchImages?(Array(queue.dropFirst(currentIndex + 1).prefix(4)), CGSize(width: 700, height: 700))
            return true
        }
        return false
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
        cancelTimer()
        guard sessionActive, playbackAllowed, isPlaying, !isRecovering, !queue.isEmpty,
              let frame = displayedFrame,
              let currentAsset else { return }

        let duration = PlaybackTimingPolicy.duration(
            for: currentAsset.kind,
            settings: settings,
            mediaDuration: currentMediaDuration
        )
        let generation = loadGeneration
        let frameID = frame.id
        let token = timerToken
        let initialElapsed = min(max(elapsed, 0), duration)
        let startedAt = Date()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, self.sessionActive, !Task.isCancelled,
                      self.timerToken == token,
                      self.loadGeneration == generation,
                      self.displayedFrame?.id == frameID,
                      self.playbackAllowed,
                      self.isPlaying else { return }

                let elapsed = min(duration, initialElapsed + Date().timeIntervalSince(startedAt))
                self.elapsed = elapsed
                self.progress = min(elapsed / duration, 1)
                guard elapsed >= duration else { continue }

                // Timed transitions must replace the displayed group as a
                // whole, just like a swipe, rather than advancing one tile.
                self.navigateByDisplayedGroup(direction: 1)
                return
            }
        }
    }

    private func cancelTimer() {
        timerToken &+= 1
        timerTask?.cancel()
        timerTask = nil
    }
}
