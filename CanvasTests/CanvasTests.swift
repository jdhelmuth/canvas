import XCTest
import AVFoundation
import Combine
import CoreLocation
import Photos
import PhotosUI
@testable import Canvas

final class CanvasTests: XCTestCase {
    @MainActor
    func testAssetImageLoaderUsesBoundedMemoryCache() {
        let loader = AssetImageLoader()

        XCTAssertEqual(loader.cache.countLimit, AssetImageLoader.cacheCountLimit)
        XCTAssertEqual(loader.cache.totalCostLimit, AssetImageLoader.cacheTotalCostLimit)
    }

    func testShuffleIsDeterministicForSeed() {
        let ids = ["a", "b", "c", "d", "e"]
        XCTAssertEqual(QueueAlgorithm.orderedIDs(ids, mode: .shuffle, seed: 42), QueueAlgorithm.orderedIDs(ids, mode: .shuffle, seed: 42))
        XCTAssertNotEqual(QueueAlgorithm.orderedIDs(ids, mode: .shuffle, seed: 42), ids)
    }

    func testQueueShuffleSamplesEverySelectedLibraryBeforeRepeatingALargeLibrary() {
        let assets = (0..<12).map { index in
            CanvasMediaItem(
                id: "apple:\(index)",
                source: .applePhotos,
                kind: .photo,
                creationDate: nil,
                filename: "photo-\(index).jpg",
                isFavorite: false,
                pixelWidth: 100,
                pixelHeight: 100,
                albumTitle: index < 10 ? "Large album" : "Small album",
                appleAsset: nil,
                localURL: nil,
                contentHash: nil,
                libraryID: index < 10 ? "large-library" : (index == 10 ? "small-library-a" : "small-library-b")
            )
        }

        let queue = QueueBuilder.build(assets, mode: .shuffle, repeatEnabled: true, shuffleSeed: 42)
        XCTAssertEqual(queue.map(\.id).count, assets.count)
        XCTAssertEqual(Set(queue.prefix(3).compactMap(\.libraryID)), Set(["large-library", "small-library-a", "small-library-b"]))
        XCTAssertEqual(Set(queue.map(\.id)), Set(assets.map(\.id)))
    }

    func testQueueShuffleSeedChangesTheOrderForFreshSessions() {
        let assets = (0..<8).map { index in
            CanvasMediaItem(
                id: "apple:\(index)",
                source: .applePhotos,
                kind: .photo,
                creationDate: nil,
                filename: "photo-\(index).jpg",
                isFavorite: false,
                pixelWidth: 100,
                pixelHeight: 100,
                albumTitle: index < 4 ? "Family" : "Travel",
                appleAsset: nil,
                localURL: nil,
                contentHash: nil
            )
        }

        let first = QueueBuilder.build(assets, mode: .shuffle, repeatEnabled: true, shuffleSeed: 1).map(\.id)
        let second = QueueBuilder.build(assets, mode: .shuffle, repeatEnabled: true, shuffleSeed: 2).map(\.id)
        XCTAssertNotEqual(first, second)
    }

    func testQueueBuilderDeduplicatesRepeatedAssetIDsWithinACycle() {
        let first = CanvasMediaItem(
            id: "apple:duplicate",
            source: .applePhotos,
            kind: .photo,
            creationDate: nil,
            filename: "first.jpg",
            isFavorite: false,
            pixelWidth: 1600,
            pixelHeight: 900,
            albumTitle: "Family",
            appleAsset: nil,
            localURL: nil,
            contentHash: nil
        )
        let replacement = CanvasMediaItem(
            id: first.id,
            source: first.source,
            kind: first.kind,
            creationDate: first.creationDate,
            filename: "replacement.jpg",
            isFavorite: first.isFavorite,
            pixelWidth: first.pixelWidth,
            pixelHeight: first.pixelHeight,
            albumTitle: first.albumTitle,
            appleAsset: nil,
            localURL: nil,
            contentHash: nil
        )

        let queue = QueueBuilder.build([first, replacement], mode: .shuffle, repeatEnabled: true, shuffleSeed: 42)

        XCTAssertEqual(queue.map(\.id), [first.id])
        XCTAssertEqual(queue.first?.filename, first.filename)
    }

    func testNextCycleIncludesEveryItemOnceAndMovesOutgoingGroupAwayFromBoundary() {
        let assets = (0..<8).map { index in
            CanvasMediaItem(
                id: "apple:cycle-\(index)",
                source: .applePhotos,
                kind: .photo,
                creationDate: nil,
                filename: "cycle-\(index).jpg",
                isFavorite: false,
                pixelWidth: 1600,
                pixelHeight: 900,
                albumTitle: "Family",
                appleAsset: nil,
                localURL: nil,
                contentHash: nil
            )
        }
        let next = QueueBuilder.buildNextCycle(
            assets,
            mode: .shuffle,
            previousIDs: [assets[6].id, assets[7].id],
            shuffleSeed: 42
        )

        XCTAssertEqual(next.count, assets.count)
        XCTAssertEqual(Set(next.map(\.id)), Set(assets.map(\.id)))
        XCTAssertEqual(Set(next.map(\.id)).count, next.count)
        XCTAssertFalse([assets[6].id, assets[7].id].contains(next[0].id))
    }

    func testProviderRefreshPreservesStartedQueueAndAdvancesPastFirstItemOnce() {
        let assets = (0..<4).map { index in
            CanvasMediaItem(
                id: "apple:startup-\(index)",
                source: .applePhotos,
                kind: .photo,
                creationDate: nil,
                filename: "startup-\(index).jpg",
                isFavorite: false,
                pixelWidth: 1600,
                pixelHeight: 900,
                albumTitle: "Frame",
                appleAsset: nil,
                localURL: nil,
                contentHash: nil
            )
        }
        XCTAssertEqual(assets.map(\.id), ["apple:startup-0", "apple:startup-1", "apple:startup-2", "apple:startup-3"])
        let initial = QueueBuilder.build(assets, mode: .shuffle, repeatEnabled: true, shuffleSeed: 42)
        var refreshed = QueueBuilder.refresh(initial, with: assets, mode: .shuffle, repeatEnabled: true, shuffleSeed: 99)
        let firstID = initial[0].id

        XCTAssertEqual(refreshed.map(\.id), initial.map(\.id))
        for _ in 0..<3 {
            XCTAssertTrue(
                PlaybackQueueIdentity.canPreserveDisplayedFrame(
                    currentAssetID: firstID,
                    queueCurrentAssetID: firstID,
                    displayedGroupIDs: [firstID],
                    candidateQueue: refreshed,
                    forceReload: false
                )
            )
            refreshed = QueueBuilder.refresh(refreshed, with: assets, mode: .shuffle, repeatEnabled: true, shuffleSeed: 99)
            XCTAssertEqual(refreshed.map(\.id), initial.map(\.id))
            XCTAssertEqual(Set(refreshed.map(\.id)), Set(assets.map(\.id)))
        }

        let currentIndex = PlaybackQueueIdentity.index(for: firstID, in: refreshed, fallbackIndex: 0)
        let nextIndex = PlaybackAdvancePolicy.destinationIndex(
            imageSizes: refreshed.map { CGSize(width: $0.pixelWidth, height: $0.pixelHeight) },
            currentIndex: currentIndex,
            direction: 1,
            layout: .single,
            canvasSize: CGSize(width: 1194, height: 834),
            repeatEnabled: true,
            usesDisplayedGroup: true
        )

        XCTAssertEqual(nextIndex, (currentIndex + 1) % refreshed.count)
        XCTAssertNotEqual(nextIndex, currentIndex)
        XCTAssertEqual(refreshed[nextIndex ?? 0].id, initial[(initial.firstIndex { $0.id == firstID }! + 1) % initial.count].id)
    }

    func testQueueShuffleMixesOrientationRunsWithoutDroppingMedia() {
        let assets = (0..<12).map { index in
            let isPortrait = index < 6
            return CanvasMediaItem(
                id: "apple:\(index)",
                source: .applePhotos,
                kind: .photo,
                creationDate: nil,
                filename: "photo-\(index).jpg",
                isFavorite: false,
                pixelWidth: isPortrait ? 900 : 1600,
                pixelHeight: isPortrait ? 1400 : 900,
                albumTitle: "Family",
                appleAsset: nil,
                localURL: nil,
                contentHash: nil
            )
        }

        let queue = QueueBuilder.build(assets, mode: .shuffle, repeatEnabled: true, shuffleSeed: 42)
        let orientations = queue.map { PairLayoutResolver.orientation(for: CGSize(width: $0.pixelWidth, height: $0.pixelHeight)) }
        var initialRun = 0
        while initialRun < orientations.count, orientations[initialRun] == orientations.first {
            initialRun += 1
        }

        XCTAssertEqual(Set(queue.map(\.id)), Set(assets.map(\.id)))
        XCTAssertLessThanOrEqual(initialRun, 2)
    }

    func testLinearQueueAndFavoriteOrdering() {
        let ids = ["a", "b", "c"]
        let dates: [String: Date] = ["a": Date(timeIntervalSince1970: 30), "b": Date(timeIntervalSince1970: 10), "c": Date(timeIntervalSince1970: 20)]
        XCTAssertEqual(QueueAlgorithm.orderedIDs(ids, mode: .oldestFirst, dates: dates), ["b", "c", "a"])
        XCTAssertEqual(QueueAlgorithm.orderedIDs(ids, mode: .favoritesFirst, favorites: ["c"]), ["c", "a", "b"])
    }

    func testRecentAvoidanceMovesRecentItemsToTail() {
        XCTAssertEqual(QueueAlgorithm.applyingRecentAvoidance(["a", "b", "c", "d"], previous: ["b", "c"], count: 2), ["a", "d", "b", "c"])
    }

    func testFilterMediaAndDates() {
        var filters = CanvasFilters(); filters.includeVideos = false; filters.favoritesOnly = true
        let asset = MediaDescriptor(id: "v", kind: .video, creationDate: Date(), modificationDate: nil, filename: "v", isFavorite: true, pixelWidth: 100, pixelHeight: 100, albumTitles: [])
        XCTAssertFalse(filters.accepts(asset))
    }

    func testFilterScreenshotsBurstsAndLocation() {
        var filters = CanvasFilters(); filters.includeScreenshots = false; filters.includeBursts = false; filters.locationTaggedOnly = true
        let asset = MediaDescriptor(id: "photo", kind: .photo, creationDate: Date(), modificationDate: nil, filename: "photo", isFavorite: false, pixelWidth: 100, pixelHeight: 100, albumTitles: [], isScreenshot: true, isBurst: true, hasLocation: false)
        XCTAssertFalse(filters.accepts(asset))
        filters.includeScreenshots = true; filters.includeBursts = true; filters.locationTaggedOnly = false
        XCTAssertTrue(filters.accepts(asset))
    }

    func testTransitionReduceMotionAndExclusions() {
        XCTAssertEqual(TransitionEngine.choose(preferred: .zoomIn, random: false, excluded: [], reduceMotion: true), .crossfade)
        XCTAssertFalse(TransitionStyle.allCases.filter { !$0.isReduceMotionSafe }.isEmpty)
    }

    func testRandomTransitionSelectionUsesAllowedStylesAndChangesWithSeed() {
        let excluded: Set<TransitionStyle> = [.crossfade]
        let allowed = Set(TransitionStyle.allCases).subtracting(excluded).subtracting([.cut])
        let selections = Set((1...24).map { seed in
            TransitionEngine.choose(
                preferred: .crossfade,
                random: true,
                excluded: excluded,
                reduceMotion: false,
                seed: UInt64(seed)
            )
        })

        XCTAssertTrue(selections.isSubset(of: allowed))
        XCTAssertFalse(selections.contains(.cut))
        XCTAssertGreaterThan(selections.count, 1)
    }

    func testCompletedFrameTransitionsAlwaysRestoreIncomingIdentity() {
        let canvasSize = CGSize(width: 1194, height: 834)

        for style in TransitionStyle.allCases {
            let state = CanvasFrameTransitionGeometry.state(
                style: style,
                role: .incoming,
                progress: 1,
                canvasSize: canvasSize
            )

            XCTAssertEqual(state.scale, 1, accuracy: 0.0001, style.title)
            XCTAssertEqual(state.opacity, 1, accuracy: 0.0001, style.title)
            XCTAssertEqual(state.blur, 0, accuracy: 0.0001, style.title)
            XCTAssertEqual(state.offset.width, 0, accuracy: 0.0001, style.title)
            XCTAssertEqual(state.offset.height, 0, accuracy: 0.0001, style.title)
            XCTAssertEqual(state.rotationDegrees, 0, accuracy: 0.0001, style.title)
        }
    }

    func testCrossfadeNeverTranslatesOrScalesPairedFrame() {
        let canvasSize = CGSize(width: 1194, height: 834)

        for step in 0...20 {
            let state = CanvasFrameTransitionGeometry.state(
                style: .crossfade,
                role: .incoming,
                progress: CGFloat(step) / 20,
                canvasSize: canvasSize
            )
            XCTAssertEqual(state.scale, 1, accuracy: 0.0001)
            XCTAssertEqual(state.offset, .zero)
            XCTAssertEqual(state.rotationDegrees, 0, accuracy: 0.0001)
        }
    }

    func testGestureDirectionIsResolvedOnceWithoutChangingTimedCrossfade() {
        XCTAssertEqual(
            TransitionEngine.resolvedStyle(
                preferred: .crossfade,
                random: false,
                excluded: [],
                reduceMotion: false,
                seed: 1,
                gestureDirection: 1
            ),
            .slideLeft
        )
        XCTAssertEqual(
            TransitionEngine.resolvedStyle(
                preferred: .crossfade,
                random: false,
                excluded: [],
                reduceMotion: false,
                seed: 1,
                gestureDirection: 0
            ),
            .crossfade
        )
        XCTAssertEqual(
            TransitionEngine.resolvedStyle(
                preferred: .pageSwipe,
                random: false,
                excluded: [],
                reduceMotion: true,
                seed: 1,
                gestureDirection: -1
            ),
            .crossfade
        )
    }

    func testOverlayTextStrokeDefaultsAreBackwardCompatibleAndBounded() {
        let settings = OverlaySettings()
        XCTAssertFalse(OverlayTextStrokePolicy.isEnabled(settings.textStrokeEnabled))
        XCTAssertEqual(OverlayTextStrokePolicy.width(nil), 1.5, accuracy: 0.001)
        XCTAssertEqual(OverlayTextStrokePolicy.width(-4), 0.5, accuracy: 0.001)
        XCTAssertEqual(OverlayTextStrokePolicy.width(20), 6, accuracy: 0.001)
        XCTAssertEqual(OverlayTextStrokePolicy.color(.orange, mediaImage: nil), .orange)
    }

    func testSupportingTextStyleIsIndependentFromClockStyleWithLegacyStrokeFallback() {
        var settings = OverlaySettings()
        XCTAssertEqual(settings.effectiveTextWeight, .regular)
        XCTAssertFalse(settings.effectiveClockStrokeEnabled)

        settings.textWeight = .bold
        settings.clockWeight = .regular
        settings.textStrokeEnabled = true
        settings.textStrokeColor = .cyan
        settings.textStrokeWidth = 4

        // Simulate a pre-separation persisted value. It inherits the old
        // shared stroke until the settings store migrates it.
        settings.clockStrokeEnabled = nil
        settings.clockStrokeColor = nil
        settings.clockStrokeWidth = nil

        XCTAssertEqual(settings.effectiveTextWeight, .bold)
        XCTAssertEqual(settings.clockWeight, .regular)
        XCTAssertTrue(settings.effectiveClockStrokeEnabled)
        XCTAssertEqual(settings.effectiveClockStrokeColor, .cyan)
        XCTAssertEqual(settings.effectiveClockStrokeWidth, 4, accuracy: 0.001)

        settings.clockStrokeEnabled = false
        settings.clockStrokeColor = .orange
        settings.clockStrokeWidth = 1
        XCTAssertFalse(settings.effectiveClockStrokeEnabled)
        XCTAssertEqual(settings.effectiveClockStrokeColor, .orange)
        XCTAssertEqual(settings.effectiveClockStrokeWidth, 1, accuracy: 0.001)
    }

    func testPairLayoutRulesAcrossDeviceOrientations() {
        let portraits = [CGSize(width: 900, height: 1400), CGSize(width: 1000, height: 1500)]
        let landscapes = [CGSize(width: 1600, height: 900), CGSize(width: 1400, height: 1000)]
        XCTAssertEqual(PairLayoutResolver.style(imageSizes: portraits, canvasSize: CGSize(width: 1024, height: 1366)), .fitBlurred)
        XCTAssertEqual(PairLayoutResolver.style(imageSizes: landscapes, canvasSize: CGSize(width: 1024, height: 1366)), .pairVertical)
        XCTAssertEqual(PairLayoutResolver.style(imageSizes: portraits, canvasSize: CGSize(width: 1366, height: 1024)), .pairHorizontal)
        XCTAssertEqual(PairLayoutResolver.style(imageSizes: landscapes, canvasSize: CGSize(width: 1366, height: 1024)), .fitBlurred)
        XCTAssertEqual(PairLayoutResolver.style(imageSizes: [portraits[0], landscapes[0]], canvasSize: CGSize(width: 1024, height: 1366)), .fitBlurred)
        XCTAssertEqual(PairLayoutResolver.style(imageSizes: [CGSize.zero, landscapes[0]], canvasSize: CGSize(width: 1024, height: 1366)), .fitBlurred)
    }

    func testPairLayoutUsesAvailableCompatibleCompanionAndSafeFallback() {
        let portraitCanvas = CGSize(width: 1024, height: 1366)
        let landscapeCanvas = CGSize(width: 1366, height: 1024)
        let portrait = CGSize(width: 900, height: 1400)
        let landscape = CGSize(width: 1600, height: 900)

        let portraitPair = PairLayoutResolver.selection(imageSizes: [landscape, landscape], canvasSize: portraitCanvas)
        XCTAssertEqual(portraitPair.style, .pairVertical)
        XCTAssertEqual(portraitPair.indices, [0, 1])

        let landscapePair = PairLayoutResolver.selection(imageSizes: [portrait, CGSize(width: 400, height: 700), landscape, portrait], canvasSize: landscapeCanvas)
        XCTAssertEqual(landscapePair.style, .pairHorizontal)
        XCTAssertEqual(landscapePair.indices, [0, 1])

        let singleIncompatible = PairLayoutResolver.selection(imageSizes: [landscape], canvasSize: landscapeCanvas)
        XCTAssertEqual(singleIncompatible.style, .fitBlurred)
        XCTAssertEqual(singleIncompatible.indices, [0])

        let singlePortraitOnPortrait = PairLayoutResolver.selection(imageSizes: [portrait], canvasSize: portraitCanvas)
        XCTAssertEqual(singlePortraitOnPortrait.style, .fitBlurred)
    }

    func testExplicitPairLayoutsKeepLandscapePhotosSoloOnLandscapeIPad() {
        let landscapeCanvas = CGSize(width: 1366, height: 1024)
        let portraitCanvas = CGSize(width: 1024, height: 1366)
        let portrait = CGSize(width: 900, height: 1400)
        let landscape = CGSize(width: 1600, height: 900)

        // A landscape iPad pairs portraits horizontally, but a landscape
        // source is always its own full-screen group.
        XCTAssertEqual(
            PairLayoutResolver.selection(
                imageSizes: [portrait, portrait],
                canvasSize: landscapeCanvas,
                requestedLayout: .pairHorizontal
            ),
            PairLayoutSelection(style: .pairHorizontal, indices: [0, 1])
        )
        XCTAssertEqual(
            PairLayoutResolver.selection(
                imageSizes: [landscape, landscape],
                canvasSize: landscapeCanvas,
                requestedLayout: .pairHorizontal
            ),
            PairLayoutSelection(style: .fitBlurred, indices: [0])
        )
        XCTAssertEqual(
            PairLayoutResolver.selection(
                imageSizes: [portrait, landscape],
                canvasSize: landscapeCanvas,
                requestedLayout: .pairHorizontal
            ),
            PairLayoutSelection(style: .single, indices: [0])
        )

        // On a portrait iPad, landscape photos are the compatible vertical
        // pair orientation requested by the product behavior.
        XCTAssertEqual(
            PairLayoutResolver.selection(
                imageSizes: [landscape, landscape],
                canvasSize: portraitCanvas,
                requestedLayout: .pairVertical
            ),
            PairLayoutSelection(style: .pairVertical, indices: [0, 1])
        )

        let mixedQueue = [portrait, landscape, portrait, portrait, landscape]
        XCTAssertEqual(
            PlaybackGroupResolver.groupStarts(
                imageSizes: mixedQueue,
                layout: .pairHorizontal,
                canvasSize: landscapeCanvas
            ),
            [0, 1, 2, 4]
        )
        XCTAssertEqual(
            CaptureDateOverlayGeometry.tileFrames(
                imageSizes: [landscape, landscape],
                style: .pairHorizontal,
                canvasSize: landscapeCanvas,
                spacing: 8
            ).count,
            1
        )
    }

    func testAutomaticPairingDoesNotSkipAnIncompatibleSinglePhoto() {
        let portrait = CGSize(width: 900, height: 1400)
        let landscape = CGSize(width: 1600, height: 900)
        let canvasSize = CGSize(width: 1366, height: 1024)

        XCTAssertEqual(
            PairLayoutResolver.selection(imageSizes: [portrait, landscape, portrait], canvasSize: canvasSize).indices,
            [0]
        )
        XCTAssertEqual(
            PlaybackGroupResolver.groupStarts(
                imageSizes: [portrait, landscape, portrait, portrait, landscape],
                layout: .automatic,
                canvasSize: canvasSize
            ),
            [0, 1, 2, 4]
        )
    }

    @MainActor
    func testWeatherOverlayWaitsForLocationPermissionBeforeRequestingWeather() {
        let service = CanvasWeatherService(autoRequestLocation: false)
        service.update(showWeather: true)
        XCTAssertEqual(service.status, .needsLocationPermission)
        XCTAssertFalse(service.isLoading)
        XCTAssertTrue(service.errorMessage?.contains("location") == true)

        service.update(showWeather: false)
        XCTAssertEqual(service.status, .disabled)
    }

    func testAmbientTemperatureFormattingNormalizesLivePreviewAndConvertedValues() throws {
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(CanvasWeatherTemperatureFormatter.normalized("72°F", locale: locale), "72.0°F")
        XCTAssertEqual(CanvasWeatherTemperatureFormatter.normalized("22°C", locale: locale), "71.6°F")

        let snapshot = CanvasWeatherSnapshot(
            symbolName: "sun.max.fill",
            condition: "Clear",
            temperature: "72°F",
            apparentTemperature: "70°F",
            highTemperature: "78°F",
            lowTemperature: "61°F",
            nextHourTemperature: "74°F"
        )
        XCTAssertEqual(snapshot.temperature, "72.0°F")
        XCTAssertEqual(snapshot.apparentTemperature, "70.0°F")
        XCTAssertEqual(snapshot.highTemperature, "78.0°F")
        XCTAssertEqual(snapshot.lowTemperature, "61.0°F")
        XCTAssertEqual(snapshot.nextHourTemperature, "74.0°F")
        XCTAssertEqual(CanvasWeatherSnapshot.preview.temperature, "72.0°F")
    }

    func testCachedLegacyWeatherTemperaturesNormalizeEveryTemperatureSurface() throws {
        let legacyJSON = Data(#"{"symbolName":"sun.max.fill","condition":"Clear","temperature":"72°F","apparentTemperature":"70°F","highTemperature":"78°F","lowTemperature":"61°F","nextHourTemperature":"74°F","updatedAt":0}"#.utf8)
        let snapshot = try JSONDecoder().decode(CanvasWeatherSnapshot.self, from: legacyJSON)

        XCTAssertEqual(snapshot.temperature, "72.0°F")
        XCTAssertEqual(snapshot.apparentTemperature, "70.0°F")
        XCTAssertEqual(snapshot.highTemperature, "78.0°F")
        XCTAssertEqual(snapshot.lowTemperature, "61.0°F")
        XCTAssertEqual(snapshot.nextHourTemperature, "74.0°F")
    }

    @MainActor
    func testAmbientRefreshPolicyUsesDocumentedCadenceAndSourceTimestamps() {
        XCTAssertEqual(CanvasAmbientRefreshPolicy.upstreamUpdateFloor, 60)
        XCTAssertEqual(CanvasAmbientRefreshPolicy.pollingInterval, 60)

        let old = makeSnapshot(temperature: "70°F", timestamp: Date(timeIntervalSince1970: 100))
        let newer = makeSnapshot(temperature: "71°F", timestamp: Date(timeIntervalSince1970: 101))
        let same = makeSnapshot(temperature: "72°F", timestamp: Date(timeIntervalSince1970: 100))

        XCTAssertFalse(CanvasAmbientRefreshPolicy.shouldPublish(existing: old, incoming: same, source: .ambientStation))
        XCTAssertFalse(CanvasAmbientRefreshPolicy.shouldPublish(existing: old, incoming: old, source: .ambientStation))
        XCTAssertTrue(CanvasAmbientRefreshPolicy.shouldPublish(existing: old, incoming: newer, source: .ambientStation))
        XCTAssertTrue(CanvasAmbientRefreshPolicy.shouldPublish(existing: old, incoming: same, source: .weatherKit))
    }

    @MainActor
    func testAmbientForegroundStartsImmediateRefreshAndPollsAtCadenceWithoutOverlap() async {
        let provider = TestWeatherProvider(results: [makeResult(temperature: "72°F")])
        let service = makeAmbientService(provider: provider, interval: 0.02)

        service.update(showWeather: true)
        let receivedInitialReading = await waitFor { provider.callCount >= 1 }
        let receivedPolledReading = await waitFor(timeout: 0.5) { provider.callCount >= 2 }
        XCTAssertTrue(receivedInitialReading)
        XCTAssertTrue(receivedPolledReading)
        XCTAssertEqual(provider.maximumConcurrentCalls, 1)

        service.clear()
    }

    @MainActor
    func testAmbientPollingStopsInactiveAndForegroundReturnRefreshesImmediately() async {
        let provider = TestWeatherProvider(results: [makeResult(temperature: "72°F")], delayNanoseconds: 200_000_000)
        let service = makeAmbientService(provider: provider, interval: 1)

        service.update(showWeather: true)
        let receivedInitialReading = await waitFor { provider.callCount >= 1 }
        XCTAssertTrue(receivedInitialReading)
        service.setActive(false)
        let inactiveCallCount = provider.callCount
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(provider.callCount, inactiveCallCount)

        service.setActive(true)
        let refreshedAfterForeground = await waitFor(timeout: 1) { provider.callCount >= inactiveCallCount + 1 }
        XCTAssertTrue(refreshedAfterForeground)
        XCTAssertEqual(provider.maximumConcurrentCalls, 1)

        service.clear()
    }

    @MainActor
    func testAmbientRefreshDeduplicatesRepeatedTriggersAndNeverOverlapsRequests() async {
        let provider = TestWeatherProvider(results: [makeResult(temperature: "72°F")], delayNanoseconds: 50_000_000)
        let service = makeAmbientService(provider: provider, interval: 1)

        service.update(showWeather: true)
        let receivedInitialReading = await waitFor { provider.callCount >= 1 }
        XCTAssertTrue(receivedInitialReading)
        for _ in 0..<5 {
            service.refreshNow()
        }

        let receivedDeduplicatedFollowUp = await waitFor(timeout: 1) { provider.callCount >= 2 }
        XCTAssertTrue(receivedDeduplicatedFollowUp)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(provider.callCount, 2)
        XCTAssertEqual(provider.maximumConcurrentCalls, 1)

        service.clear()
    }

    @MainActor
    func testAmbientNewReadingPublishesToUIAndStaleReadingPreservesCache() async throws {
        let defaults = try makeTestDefaults()
        let newestTimestamp = Date(timeIntervalSince1970: 2_000)
        let staleTimestamp = Date(timeIntervalSince1970: 1_000)
        let provider = TestWeatherProvider(results: [
            makeResult(temperature: "72°F", timestamp: newestTimestamp),
            makeResult(temperature: "70°F", timestamp: staleTimestamp)
        ])
        let service = makeAmbientService(provider: provider, interval: 1, defaults: defaults)
        var publishedTemperatures: [String] = []
        let subscription = service.$snapshot.sink { snapshot in
            if let snapshot {
                publishedTemperatures.append(snapshot.temperature)
            }
        }

        service.update(showWeather: true)
        let receivedInitialReading = await waitFor { provider.callCount >= 1 && service.snapshot != nil }
        XCTAssertTrue(receivedInitialReading)
        XCTAssertEqual(service.snapshot?.temperature, "72.0°F")
        XCTAssertEqual(publishedTemperatures.last, "72.0°F")

        service.refreshNow()
        let receivedStaleReading = await waitFor(timeout: 1) { provider.callCount >= 2 }
        XCTAssertTrue(receivedStaleReading)
        XCTAssertEqual(service.snapshot?.temperature, "72.0°F")
        XCTAssertTrue(service.isUsingCachedSnapshot)

        let cachedService = makeAmbientService(
            provider: TestWeatherProvider(results: [makeResult(temperature: "65°F")]),
            interval: 1,
            defaults: defaults
        )
        XCTAssertEqual(cachedService.snapshot?.temperature, "72.0°F")

        subscription.cancel()
        service.clear()
        cachedService.clear()
    }

    func testWeatherAuthorizationFailureExplainsTheSeparateAppServiceRequirement() {
        XCTAssertEqual(WeatherOverlayStatus.authorizationUnavailable.title, "WeatherKit authorization unavailable")
        XCTAssertTrue(WeatherOverlayStatus.authorizationUnavailable.message.contains("authorization service"))
        XCTAssertTrue(WeatherOverlayStatus.authorizationUnavailable.message.contains("WeatherKit capability"))
        XCTAssertTrue(WeatherOverlayStatus.authorizationUnavailable.message.contains("WeatherKit App Service"))
        XCTAssertTrue(WeatherOverlayStatus.authorizationUnavailable.message.contains("newly signed build"))
    }

    func testWeatherSnapshotDropsLegacyLegalSourceTextFromItsPersistedModel() throws {
        let legacyJSON = Data(#"{"symbolName":"cloud.sun.fill","condition":"Partly Cloudy","temperature":"72°F","attributionText":"WeatherKit Sources\\nWeather Station Data","updatedAt":0}"#.utf8)
        let snapshot = try JSONDecoder().decode(CanvasWeatherSnapshot.self, from: legacyJSON)
        let migratedJSON = try JSONEncoder().encode(snapshot)
        let migratedText = try XCTUnwrap(String(data: migratedJSON, encoding: .utf8))

        XCTAssertEqual(snapshot.symbolName, "cloud.sun.fill")
        XCTAssertEqual(snapshot.displayText, "72.0°F · Partly Cloudy · Last known")
        XCTAssertFalse(migratedText.contains("WeatherKit Sources"))
        XCTAssertFalse(migratedText.contains("Weather Station Data"))
    }

    func testWeatherDefaultsStayMinimalAndLegacySettingsDecodeCompatibly() throws {
        let defaults = OverlaySettings()
        XCTAssertTrue(defaults.effectiveWeatherShowConditions)
        XCTAssertTrue(defaults.effectiveWeatherShowAirQuality)
        XCTAssertFalse(defaults.effectiveWeatherShowFeelsLike)
        XCTAssertFalse(defaults.effectiveWeatherShowHumidity)
        XCTAssertFalse(defaults.effectiveWeatherShowWind)
        XCTAssertFalse(defaults.effectiveWeatherShowUVIndex)
        XCTAssertFalse(defaults.effectiveWeatherShowPrecipitationChance)
        XCTAssertFalse(defaults.effectiveWeatherShowRainToday)
        XCTAssertFalse(defaults.effectiveWeatherShowDailyHighLow)
        XCTAssertFalse(defaults.effectiveWeatherShowSunriseSunset)
        XCTAssertFalse(defaults.effectiveWeatherShowNextHour)
        XCTAssertEqual(defaults.effectiveWeatherSize, defaults.fontSize)

        var independent = defaults
        independent.weatherSize = 36
        independent.fontSize = 18
        XCTAssertEqual(independent.effectiveWeatherSize, 36)
        XCTAssertEqual(independent.fontSize, 18)

        var legacy = OverlaySettings()
        legacy.weatherShowConditions = nil
        legacy.weatherShowAirQuality = nil
        legacy.weatherShowNextHour = nil
        XCTAssertTrue(legacy.effectiveWeatherShowConditions)
        XCTAssertTrue(legacy.effectiveWeatherShowAirQuality)
        XCTAssertFalse(legacy.effectiveWeatherShowNextHour)
    }

    func testClockAndWeatherPairOnlyWhenBothAreVisible() {
        XCTAssertTrue(WeatherClockLayoutPolicy.pairsClockAndWeather(showTime: true, showWeather: true))
        XCTAssertFalse(WeatherClockLayoutPolicy.pairsClockAndWeather(showTime: false, showWeather: true))
        XCTAssertFalse(WeatherClockLayoutPolicy.pairsClockAndWeather(showTime: true, showWeather: false))
        XCTAssertFalse(WeatherClockLayoutPolicy.shouldRenderStandalone(.weather, paired: true))
        XCTAssertTrue(WeatherClockLayoutPolicy.shouldRenderStandalone(.clock, paired: true))
        XCTAssertTrue(WeatherClockLayoutPolicy.shouldRenderStandalone(.weather, paired: false))
    }

    func testClockWeatherRowFollowsCanvasOrientation() {
        XCTAssertFalse(
            WeatherClockLayoutPolicy.stacksClockAndWeather(
                for: CGSize(width: 1366, height: 1024)
            )
        )
        XCTAssertTrue(
            WeatherClockLayoutPolicy.stacksClockAndWeather(
                for: CGSize(width: 1024, height: 1366)
            )
        )
        // A narrow landscape canvas remains horizontal; stacking is reserved
        // for portrait orientation rather than an arbitrary width threshold.
        XCTAssertFalse(
            WeatherClockLayoutPolicy.stacksClockAndWeather(
                for: CGSize(width: 1024, height: 834)
            )
        )
        XCTAssertFalse(WeatherOverlayFooterPolicy.rendersCompactVisualFooter)
    }

    func testPlaybackTimingPolicyRejectsZeroPhotoDurationAndPreservesUnlimitedVideo() {
        XCTAssertEqual(PlaybackTimingPolicy.normalizedPhotoDuration(0), 10)
        XCTAssertEqual(PlaybackTimingPolicy.normalizedPhotoDuration(.nan), 10)
        XCTAssertEqual(PlaybackTimingPolicy.normalizedPhotoDuration(0.2), 1)
        XCTAssertEqual(PlaybackTimingPolicy.normalizedVideoDuration(0), 0)

        var settings = CanvasSettings()
        settings.photoDuration = 0
        settings.livePhotoDuration = .infinity
        settings.videoDuration = 0
        settings.transitionDuration = -.infinity
        XCTAssertTrue(settings.normalizePlaybackTiming())
        XCTAssertEqual(settings.photoDuration, 10)
        XCTAssertEqual(settings.livePhotoDuration, 10)
        XCTAssertEqual(settings.videoDuration, 0)
        XCTAssertEqual(settings.transitionDuration, 1)
    }

    func testUSAirQualityCategoriesUsePublishedAQIBands() {
        XCTAssertEqual(CanvasAirQualityCategory.category(for: 0), .good)
        XCTAssertEqual(CanvasAirQualityCategory.category(for: 50), .good)
        XCTAssertEqual(CanvasAirQualityCategory.category(for: 51), .moderate)
        XCTAssertEqual(CanvasAirQualityCategory.category(for: 101), .unhealthySensitive)
        XCTAssertEqual(CanvasAirQualityCategory.category(for: 151), .unhealthy)
        XCTAssertEqual(CanvasAirQualityCategory.category(for: 201), .veryUnhealthy)
        XCTAssertEqual(CanvasAirQualityCategory.category(for: 301), .hazardous)
    }

    func testOpenMeteoAQIDecodingAndCoordinateMinimization() throws {
        let data = Data(#"{"current":{"us_aqi":36.4}}"#.utf8)
        let decoded = try JSONDecoder().decode(OpenMeteoAirQualityResponse.self, from: data)
        XCTAssertEqual(decoded.current?.usAQI, 36.4)
        XCTAssertEqual(OpenMeteoAirQualityProvider.coordinateString(40.44672), "40.45")
        XCTAssertEqual(OpenMeteoAirQualityProvider.coordinateString(-79.98214), "-79.98")
    }

    func testAmbientStationSettingsDefaultToWeatherKitAndNormalizeMAC() throws {
        let encoded = try JSONEncoder().encode(CanvasSettings())
        let decoded = try JSONDecoder().decode(CanvasSettings.self, from: encoded)
        XCTAssertEqual(decoded.effectiveWeatherSource, .weatherKit)
        XCTAssertNil(decoded.effectiveAmbientDeviceMAC)
        XCTAssertEqual(
            AmbientWeatherCanvasProvider.normalizeMAC("00-10-fa-aa-bb-cc"),
            "00:10:FA:AA:BB:CC"
        )
        XCTAssertNil(AmbientWeatherCanvasProvider.normalizeMAC("WS-5000"))
    }

    func testAmbientReadingDecodingAndObservationGlyphMapping() throws {
        let data = Data(#"{"reading":{"tempF":72.4,"apparentTempF":70.1,"humidityPercent":48,"windMph":8.2,"windGustMph":12.3,"windDirectionDeg":315,"pressureInHg":29.9,"uvIndex":0,"hourlyRainIn":0.2,"rainTodayIn":0.4,"highF":78,"lowF":61,"asOf":"2026-08-12T20:00:00.000Z"}}"#.utf8)
        let response = try JSONDecoder().decode(CanvasAmbientCurrentResponse.self, from: data)
        let reading = try XCTUnwrap(response.reading)
        let snapshot = AmbientWeatherCanvasProvider.snapshot(from: reading)

        XCTAssertEqual(snapshot.symbolName, "cloud.rain.fill")
        XCTAssertEqual(snapshot.condition, "Rain")
        XCTAssertEqual(snapshot.temperature, "72.4°F")
        XCTAssertEqual(snapshot.apparentTemperature, "70.1°F")
        XCTAssertEqual(snapshot.humidityPercent, 48)
        XCTAssertTrue(snapshot.wind?.contains("NW") == true)
        XCTAssertTrue(snapshot.wind?.contains("8") == true)
        XCTAssertEqual(snapshot.rainToday, "0.40 in")
        XCTAssertEqual(snapshot.highTemperature, "78.0°F")
        XCTAssertEqual(snapshot.lowTemperature, "61.0°F")
    }

    func testAmbientReadingNeverInventsClearWhenSkyConditionIsUnavailable() throws {
        let data = Data(#"{"reading":{"tempF":64,"humidityPercent":96,"uvIndex":4,"hourlyRainIn":0,"asOf":"2026-08-15T15:00:00.000Z"}}"#.utf8)
        let response = try JSONDecoder().decode(CanvasAmbientCurrentResponse.self, from: data)
        let reading = try XCTUnwrap(response.reading)
        let snapshot = AmbientWeatherCanvasProvider.snapshot(from: reading)

        XCTAssertEqual(snapshot.symbolName, "cloud.fill")
        XCTAssertEqual(snapshot.condition, "Conditions unavailable")
    }

    func testOpenMeteoConditionMappingIncludesFogAndCloudCover() {
        XCTAssertEqual(OpenMeteoConditionPolicy.condition(for: 45, isDay: true), CanvasWeatherCondition(symbolName: "cloud.fog.fill", text: "Fog"))
        XCTAssertEqual(OpenMeteoConditionPolicy.condition(for: 3, isDay: true), CanvasWeatherCondition(symbolName: "cloud.fill", text: "Overcast"))
        XCTAssertEqual(OpenMeteoConditionPolicy.condition(for: 2, isDay: true), CanvasWeatherCondition(symbolName: "cloud.sun.fill", text: "Partly cloudy"))
        XCTAssertEqual(OpenMeteoConditionPolicy.condition(for: 0, isDay: false), CanvasWeatherCondition(symbolName: "moon.stars.fill", text: "Clear"))
    }

    func testOpenMeteoCurrentConditionRequestUsesCurrentWeatherCode() throws {
        let url = try XCTUnwrap(
            OpenMeteoCurrentConditionProvider.requestURL(
                for: CLLocation(latitude: 40.44672, longitude: -79.98214)
            )
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "current" })?.value, "weather_code,is_day")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "timezone" })?.value, "auto")
    }

    func testCachedWeatherIsExplicitlyLabeledLastKnown() {
        let snapshot = CanvasWeatherSnapshot(
            symbolName: "sun.max.fill",
            condition: "Clear",
            temperature: "72°F",
            updatedAt: .now
        )

        XCTAssertEqual(snapshot.displayText(isUsingCachedSnapshot: true), "72.0°F · Clear · Last known")
    }

    func testAmbientStationChoicesUseFriendlyLabelsWithoutShowingIdentifiers() throws {
        let data = Data(#"{"devices":[{"macAddress":"00:10:FA:AA:BB:CC","name":"Backyard","location":"Pittsburgh"},{"macAddress":"00:10:FA:DD:EE:FF","name":"","location":""}]}"#.utf8)
        let response = try JSONDecoder().decode(CanvasAmbientDeviceResponse.self, from: data)
        XCTAssertEqual(response.devices[0].displayName, "Backyard · Pittsburgh")
        XCTAssertEqual(response.devices[1].displayName, "Ambient station")
        XCTAssertFalse(response.devices[0].displayName.contains(response.devices[0].macAddress))
    }

    func testWeatherSnapshotAQIEnrichmentPreservesWeatherKitDetails() {
        let source = CanvasWeatherSnapshot.preview.addingAirQualityIndex(nil)
        let enriched = source.addingAirQualityIndex(42)
        XCTAssertEqual(enriched.temperature, source.temperature)
        XCTAssertEqual(enriched.condition, source.condition)
        XCTAssertEqual(enriched.nextHourCondition, source.nextHourCondition)
        XCTAssertEqual(enriched.airQualityIndex, 42)
    }

    func testSwipeNavigationAndPlaybackIndexMoveExactlyOneItem() {
        XCTAssertEqual(SwipeNavigation.direction(for: CGSize(width: -120, height: 8)), 1)
        XCTAssertEqual(SwipeNavigation.direction(for: CGSize(width: 120, height: -8)), -1)
        XCTAssertNil(SwipeNavigation.direction(for: CGSize(width: 25, height: 2)))
        XCTAssertNil(SwipeNavigation.direction(for: CGSize(width: -120, height: 140)))
        XCTAssertEqual(PlaybackIndexResolver.nextIndex(current: 1, count: 5, direction: 1, repeatEnabled: false), 2)
        XCTAssertEqual(PlaybackIndexResolver.nextIndex(current: 2, count: 5, direction: -1, repeatEnabled: false), 1)
        XCTAssertNil(PlaybackIndexResolver.nextIndex(current: 4, count: 5, direction: 1, repeatEnabled: false))
        XCTAssertEqual(PlaybackIndexResolver.nextIndex(current: 4, count: 5, direction: 1, repeatEnabled: true), 0)
    }

    func testDisplayedPairSwipeAdvancesByWholeGroup() {
        let portraits = [
            CGSize(width: 900, height: 1400),
            CGSize(width: 1000, height: 1500),
            CGSize(width: 800, height: 1200),
            CGSize(width: 1100, height: 1600),
            CGSize(width: 700, height: 1000)
        ]
        let landscapeCanvas = CGSize(width: 1366, height: 1024)
        // Portrait pairs are the two-tile group on a landscape iPad.
        XCTAssertEqual(
            PlaybackGroupResolver.selection(imageSizes: portraits, currentIndex: 0, layout: .automatic, canvasSize: landscapeCanvas).indices,
            [0, 1]
        )
        XCTAssertEqual(
            PlaybackGroupResolver.nextGroupIndex(imageSizes: portraits, currentIndex: 0, direction: 1, layout: .automatic, canvasSize: landscapeCanvas, repeatEnabled: false),
            2
        )

        let portraitCanvas = CGSize(width: 1024, height: 1366)
        let landscapes = [
            CGSize(width: 1600, height: 900),
            CGSize(width: 1400, height: 900),
            CGSize(width: 1500, height: 850),
            CGSize(width: 1300, height: 800),
            CGSize(width: 1200, height: 700)
        ]
        XCTAssertEqual(
            PlaybackGroupResolver.selection(imageSizes: landscapes, currentIndex: 0, layout: .automatic, canvasSize: portraitCanvas).indices,
            [0, 1]
        )
        XCTAssertEqual(
            PlaybackGroupResolver.nextGroupIndex(imageSizes: landscapes, currentIndex: 0, direction: 1, layout: .automatic, canvasSize: portraitCanvas, repeatEnabled: false),
            2
        )
        XCTAssertEqual(
            PlaybackGroupResolver.nextGroupIndex(imageSizes: landscapes, currentIndex: 2, direction: -1, layout: .automatic, canvasSize: portraitCanvas, repeatEnabled: false),
            0
        )
        XCTAssertEqual(SwipeTransitionState.from(direction: 1), .forward)
        XCTAssertEqual(SwipeTransitionState.from(direction: -1), .backward)
        XCTAssertEqual(SwipeTransitionState.from(direction: 0), .automatic)
    }

    func testAutomaticDisplayedPairTransitionUsesNextGroupStart() {
        let portraits = [
            CGSize(width: 900, height: 1400),
            CGSize(width: 1000, height: 1500),
            CGSize(width: 800, height: 1200),
            CGSize(width: 1100, height: 1600)
        ]
        let canvasSize = CGSize(width: 1366, height: 1024)

        XCTAssertEqual(
            PlaybackAdvancePolicy.destinationIndex(
                imageSizes: portraits,
                currentIndex: 0,
                direction: 1,
                layout: .automatic,
                canvasSize: canvasSize,
                repeatEnabled: false,
                usesDisplayedGroup: true
            ),
            2
        )
        XCTAssertEqual(
            PlaybackAdvancePolicy.destinationIndex(
                imageSizes: portraits,
                currentIndex: 0,
                direction: 1,
                layout: .automatic,
                canvasSize: canvasSize,
                repeatEnabled: false,
                usesDisplayedGroup: false
            ),
            1
        )
    }

    func testBackwardPlaybackHistoryReplaysThePriorRouteAcrossAReshuffle() {
        let assets = (0..<4).map { index in
            CanvasMediaItem(
                id: "asset-\(index)",
                source: .applePhotos,
                kind: .photo,
                creationDate: nil,
                filename: "photo-\(index).jpg",
                isFavorite: false,
                pixelWidth: 900,
                pixelHeight: 1400,
                albumTitle: "Family",
                appleAsset: nil,
                localURL: nil,
                contentHash: nil
            )
        }
        let firstQueue = [assets[0], assets[1], assets[2], assets[3]]
        let reshuffledQueue = [assets[2], assets[3], assets[0], assets[1]]
        var history = PlaybackNavigationHistory()
        history.reset(to: PlaybackHistoryPosition(queue: firstQueue, currentIndex: 0))
        history.append(PlaybackHistoryPosition(queue: firstQueue, currentIndex: 2))
        history.append(PlaybackHistoryPosition(queue: reshuffledQueue, currentIndex: 0))

        let previousAfterReshuffle = history.move(direction: -1)
        XCTAssertEqual(previousAfterReshuffle?.queue.map(\.id), ["asset-0", "asset-1", "asset-2", "asset-3"])
        XCTAssertEqual(previousAfterReshuffle?.currentIndex, 2)

        let firstFrame = history.move(direction: -1)
        XCTAssertEqual(firstFrame?.queue.map(\.id), ["asset-0", "asset-1", "asset-2", "asset-3"])
        XCTAssertEqual(firstFrame?.currentIndex, 0)
    }

    func testDisplayedGroupSwipeUsesAdjacentGroupsForHeterogeneousOrientations() {
        let imageSizes = [
            CGSize(width: 900, height: 1400),
            CGSize(width: 1000, height: 1500),
            CGSize(width: 1600, height: 900),
            CGSize(width: 800, height: 1200),
            CGSize(width: 700, height: 1000),
            CGSize(width: 1400, height: 800)
        ]
        let canvasSize = CGSize(width: 1366, height: 1024)

        XCTAssertEqual(
            PlaybackGroupResolver.groupStarts(imageSizes: imageSizes, layout: .automatic, canvasSize: canvasSize),
            [0, 2, 3, 5]
        )

        // The swipe destination is the next/previous displayed group start,
        // even when the current index is the second tile of a pair.
        XCTAssertEqual(
            PlaybackGroupResolver.nextGroupIndex(imageSizes: imageSizes, currentIndex: 0, direction: 1, layout: .automatic, canvasSize: canvasSize, repeatEnabled: false),
            2
        )
        XCTAssertEqual(
            PlaybackGroupResolver.nextGroupIndex(imageSizes: imageSizes, currentIndex: 1, direction: 1, layout: .automatic, canvasSize: canvasSize, repeatEnabled: false),
            2
        )
        XCTAssertEqual(
            PlaybackGroupResolver.nextGroupIndex(imageSizes: imageSizes, currentIndex: 3, direction: 1, layout: .automatic, canvasSize: canvasSize, repeatEnabled: false),
            5
        )
        XCTAssertEqual(
            PlaybackGroupResolver.nextGroupIndex(imageSizes: imageSizes, currentIndex: 2, direction: -1, layout: .automatic, canvasSize: canvasSize, repeatEnabled: false),
            0
        )
        XCTAssertEqual(
            PlaybackGroupResolver.nextGroupIndex(imageSizes: imageSizes, currentIndex: 4, direction: -1, layout: .automatic, canvasSize: canvasSize, repeatEnabled: false),
            2
        )
        XCTAssertEqual(
            PlaybackGroupResolver.nextGroupIndex(imageSizes: imageSizes, currentIndex: 5, direction: -1, layout: .automatic, canvasSize: canvasSize, repeatEnabled: false),
            3
        )
        XCTAssertNil(
            PlaybackGroupResolver.nextGroupIndex(imageSizes: imageSizes, currentIndex: 5, direction: 1, layout: .automatic, canvasSize: canvasSize, repeatEnabled: false)
        )
        XCTAssertEqual(
            PlaybackGroupResolver.nextGroupIndex(imageSizes: imageSizes, currentIndex: 5, direction: 1, layout: .automatic, canvasSize: canvasSize, repeatEnabled: true),
            0
        )
    }

    func testLivePhotoIsSingleGroupBoundaryAndAdjacentGroupsRemainOrdered() {
        let imageSizes = [
            CGSize(width: 1170, height: 2532), // Live Photo: one UIKit tile
            CGSize(width: 900, height: 1400),
            CGSize(width: 1000, height: 1500),
            CGSize(width: 2532, height: 1170), // another Live Photo boundary
            CGSize(width: 800, height: 1200),
            CGSize(width: 700, height: 1000)
        ]
        let singleMediaIndices: Set<Int> = [0, 3]
        let canvasSize = CGSize(width: 1366, height: 1024)

        XCTAssertEqual(
            PlaybackGroupResolver.groupStarts(
                imageSizes: imageSizes,
                layout: .automatic,
                canvasSize: canvasSize,
                singleMediaIndices: singleMediaIndices
            ),
            [0, 1, 3, 4]
        )
        XCTAssertEqual(
            PlaybackGroupResolver.nextGroupIndex(
                imageSizes: imageSizes,
                currentIndex: 1,
                direction: 1,
                layout: .automatic,
                canvasSize: canvasSize,
                repeatEnabled: false,
                singleMediaIndices: singleMediaIndices
            ),
            3
        )
        XCTAssertEqual(
            PlaybackGroupResolver.nextGroupIndex(
                imageSizes: imageSizes,
                currentIndex: 4,
                direction: -1,
                layout: .automatic,
                canvasSize: canvasSize,
                repeatEnabled: false,
                singleMediaIndices: singleMediaIndices
            ),
            3
        )
        XCTAssertFalse(
            PlaybackAdvancePolicy.shouldShuffleAfterAdvance(
                direction: 1,
                targetIndex: 3,
                currentIndex: 3,
                shuffleEachLoop: true
            )
        )
        XCTAssertTrue(
            PlaybackAdvancePolicy.shouldShuffleAfterAdvance(
                direction: 1,
                targetIndex: 0,
                currentIndex: 0,
                shuffleEachLoop: true
            )
        )
        XCTAssertTrue(PlaybackMediaSurfacePolicy.usesSingleTile(for: .livePhoto))
        XCTAssertTrue(PlaybackMediaSurfacePolicy.usesSingleTile(for: .video))
        XCTAssertFalse(PlaybackMediaSurfacePolicy.usesSingleTile(for: .photo))
        XCTAssertFalse(PlaybackMediaSurfacePolicy.allowsCompanions(for: .livePhoto))
        XCTAssertTrue(PlaybackMediaSurfacePolicy.allowsCompanions(for: .photo))
    }

    func testSingleTileCaptureDateBadgeStaysInsideBottomLeadingCorner() {
        let tile = CGSize(width: 1024, height: 1366)
        let badge = CGSize(width: 128, height: 30)
        let frame = CaptureDateOverlayGeometry.bottomLeadingFrame(tileSize: tile, badgeSize: badge, inset: 10)
        XCTAssertEqual(frame.minX, 10, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, tile.height - 10, accuracy: 0.001)
        XCTAssertTrue(CGRect(origin: .zero, size: tile).contains(frame))
    }

    func testPortraitPairCaptureDatesMoveToInnerEdgesAroundCenterline() {
        let portraits = [
            CGSize(width: 900, height: 1400),
            CGSize(width: 1000, height: 1500)
        ]

        XCTAssertEqual(
            CaptureDateOverlayGeometry.horizontalAnchor(
                tilePosition: 0,
                tileIndex: 0,
                tileCount: 2,
                resolvedStyle: .portraitPair,
                imageSizes: portraits,
                position: .bottomLeading
            ),
            .trailing
        )
        XCTAssertEqual(
            CaptureDateOverlayGeometry.horizontalAnchor(
                tilePosition: 1,
                tileIndex: 1,
                tileCount: 2,
                resolvedStyle: .portraitPair,
                imageSizes: portraits,
                position: .bottomLeading
            ),
            .leading
        )
        XCTAssertEqual(
            CaptureDateOverlayGeometry.horizontalAnchor(
                tilePosition: 1,
                tileIndex: 1,
                tileCount: 2,
                resolvedStyle: .portraitPair,
                imageSizes: portraits,
                position: .bottomTrailing
            ),
            .leading
        )
    }

    func testLandscapeCaptureDatesMoveToBottomTrailingForBottomLeadingClock() {
        let landscapes = [CGSize(width: 1600, height: 900)]

        XCTAssertEqual(
            CaptureDateOverlayGeometry.horizontalAnchor(
                tilePosition: 0,
                tileIndex: 0,
                tileCount: 1,
                resolvedStyle: .single,
                imageSizes: landscapes,
                position: .bottomLeading
            ),
            .trailing
        )
        XCTAssertEqual(
            CaptureDateOverlayGeometry.horizontalAnchor(
                tilePosition: 0,
                tileIndex: 0,
                tileCount: 1,
                resolvedStyle: .single,
                imageSizes: landscapes,
                position: .bottomTrailing
            ),
            .leading
        )
    }

    func testClockIsBottomRowOnlyForBottomOverlayPositions() {
        XCTAssertTrue(ClockOverlayStackPolicy.placesClockAtBottom(for: .bottomLeading))
        XCTAssertTrue(ClockOverlayStackPolicy.placesClockAtBottom(for: .bottomTrailing))
        XCTAssertFalse(ClockOverlayStackPolicy.placesClockAtBottom(for: .topLeading))
        XCTAssertFalse(ClockOverlayStackPolicy.placesClockAtBottom(for: .center))
    }

    func testBottomOverlayOrderKeepsBatteryDateAndClockTogether() {
        let order = OverlayStackOrder.items(
            position: .bottomTrailing,
            showTime: true,
            showDate: true,
            showAlbum: true,
            showWeekday: true,
            showLocation: true,
            showCaption: true,
            showItemCount: true,
            showBattery: true,
            showWeather: true
        )

        XCTAssertEqual(Array(order.suffix(3)), [.battery, .date, .clock])
        XCTAssertEqual(
            OverlayStackOrder.items(
                position: .topLeading,
                showTime: true,
                showDate: true,
                showAlbum: false,
                showWeekday: false,
                showLocation: false,
                showCaption: false,
                showItemCount: false,
                showBattery: true,
                showWeather: false
            ),
            [.clock, .date, .battery]
        )
    }

    func testBatteryOverlayUsesFullSymbolAtFullCharge() {
        XCTAssertEqual(BatteryOverlayPolicy.percentage(for: 1), 100)
        XCTAssertEqual(BatteryOverlayPolicy.label(for: 1), "100%")
        XCTAssertEqual(BatteryOverlayPolicy.symbol(for: 1, isCharging: false), "battery.100percent")
        XCTAssertEqual(BatteryOverlayPolicy.symbol(for: 0.999, isCharging: true), "battery.100percent")
    }

    func testBatteryOverlayRoundsLevelsAndHandlesUnavailableSimulatorReading() {
        XCTAssertEqual(BatteryOverlayPolicy.label(for: 0.996), "100%")
        XCTAssertEqual(BatteryOverlayPolicy.symbol(for: 0.75, isCharging: false), "battery.75percent")
        XCTAssertEqual(BatteryOverlayPolicy.symbol(for: 0.5, isCharging: false), "battery.50percent")
        XCTAssertEqual(BatteryOverlayPolicy.label(for: -1), "—")
    }

    func testCaptureDateTileFramesStayInsideFinalSingleAndPairedCanvas() {
        let single = CaptureDateOverlayGeometry.tileFrames(
            imageSizes: [CGSize(width: 900, height: 1400)],
            style: .automatic,
            canvasSize: CGSize(width: 1024, height: 1366),
            spacing: 8
        )
        XCTAssertEqual(single.map(\.index), [0])
        XCTAssertTrue(single.allSatisfy { CGRect(origin: .zero, size: CGSize(width: 1024, height: 1366)).contains($0.frame) })

        let pair = CaptureDateOverlayGeometry.tileFrames(
            imageSizes: [CGSize(width: 900, height: 1400), CGSize(width: 1000, height: 1500)],
            style: .automatic,
            canvasSize: CGSize(width: 1366, height: 1024),
            spacing: 8
        )
        XCTAssertEqual(pair.map(\.index), [0, 1])
        XCTAssertTrue(pair.allSatisfy { CGRect(origin: .zero, size: CGSize(width: 1366, height: 1024)).contains($0.frame) })
        XCTAssertEqual(pair[0].frame, CGRect(x: 0, y: 0, width: 679, height: 1024))
        XCTAssertEqual(pair[1].frame, CGRect(x: 687, y: 0, width: 679, height: 1024))
        XCTAssertEqual(pair[0].frame.width, pair[1].frame.width)
        XCTAssertEqual(pair[1].frame.minX - pair[0].frame.maxX, 8, accuracy: 0.001)
        XCTAssertEqual(pair[1].frame.maxX, 1366, accuracy: 0.001)
    }

    func testPortraitPairMediaPlansUseExplicitTileAlignmentInsideTheirViewports() {
        let canvas = CGSize(width: 2388, height: 1668)
        let sourceSizes = [
            CGSize(width: 3024, height: 4032),
            CGSize(width: 2880, height: 3840)
        ]
        let tiles = CaptureDateOverlayGeometry.tileFrames(
            imageSizes: sourceSizes,
            style: .automatic,
            canvasSize: canvas,
            spacing: 8
        )

        XCTAssertEqual(tiles.count, 2)
        for (sourcePair, tile) in zip(sourceSizes.enumerated(), tiles) {
            let sourceSize = sourcePair.element
            let alignment = MediaTileAlignmentPolicy.horizontalAlignment(
                tilePosition: sourcePair.offset,
                layout: .pairHorizontal
            )
            let plan = MediaFramingGeometry.plan(
                imageSize: sourceSize,
                viewportSize: tile.frame.size,
                preferredMode: .fillZoom,
                requestedLayout: .automatic,
                selectedLayout: .pairHorizontal,
                horizontalAlignment: alignment
            )

            // The first tile owns the leading edge. The second remains
            // centered, preserving its existing composition while both tiles
            // still cover their full explicit viewports.
            if sourcePair.offset == 0 {
                XCTAssertEqual(plan.renderedFrame.minX, 0, accuracy: 0.001)
            } else {
                XCTAssertEqual(plan.renderedFrame.midX, tile.frame.width / 2, accuracy: 0.001)
            }
            XCTAssertEqual(plan.renderedFrame.midY, tile.frame.height / 2, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(plan.renderedFrame.width, tile.frame.width - 0.001)
            XCTAssertGreaterThanOrEqual(plan.renderedFrame.height, tile.frame.height - 0.001)
        }
    }

    func testPortraitPairAlignmentPolicyIsGlobalAcrossPortraitAspectRatios() {
        let portraitSources = [
            CGSize(width: 3024, height: 4032),
            CGSize(width: 2000, height: 3000),
            CGSize(width: 2268, height: 4032),
            CGSize(width: 1440, height: 2560),
            CGSize(width: 1170, height: 2532)
        ]
        let viewport = CGSize(width: 593, height: 834)

        for source in portraitSources {
            let firstTile = MediaFramingGeometry.plan(
                imageSize: source,
                viewportSize: viewport,
                preferredMode: .fillZoom,
                requestedLayout: .automatic,
                selectedLayout: .pairHorizontal,
                horizontalAlignment: MediaTileAlignmentPolicy.horizontalAlignment(
                    tilePosition: 0,
                    layout: .pairHorizontal
                )
            )
            XCTAssertEqual(firstTile.renderedFrame.minX, 0, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(firstTile.renderedFrame.maxX, viewport.width - 0.001)
            XCTAssertGreaterThanOrEqual(firstTile.renderedFrame.maxY, viewport.height - 0.001)
        }

        XCTAssertEqual(
            MediaTileAlignmentPolicy.horizontalAlignment(tilePosition: 1, layout: .pairHorizontal),
            .center
        )
        XCTAssertEqual(
            MediaTileAlignmentPolicy.horizontalAlignment(tilePosition: 0, layout: .pairVertical),
            .center
        )
    }

    func testHorizontalPortraitPairForcesFullBleedWhenSavedPreferenceIsFit() {
        // This is the failure shape from the iPad report: a narrow 9:16
        // portrait beside a wider 3:4 portrait. Pair tiles must fill both
        // halves even when an older device still has Fit with border saved.
        let viewport = CGSize(width: 1190, height: 1668)
        let plan = MediaFramingGeometry.plan(
            imageSize: CGSize(width: 1440, height: 2560),
            viewportSize: viewport,
            preferredMode: .fitWithBorder,
            requestedLayout: .automatic,
            selectedLayout: .pairHorizontal,
            horizontalAlignment: .leading
        )

        XCTAssertEqual(plan.mode, .fillZoom)
        XCTAssertEqual(plan.renderedFrame.minX, 0, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(plan.renderedFrame.maxX, viewport.width - 0.001)
        XCTAssertGreaterThanOrEqual(plan.renderedFrame.maxY, viewport.height - 0.001)
    }

    func testCaptureDateBadgeStyleIsConsistentAndPersistable() {
        XCTAssertEqual(CaptureDateBadgeStyle.darkBadgeLightText.title, "Dark badge / light text")
        XCTAssertEqual(CaptureDateBadgeStyle.lightBadgeDarkText.title, "Light badge / dark text")
        let settings = OverlaySettings()
        XCTAssertEqual(settings.captureDateStyle ?? .darkBadgeLightText, .darkBadgeLightText)
    }

    func testFramingModeOptionsPreserveImageOrExplicitlyAllowCrop() {
        XCTAssertTrue(MediaFramingMode.fitWithBorder.preservesEntireImage)
        XCTAssertFalse(MediaFramingMode.fillZoom.preservesEntireImage)
        XCTAssertEqual(CanvasSettings().effectiveFramingMode, .fitWithBorder)
    }

    func testEveryPhotoKitSourceRequestPreservesFullAspectBeforeSurfaceFraming() {
        XCTAssertEqual(PhotoLibraryService.displayImageContentMode, .aspectFit)
        XCTAssertEqual(PhotoKitSourceFramingPolicy.contentMode, .aspectFit)
    }

    func testSingleStageFramingDoesNotCompoundFillZoom() {
        let original = CGSize(width: 3024, height: 4032)
        let landscapeIPad = CGSize(width: 1366, height: 1024)

        let oneStage = MediaFramingGeometry.renderedSize(
            imageSize: original,
            viewportSize: landscapeIPad,
            mode: .fillZoom
        )
        XCTAssertEqual(oneStage.width, landscapeIPad.width, accuracy: 0.001)
        XCTAssertEqual(oneStage.width / oneStage.height, original.width / original.height, accuracy: 0.0001)

        // If PhotoKit first aspect-fills the source to the iPad's ratio, the
        // renderer can no longer recover the original portrait composition.
        // The shared request policy prevents that destructive first crop.
        let prematurelyCropped = landscapeIPad
        XCTAssertNotEqual(
            prematurelyCropped.width / prematurelyCropped.height,
            original.width / original.height,
            accuracy: 0.0001
        )
    }

    func testFillFramingUsesMinimumCoverScaleForEachPortraitImage() {
        let viewport = CGSize(width: 1024, height: 1366)
        let portraitImages = [
            CGSize(width: 900, height: 1400),
            CGSize(width: 700, height: 1000)
        ]

        for imageSize in portraitImages {
            let expectedScale = max(viewport.width / imageSize.width, viewport.height / imageSize.height)
            let scale = MediaFramingGeometry.scale(imageSize: imageSize, viewportSize: viewport, mode: .fillZoom)
            let rendered = MediaFramingGeometry.renderedSize(imageSize: imageSize, viewportSize: viewport, mode: .fillZoom)

            XCTAssertEqual(scale, expectedScale, accuracy: 0.0001)
            XCTAssertGreaterThanOrEqual(rendered.width, viewport.width - 0.0001)
            XCTAssertGreaterThanOrEqual(rendered.height, viewport.height - 0.0001)
            XCTAssertEqual(rendered.width / rendered.height, imageSize.width / imageSize.height, accuracy: 0.0001)
            XCTAssertTrue(
                abs(rendered.width - viewport.width) < 0.0001 || abs(rendered.height - viewport.height) < 0.0001,
                "Fill should touch one viewport edge at the minimum cover scale"
            )
        }

        let fitSize = MediaFramingGeometry.renderedSize(imageSize: portraitImages[0], viewportSize: viewport, mode: .fitWithBorder)
        XCTAssertLessThanOrEqual(fitSize.width, viewport.width + 0.0001)
        XCTAssertLessThanOrEqual(fitSize.height, viewport.height + 0.0001)
    }

    func testScreenshotSizedPortraitPairUsesOnlyMinimumCoverCropAtRest() {
        // The reported iPad captures are 2388 x 1668, with two portrait tiles
        // separated by a narrow gutter. A normal 3:4 source should lose only
        // a thin strip at the sides, never most of the photo.
        let screenshotTile = CGSize(width: 1190, height: 1668)
        let source = CGSize(width: 3024, height: 4032)
        let plan = MediaFramingGeometry.plan(
            imageSize: source,
            viewportSize: screenshotTile,
            preferredMode: .fillZoom,
            requestedLayout: .automatic,
            selectedLayout: .pairHorizontal
        )

        XCTAssertEqual(plan.mode, .fillZoom)
        XCTAssertEqual(InteractivePhotoZoomPolicy.restingScale, 1)
        XCTAssertEqual(plan.renderedFrame.height, screenshotTile.height, accuracy: 0.001)
        XCTAssertLessThan(plan.cropFraction, 0.06)
    }

    func testInteractivePhotoZoomCannotPersistBelowOrBeyondSupportedRange() {
        XCTAssertEqual(InteractivePhotoZoomPolicy.scale(for: 0.2), 1)
        XCTAssertEqual(InteractivePhotoZoomPolicy.scale(for: 1), 1)
        XCTAssertEqual(InteractivePhotoZoomPolicy.scale(for: 2.25), 2.25)
        XCTAssertEqual(InteractivePhotoZoomPolicy.scale(for: 10), 4)
    }

    func testAutomaticPortraitPairUsesOneExplicitFramingModeAcrossAspectRatios() {
        let canvas = CGSize(width: 1194, height: 834)
        let tiles = CaptureDateOverlayGeometry.tileFrames(
            imageSizes: [
                CGSize(width: 3024, height: 4032),
                CGSize(width: 1440, height: 2560)
            ],
            style: .automatic,
            canvasSize: canvas,
            spacing: 8
        )
        let sources = [
            CGSize(width: 3024, height: 4032),
            CGSize(width: 1440, height: 2560)
        ]

        XCTAssertEqual(tiles.count, 2)
        XCTAssertGreaterThan(
            MediaFramingGeometry.cropFraction(imageSize: sources[1], viewportSize: tiles[1].frame.size),
            0.18
        )

        for (source, tile) in zip(sources, tiles) {
            let plan = MediaFramingGeometry.plan(
                imageSize: source,
                viewportSize: tile.frame.size,
                preferredMode: .fillZoom,
                requestedLayout: .automatic,
                selectedLayout: .pairHorizontal
            )
            XCTAssertEqual(plan.mode, .fillZoom)
            XCTAssertEqual(plan.renderedFrame.midX, tile.frame.width / 2, accuracy: 0.0001)
            XCTAssertEqual(plan.renderedFrame.midY, tile.frame.height / 2, accuracy: 0.0001)
            XCTAssertGreaterThanOrEqual(plan.renderedFrame.width, tile.frame.width - 0.0001)
            XCTAssertGreaterThanOrEqual(plan.renderedFrame.height, tile.frame.height - 0.0001)
        }
    }

    func testPortraitPairFramingIsGlobalAcrossAspectRatiosAndOrientations() {
        let portraitSources = [
            CGSize(width: 3024, height: 4032), // 3:4 camera photo
            CGSize(width: 2000, height: 3000), // 2:3 camera photo
            CGSize(width: 2268, height: 4032), // 9:16 camera photo
            CGSize(width: 1440, height: 2560), // 9:16 alternate source
            CGSize(width: 1170, height: 2532)  // extra-tall phone capture
        ]
        let landscapeSources = [
            CGSize(width: 4032, height: 3024), // 4:3 camera photo
            CGSize(width: 3000, height: 2000), // 3:2 camera photo
            CGSize(width: 2560, height: 1440), // 16:9 alternate source
            CGSize(width: 2532, height: 1170)  // extra-wide phone capture
        ]
        let pairCanvases: [(canvas: CGSize, style: LayoutStyle, selected: LayoutStyle, sources: [CGSize])] = [
            (CGSize(width: 1194, height: 834), .automatic, .pairHorizontal, portraitSources),
            // A portrait iPad uses landscape sources for its compatible
            // vertical pair; portrait sources remain solo there.
            (CGSize(width: 834, height: 1194), .pairVertical, .pairVertical, landscapeSources)
        ]

        for pair in pairCanvases {
            let tiles = CaptureDateOverlayGeometry.tileFrames(
                imageSizes: [pair.sources[0], pair.sources[1]],
                style: pair.style,
                canvasSize: pair.canvas,
                spacing: 8
            )
            XCTAssertEqual(tiles.count, 2)

            for source in pair.sources {
                for tile in tiles {
                    let fillPlan = MediaFramingGeometry.plan(
                        imageSize: source,
                        viewportSize: tile.frame.size,
                        preferredMode: .fillZoom,
                        requestedLayout: pair.style,
                        selectedLayout: pair.selected
                    )

                    XCTAssertEqual(fillPlan.mode, .fillZoom)
                    XCTAssertEqual(fillPlan.renderedFrame.midX, tile.frame.width / 2, accuracy: 0.0001)
                    XCTAssertEqual(fillPlan.renderedFrame.midY, tile.frame.height / 2, accuracy: 0.0001)
                    XCTAssertLessThanOrEqual(fillPlan.renderedFrame.minX, 0.0001)
                    XCTAssertGreaterThanOrEqual(fillPlan.renderedFrame.maxX, tile.frame.width - 0.0001)
                    XCTAssertLessThanOrEqual(fillPlan.renderedFrame.minY, 0.0001)
                    XCTAssertGreaterThanOrEqual(fillPlan.renderedFrame.maxY, tile.frame.height - 0.0001)

                    let fitPlan = MediaFramingGeometry.plan(
                        imageSize: source,
                        viewportSize: tile.frame.size,
                        preferredMode: .fitWithBorder,
                        requestedLayout: pair.style,
                        selectedLayout: pair.selected
                    )

                    if pair.selected == .pairHorizontal {
                        // Horizontal portrait pairs are intentionally full
                        // bleed even when the saved preference is Fit.
                        XCTAssertEqual(fitPlan.mode, .fillZoom)
                        XCTAssertLessThanOrEqual(fitPlan.renderedFrame.minX, 0.0001)
                        XCTAssertGreaterThanOrEqual(fitPlan.renderedFrame.maxX, tile.frame.width - 0.0001)
                        XCTAssertLessThanOrEqual(fitPlan.renderedFrame.minY, 0.0001)
                        XCTAssertGreaterThanOrEqual(fitPlan.renderedFrame.maxY, tile.frame.height - 0.0001)
                    } else {
                        XCTAssertEqual(fitPlan.mode, .fitWithBorder)
                        XCTAssertGreaterThanOrEqual(fitPlan.renderedFrame.minX, -0.0001)
                        XCTAssertLessThanOrEqual(fitPlan.renderedFrame.maxX, tile.frame.width + 0.0001)
                        XCTAssertGreaterThanOrEqual(fitPlan.renderedFrame.minY, -0.0001)
                        XCTAssertLessThanOrEqual(fitPlan.renderedFrame.maxY, tile.frame.height + 0.0001)
                    }
                }
            }
        }
    }

    func testTallPortraitFillPlanHasNoLeadingInsetWhenPlacedFromTopLeadingOrigin() {
        // This is the exact geometry reported by the physical iPad probe for
        // the recurring 2268x4032 source. A fill plan must touch both tile
        // sides when its origin is applied explicitly by LayoutCanvas.
        let viewport = CGSize(width: 593, height: 834)
        let plan = MediaFramingGeometry.plan(
            imageSize: CGSize(width: 2268, height: 4032),
            viewportSize: viewport,
            preferredMode: .fillZoom,
            requestedLayout: .automatic,
            selectedLayout: .pairHorizontal,
            horizontalAlignment: .leading
        )

        XCTAssertEqual(plan.mode, .fillZoom)
        XCTAssertEqual(plan.renderedFrame.minX, 0, accuracy: 0.001)
        XCTAssertEqual(plan.renderedFrame.maxX, viewport.width, accuracy: 0.001)
        XCTAssertLessThan(plan.renderedFrame.minY, 0)
    }

    func testFitBlurredFallbackRespectsForegroundFramingPreference() {
        let fillPlan = MediaFramingGeometry.plan(
            imageSize: CGSize(width: 4032, height: 3024),
            viewportSize: CGSize(width: 1366, height: 1024),
            preferredMode: .fillZoom,
            requestedLayout: .automatic,
            selectedLayout: .fitBlurred
        )
        XCTAssertEqual(fillPlan.mode, .fillZoom)
        XCTAssertGreaterThanOrEqual(fillPlan.renderedFrame.width, 1366)
        XCTAssertGreaterThanOrEqual(fillPlan.renderedFrame.height, 1024)

        let fitPlan = MediaFramingGeometry.plan(
            imageSize: CGSize(width: 4032, height: 3024),
            viewportSize: CGSize(width: 1366, height: 1024),
            preferredMode: .fitWithBorder,
            requestedLayout: .automatic,
            selectedLayout: .fitBlurred
        )
        XCTAssertEqual(fitPlan.mode, .fitWithBorder)
        XCTAssertLessThanOrEqual(fitPlan.renderedFrame.width, 1366)
        XCTAssertLessThanOrEqual(fitPlan.renderedFrame.height, 1024)
    }

    func testFramingUsesUIImageDisplayOrientation() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 200))
        let upright = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        }
        guard let cgImage = upright.cgImage else {
            return XCTFail("Expected a CGImage-backed fixture")
        }
        let rotated = UIImage(cgImage: cgImage, scale: upright.scale, orientation: .right)

        XCTAssertEqual(upright.canvasDisplaySize, CGSize(width: 400, height: 200))
        XCTAssertEqual(rotated.canvasDisplaySize, CGSize(width: 200, height: 400))
    }

    func testHomeAlbumAreaIncludesSafeEdgeExtension() {
        XCTAssertEqual(HomeContentGeometry.bottomEdgeExtension(reportedSafeAreaBottom: 0), 36, accuracy: 0.001)
        XCTAssertEqual(HomeContentGeometry.bottomEdgeExtension(reportedSafeAreaBottom: 44), 44, accuracy: 0.001)
    }

    func testControlsAutoHideRequiresPlaybackAndExpiresAfterInactivity() {
        let started = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(ControlsAutoHidePolicy.shouldSchedule(alwaysVisible: false, playbackAllowed: true, delay: 5))
        XCTAssertFalse(ControlsAutoHidePolicy.shouldSchedule(alwaysVisible: true, playbackAllowed: true, delay: 5))
        XCTAssertFalse(ControlsAutoHidePolicy.shouldSchedule(alwaysVisible: false, playbackAllowed: false, delay: 5))
        XCTAssertFalse(ControlsAutoHidePolicy.shouldSchedule(alwaysVisible: false, playbackAllowed: true, delay: 0))
        XCTAssertFalse(ControlsAutoHidePolicy.isExpired(now: Date(timeIntervalSince1970: 104.9), startedAt: started, delay: 5))
        XCTAssertTrue(ControlsAutoHidePolicy.isExpired(now: Date(timeIntervalSince1970: 105), startedAt: started, delay: 5))
    }

    func testCaptureDateOverlayPolicySupportsSinglePairedAndDisabledStates() {
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let second = Date(timeIntervalSince1970: 1_700_086_400)
        XCTAssertEqual(CaptureDateOverlayPolicy.visibleDates([first], enabled: true), [first])
        XCTAssertEqual(CaptureDateOverlayPolicy.visibleDates([first], enabled: false), [nil])
        XCTAssertEqual(CaptureDateOverlayPolicy.visibleDates([first, second], enabled: true), [first, second])
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(CaptureDateOverlayPolicy.visibleDates([first, nil], enabled: true), [first, nil])
    }

    func testCaptureDateContrastAdaptsToLightAndDarkMedia() {
        XCTAssertEqual(CaptureDateContrastResolver.contrast(forLuminance: 0.12), .lightContent)
        XCTAssertEqual(CaptureDateContrastResolver.contrast(forLuminance: 0.92), .darkContent)
        XCTAssertEqual(CaptureDateContrastResolver.contrast(forLuminance: 0.58), .darkContent)
    }

    func testOverlayOpacitySeparatesMaterialAndTextChannels() {
        XCTAssertEqual(
            OverlayOpacityPolicy.values(backgroundOpacity: 0.31, clockOpacity: 0.82),
            OverlayOpacityValues(background: 0.31, text: 0.82)
        )
        XCTAssertEqual(
            OverlayOpacityPolicy.values(backgroundOpacity: 1.4, clockOpacity: -0.2),
            OverlayOpacityValues(background: 1, text: 0)
        )
    }

    func testOverlayDateFormatsCoverCommonStylesAndNumbersOnly() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2024, month: 1, day: 2, hour: 12))!
        let locale = Locale(identifier: "en_US_POSIX")

        XCTAssertEqual(OverlayDateFormat.short.string(from: date, locale: locale, calendar: calendar), "1/2/24")
        XCTAssertEqual(OverlayDateFormat.medium.string(from: date, locale: locale, calendar: calendar), "Jan 2, 2024")
        XCTAssertEqual(OverlayDateFormat.long.string(from: date, locale: locale, calendar: calendar), "January 2, 2024")
        XCTAssertEqual(OverlayDateFormat.full.string(from: date, locale: locale, calendar: calendar), "Tuesday, January 2, 2024")

        let numbersOnly = OverlayDateFormat.numbersOnly.string(from: date, locale: locale, calendar: calendar)
        XCTAssertTrue(numbersOnly.contains("2024"))
        XCTAssertNil(numbersOnly.range(of: "[A-Za-z]", options: .regularExpression))
    }

    func testOverlayBackgroundControlsAllowZeroOpacityAndIndependentTransparency() {
        XCTAssertEqual(OverlayBackgroundPolicy.effectiveOpacity(opacity: 0, transparency: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(OverlayBackgroundPolicy.effectiveOpacity(opacity: 1, transparency: 0), 1, accuracy: 0.0001)
        XCTAssertEqual(OverlayBackgroundPolicy.effectiveOpacity(opacity: 0.8, transparency: 0.25), 0.6, accuracy: 0.0001)
        XCTAssertEqual(OverlayBackgroundPolicy.effectiveOpacity(opacity: 1.2, transparency: -1), 1, accuracy: 0.0001)
        XCTAssertEqual(OverlayBackgroundPolicy.effectiveOpacity(opacity: 1, transparency: 1), 0, accuracy: 0.0001)
    }

    func testAdaptiveClockColorChangesOnlyOneSharedClockLayer() {
        let plan = ClockOverlayPlacementPolicy.plan(showTime: true, color: .adaptive, visibleTileCount: 2)
        XCTAssertEqual(plan.sharedClockCount, 1)
        XCTAssertEqual(plan.perTileClockCounts, [0, 0])
        XCTAssertEqual(plan.totalClockCount, 1)
        XCTAssertTrue(plan.adaptiveColorUsesRepresentativeImage)
        XCTAssertEqual(AdaptiveClockColorResolver.colors(forLuminances: [0.12, 0.92, 0.58]), [.white, .black, .black])
        XCTAssertEqual(ClockColor.adaptive.title, "Adaptive")
        XCTAssertEqual(ClockColor.amber.title, "Amber")
        XCTAssertEqual(ClockColor.purple.title, "Purple")
    }

    func testCaptureDatePolicyKeepsLivePhotoDateToOneMediaSurfaceLayer() {
        XCTAssertTrue(CaptureDateOverlayPolicy.mediaSurfaceOwnsDate(for: .livePhoto))
        XCTAssertTrue(CaptureDateOverlayPolicy.mediaSurfaceOwnsDate(for: .video))
        XCTAssertFalse(CaptureDateOverlayPolicy.showsStandaloneDate(enabled: true, kind: .livePhoto, layoutImagesEmpty: true))
        XCTAssertFalse(CaptureDateOverlayPolicy.showsStandaloneDate(enabled: true, kind: .video, layoutImagesEmpty: true))
        XCTAssertTrue(CaptureDateOverlayPolicy.showsStandaloneDate(enabled: true, kind: .photo, layoutImagesEmpty: true))
    }

    func testLivePhotoPlaybackPolicyPreventsRestartLoopsAndStaleLoads() {
        XCTAssertFalse(LivePhotoPlaybackPolicy.shouldStartPlayback(isPlaying: true, playbackActive: true))
        XCTAssertTrue(LivePhotoPlaybackPolicy.shouldStartPlayback(isPlaying: true, playbackActive: false))
        XCTAssertTrue(LivePhotoPlaybackPolicy.shouldRestartAfterPlayback(loop: true, isPlaying: true))
        XCTAssertFalse(LivePhotoPlaybackPolicy.shouldRestartAfterPlayback(loop: true, isPlaying: false))
        XCTAssertTrue(LivePhotoPlaybackPolicy.acceptsLoadedPhoto(assetID: "live-2", currentAssetID: "live-2", requestGeneration: 4, currentGeneration: 4))
        XCTAssertFalse(LivePhotoPlaybackPolicy.acceptsLoadedPhoto(assetID: "live-1", currentAssetID: "live-2", requestGeneration: 3, currentGeneration: 4))
        XCTAssertFalse(LivePhotoPlaybackPolicy.acceptsLoadedPhoto(assetID: "live-2", currentAssetID: "live-2", requestGeneration: 3, currentGeneration: 4))
    }

    func testAppleAlbumCategoriesMergeCloudSharedIntoSharedWithoutLosingSelections() {
        let smart = AlbumReference(id: "smart", title: "Favorites", subtype: Int(PHAssetCollectionSubtype.smartAlbumFavorites.rawValue), estimatedCount: 2, isSmart: true, isShared: false)
        let user = AlbumReference(id: "user", title: "Family", subtype: Int(PHAssetCollectionSubtype.albumRegular.rawValue), estimatedCount: 2, isSmart: false, isShared: false)
        let sharedFlag = AlbumReference(id: "shared-flag", title: "Shared flag", subtype: 0, estimatedCount: 2, isSmart: false, isShared: true)
        let sharedSubtype = AlbumReference(id: "shared-subtype", title: "Shared subtype", subtype: Int(PHAssetCollectionSubtype.albumCloudShared.rawValue), estimatedCount: 3, isSmart: false, isShared: false)
        let other = AlbumReference(id: "other", title: "Imported", subtype: Int(PHAssetCollectionSubtype.albumImported.rawValue), estimatedCount: 2, isSmart: false, isShared: false)
        XCTAssertEqual(AppleAlbumCategory.category(for: smart), .smart)
        XCTAssertEqual(AppleAlbumCategory.category(for: user), .user)
        XCTAssertEqual(AppleAlbumCategory.category(for: sharedFlag), .shared)
        XCTAssertEqual(AppleAlbumCategory.category(for: sharedSubtype), .shared)
        XCTAssertEqual(AppleAlbumCategory.category(for: other), .other)

        let allAlbums = [smart, user, sharedFlag, sharedSubtype, other]
        XCTAssertEqual(AppleAlbumCategory.albums(from: allAlbums, in: .shared).map(\.id), [sharedFlag.id, sharedSubtype.id])
        XCTAssertEqual(AppleAlbumCategory.albums(from: allAlbums, in: .other).map(\.id), [other.id])
        let selected = [sharedFlag, sharedSubtype]
        XCTAssertEqual(selected.map(\.id), [sharedFlag.id, sharedSubtype.id])
    }

    func testAppleAlbumCategoryDefaultOrderIsStableAndIncludesEmptyCategories() {
        XCTAssertEqual(
            AppleAlbumCategoryOrdering.categories(from: nil),
            [.smart, .user, .shared, .other]
        )
        XCTAssertEqual(
            AppleAlbumCategoryOrdering.categories(from: ["other", "smart", "user", "shared"]),
            [.other, .smart, .user, .shared]
        )
    }

    func testAlbumVisibilityHidesEmptyAlbumsByDefaultAndCanShowThem() {
        let empty = AlbumReference(id: "empty", title: "Empty", subtype: 0, estimatedCount: 0, isSmart: false, isShared: false)
        let populated = AlbumReference(id: "populated", title: "Populated", subtype: 0, estimatedCount: 4, isSmart: false, isShared: false)

        XCTAssertFalse(CanvasSettings().effectiveShowEmptyAlbums)
        XCTAssertEqual(
            AlbumVisibilityPolicy.visible([empty, populated], showEmptyAlbums: false).map(\.id),
            [populated.id]
        )
        XCTAssertEqual(
            AlbumVisibilityPolicy.visible([empty, populated], showEmptyAlbums: true).map(\.id),
            [empty.id, populated.id]
        )
    }

    func testAppleAlbumCategoryReorderingPreservesUnknownIdentifiers() {
        let stored = ["smart", "future-category", "user", "shared", "other"]
        let reordered = AppleAlbumCategoryOrdering.moving(fromOffsets: IndexSet(integer: 0), toOffset: 4, in: stored)
        XCTAssertEqual(reordered, ["user", "future-category", "shared", "other", "smart"])
        XCTAssertEqual(
            AppleAlbumCategoryOrdering.categories(from: reordered),
            [.user, .shared, .other, .smart]
        )
        XCTAssertTrue(reordered.contains("future-category"))
    }

    @MainActor
    func testAppleAlbumCategoryReorderingPersistsAcrossSettingsStoreReload() {
        let suiteName = "CanvasTests.album-category-order.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = SettingsStore(defaults: defaults)
        let reordered = AppleAlbumCategoryOrdering.moving(
            fromOffsets: IndexSet(integer: 0),
            toOffset: 4,
            in: first.settings.albumCategoryOrder
        )
        first.update { $0.albumCategoryOrder = reordered }

        let restored = SettingsStore(defaults: defaults)
        XCTAssertEqual(restored.settings.albumCategoryOrder, reordered)
        XCTAssertEqual(
            AppleAlbumCategoryOrdering.categories(from: restored.settings.albumCategoryOrder),
            [.user, .shared, .other, .smart]
        )
    }

    func testAnalogClockFaceOptionsAreSelectable() {
        XCTAssertEqual(ClockStyle.allCases.map(\.title), ["Digital", "Analog"])
        XCTAssertEqual(AnalogClockFace.allCases.map(\.title), ["Arabic numerals", "Roman numerals", "Dash markers"])
    }

    func testOverlayPreviewUsesUniformDeviceCanvasScale() {
        let portrait = OverlayPreviewGeometry.normalizedCanvasSize(screenSize: CGSize(width: 1366, height: 1024), isLandscape: false)
        XCTAssertEqual(portrait, CGSize(width: 1024, height: 1366))
        XCTAssertEqual(
            OverlayPreviewGeometry.scale(containerSize: CGSize(width: 400, height: 240), canvasSize: CGSize(width: 1366, height: 1024)),
            240.0 / 1024.0,
            accuracy: 0.0001
        )
    }

    func testHomeStartCardSurfacesShareOneAction() {
        let actions = HomeStartCardSurface.allCases.map(HomeStartCardInteraction.action(for:))
        XCTAssertEqual(Set(actions), [.startOrRecover])
    }

    func testHomeAlbumAreaUsesRemainingViewportWithoutFixedBottomSpacer() {
        XCTAssertEqual(HomeContentGeometry.albumAreaHeight(viewportHeight: 1000, fixedContentHeight: 250, minimumHeight: 190), 750, accuracy: 0.001)
        XCTAssertEqual(HomeContentGeometry.albumAreaHeight(viewportHeight: 300, fixedContentHeight: 250, minimumHeight: 190), 190, accuracy: 0.001)
    }

    func testHomePlaybackSummaryReflectsSelectedTransitions() {
        XCTAssertEqual(
            HomePlaybackSummary.label(queueMode: .shuffle, transition: .slideLeft),
            "Shuffle · Slide left"
        )
        XCTAssertEqual(
            HomePlaybackSummary.label(queueMode: .shuffle, transition: .zoomIn),
            "Shuffle · Zoom in"
        )
    }

    func testHomeStartCardEntireBoundsShareOneAction() {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 180)
        let points = [
            CGPoint(x: 30, y: 30), // thumbnail/title region
            CGPoint(x: 420, y: 92), // summary/empty space
            CGPoint(x: 870, y: 92) // trailing caret region
        ]
        XCTAssertTrue(points.allSatisfy { HomeStartCardHitRegion.action(at: $0, in: bounds) == .startOrRecover })
        XCTAssertNil(HomeStartCardHitRegion.action(at: CGPoint(x: 920, y: 92), in: bounds))
    }

    func testHomeToolbarHitRegionsStayInsidePortraitAndLandscapeHeaders() {
        for size in [CGSize(width: 768, height: 70), CGSize(width: 1366, height: 70)] {
            let frames = HomeToolbarHitRegion.frames(in: size)
            XCTAssertTrue(frames.manageAlbums.minX >= 28)
            XCTAssertTrue(frames.settings.maxX <= size.width - 28)
            XCTAssertFalse(frames.manageAlbums.intersects(frames.settings))
            XCTAssertEqual(frames.manageAlbums.height, 46)
            XCTAssertEqual(frames.settings.height, 46)
        }
    }

    func testFrameLaunchPolicyRequiresPlayableMedia() {
        XCTAssertFalse(FrameLaunchPolicy.hasPlayableMedia([]))
        XCTAssertEqual(FrameLaunchPolicy.decision(for: []), .needsSelection)
        let item = CanvasMediaItem(id: "apple:frame", source: .applePhotos, kind: .photo, creationDate: nil, filename: "frame.jpg", isFavorite: false, pixelWidth: 100, pixelHeight: 100, albumTitle: "Frame", appleAsset: nil, localURL: URL(fileURLWithPath: "/tmp/frame.jpg"), contentHash: nil)
        XCTAssertTrue(FrameLaunchPolicy.hasPlayableMedia([item]))
        XCTAssertEqual(FrameLaunchPolicy.decision(for: [item]), .ready)
        let google = CanvasMediaItem(id: "google:frame", source: .googlePhotos, kind: .photo, creationDate: nil, filename: "google-frame.jpg", isFavorite: false, pixelWidth: 100, pixelHeight: 100, albumTitle: "Saved Google", appleAsset: nil, localURL: URL(fileURLWithPath: "/tmp/google-frame.jpg"), contentHash: "google-frame")
        XCTAssertEqual(FrameLaunchPolicy.decision(for: [google]), .ready)
    }

    func testFrameLaunchPolicyMakesRepeatedStartIdempotent() {
        XCTAssertTrue(FrameLaunchPolicy.canStart(isPresented: false, isStarting: false))
        XCTAssertFalse(FrameLaunchPolicy.canStart(isPresented: true, isStarting: false))
        XCTAssertFalse(FrameLaunchPolicy.canStart(isPresented: false, isStarting: true))
    }

    func testMediaBackdropUsesCurrentMediaOnlyWhenConfiguredAndAvailable() {
        XCTAssertEqual(MediaBackdropResolver.mode(imageCount: 1, blurredBackground: true), .mediaDerived)
        XCTAssertEqual(MediaBackdropResolver.mode(imageCount: 3, blurredBackground: true), .mediaDerived)
        XCTAssertEqual(MediaBackdropResolver.mode(imageCount: 0, blurredBackground: true), .neutral)
        XCTAssertEqual(MediaBackdropResolver.mode(imageCount: 1, blurredBackground: false), .neutral)
    }

    func testHomePreviewSelectionRotatesDeterministicallyWithoutChangingCount() {
        XCTAssertEqual(HomePreviewSelection.rotatedIndices(count: 6, limit: 4, seed: 7, albumID: "family"), HomePreviewSelection.rotatedIndices(count: 6, limit: 4, seed: 7, albumID: "family"))
        XCTAssertEqual(HomePreviewSelection.rotatedIndices(count: 0, limit: 4, seed: 7, albumID: "family"), [])
        XCTAssertEqual(HomePreviewSelection.rotatedIndices(count: 2, limit: 4, seed: 7, albumID: "family").count, 2)
        XCTAssertNotEqual(HomePreviewSelection.rotatedIndices(count: 6, limit: 4, seed: 7, albumID: "family"), HomePreviewSelection.rotatedIndices(count: 6, limit: 4, seed: 8, albumID: "family"))
    }

    func testHomePreviewLayoutUsesNaturalOrientationAwarePairs() {
        let landscapeCanvas = CGSize(width: 1200, height: 700)
        let portraitCanvas = CGSize(width: 700, height: 1200)
        let landscape = CGSize(width: 1600, height: 900)
        let landscape2 = CGSize(width: 1400, height: 900)
        let portrait = CGSize(width: 900, height: 1400)
        let portrait2 = CGSize(width: 800, height: 1200)

        XCTAssertEqual(
            HomePreviewLayoutResolver.selection(imageSizes: [landscape, landscape2, portrait], canvasSize: landscapeCanvas, isLandscapeDevice: true),
            HomePreviewLayoutSelection(style: .pairHorizontal, indices: [0, 1])
        )
        XCTAssertEqual(
            HomePreviewLayoutResolver.selection(imageSizes: [portrait, portrait2, landscape], canvasSize: portraitCanvas, isLandscapeDevice: false),
            HomePreviewLayoutSelection(style: .pairVertical, indices: [0, 1])
        )
    }

    func testHomePreviewLayoutAvoidsMixedOrTinyFallbacks() {
        let landscapeCanvas = CGSize(width: 1200, height: 700)
        let portraitCanvas = CGSize(width: 700, height: 1200)
        let landscape = CGSize(width: 1600, height: 900)
        let portrait = CGSize(width: 900, height: 1400)

        XCTAssertEqual(
            HomePreviewLayoutResolver.selection(imageSizes: [landscape, portrait], canvasSize: landscapeCanvas, isLandscapeDevice: true),
            HomePreviewLayoutSelection(style: .single, indices: [0])
        )
        XCTAssertEqual(
            HomePreviewLayoutResolver.selection(imageSizes: [portrait], canvasSize: portraitCanvas, isLandscapeDevice: false),
            HomePreviewLayoutSelection(style: .single, indices: [0])
        )
        XCTAssertEqual(
            HomePreviewLayoutResolver.selection(imageSizes: [landscape, landscape], canvasSize: portraitCanvas, isLandscapeDevice: false),
            HomePreviewLayoutSelection(style: .pairVertical, indices: [0, 1])
        )
    }

    func testClockPreviewPrefersAvailableLocalMedia() {
        let unavailable = CanvasMediaItem(id: "missing", source: .googlePhotos, kind: .photo, creationDate: nil, filename: "missing.jpg", isFavorite: false, pixelWidth: 100, pixelHeight: 100, albumTitle: "Saved", appleAsset: nil, localURL: nil, contentHash: nil)
        let available = CanvasMediaItem(id: "local", source: .googlePhotos, kind: .photo, creationDate: nil, filename: "local.jpg", isFavorite: false, pixelWidth: 100, pixelHeight: 100, albumTitle: "Saved", appleAsset: nil, localURL: URL(fileURLWithPath: "/tmp/local.jpg"), contentHash: nil)
        XCTAssertEqual(ClockPreviewMediaResolver.representative(from: [unavailable, available])?.id, "local")
    }

    func testScheduleCrossesMidnight() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var rule = ScheduleRule(); rule.weekdays = [2]; rule.startMinutes = 22 * 60; rule.stopMinutes = 6 * 60
        let active = calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 23, minute: 0))!
        XCTAssertTrue(ScheduleEngine.isActive(rule, date: active, calendar: calendar))
        let afterMidnight = calendar.date(from: DateComponents(year: 2026, month: 8, day: 4, hour: 2, minute: 0))!
        XCTAssertTrue(ScheduleEngine.isActive(rule, date: afterMidnight, calendar: calendar))
        let afterStop = calendar.date(from: DateComponents(year: 2026, month: 8, day: 4, hour: 6, minute: 0))!
        XCTAssertFalse(ScheduleEngine.isActive(rule, date: afterStop, calendar: calendar))
    }

    func testAutomaticNightDimmingCoversOnlyTheConfiguredOvernightWindow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(hour: Int, minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 4, hour: hour, minute: minute))!
        }

        XCTAssertFalse(NightDimmingPolicy.isActive(enabled: true, startMinutes: 22 * 60, stopMinutes: 7 * 60, date: date(hour: 12), calendar: calendar))
        XCTAssertTrue(NightDimmingPolicy.isActive(enabled: true, startMinutes: 22 * 60, stopMinutes: 7 * 60, date: date(hour: 22), calendar: calendar))
        XCTAssertTrue(NightDimmingPolicy.isActive(enabled: true, startMinutes: 22 * 60, stopMinutes: 7 * 60, date: date(hour: 2), calendar: calendar))
        XCTAssertFalse(NightDimmingPolicy.isActive(enabled: true, startMinutes: 22 * 60, stopMinutes: 7 * 60, date: date(hour: 7), calendar: calendar))
        XCTAssertFalse(NightDimmingPolicy.isActive(enabled: false, startMinutes: 22 * 60, stopMinutes: 7 * 60, date: date(hour: 23), calendar: calendar))
        XCTAssertFalse(NightDimmingPolicy.isActive(enabled: true, startMinutes: 0, stopMinutes: 0, date: date(hour: 0), calendar: calendar))
    }

    func testPresetRoundTrip() throws {
        let settings = CanvasSettings(); let data = try JSONEncoder().encode(settings); let decoded = try JSONDecoder().decode(CanvasSettings.self, from: data)
        XCTAssertEqual(settings, decoded)
    }

    func testApplyingPresetPreservesSavedPresetLibrary() {
        let first = CanvasPreset(name: "Morning", settings: CanvasSettings())
        var snapshot = CanvasSettings()
        snapshot.photoDuration = 60
        let second = CanvasPreset(name: "Evening", settings: snapshot)
        let restored = PresetApplication.settings(for: second, preserving: [first, second])
        XCTAssertEqual(restored.photoDuration, 60)
        XCTAssertEqual(restored.presets.map(\.id), [first.id, second.id])
    }

    func testPresetSavePolicyValidatesNamesAndStoresTrimmedSnapshot() {
        var snapshot = CanvasSettings()
        snapshot.photoDuration = 42
        let existing = [CanvasPreset(name: "Evening", settings: CanvasSettings())]

        if case .failure(.emptyName) = PresetSavePolicy.append(name: "  \n", snapshot: snapshot, to: existing) {
            // expected
        } else {
            XCTFail("An empty preset name must be rejected visibly")
        }
        if case .failure(.duplicateName) = PresetSavePolicy.append(name: " evening ", snapshot: snapshot, to: existing) {
            // expected
        } else {
            XCTFail("Duplicate preset names must be rejected")
        }
        guard case .success(let saved) = PresetSavePolicy.append(name: "  Morning  ", snapshot: snapshot, to: existing) else {
            return XCTFail("A valid preset name should save")
        }
        XCTAssertEqual(saved.map(\.name), ["Evening", "Morning"])
        XCTAssertEqual(saved.last?.settings.photoDuration, 42)
        XCTAssertTrue(saved.last?.settings.presets.isEmpty == true)
    }

    @MainActor
    func testPresetSavePersistsAcrossSettingsStoreReload() {
        let suiteName = "CanvasTests.presets.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = SettingsStore(defaults: defaults)
        var snapshot = first.settings
        snapshot.photoDuration = 99
        guard case .success(let presets) = PresetSavePolicy.append(name: "Night", snapshot: snapshot, to: first.settings.presets) else {
            return XCTFail("The valid preset should be produced")
        }
        first.update { $0.presets = presets }

        let restored = SettingsStore(defaults: defaults)
        XCTAssertEqual(restored.settings.presets.map(\.name), ["Night"])
        XCTAssertEqual(restored.settings.presets.first?.settings.photoDuration, 99)
    }

    func testLegacyAlbumReferenceDecodesAsApplePhotos() throws {
        let data = #"{"id":"legacy","title":"Family","subtype":0,"estimatedCount":3,"isSmart":false,"isShared":false}"#.data(using: .utf8)!
        let album = try JSONDecoder().decode(AlbumReference.self, from: data)
        XCTAssertEqual(album.source, .applePhotos)
    }

    func testCrossSourceIdentityDeduplicatesSameOriginal() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let apple = CanvasMediaItem(id: "apple:a", source: .applePhotos, kind: .photo, creationDate: date, filename: "IMG_1234.HEIC", isFavorite: false, pixelWidth: 4032, pixelHeight: 3024, albumTitle: "Apple", appleAsset: nil, localURL: nil, contentHash: nil)
        let google = CanvasMediaItem(id: "google:g", source: .googlePhotos, kind: .photo, creationDate: date, filename: "IMG_1234.JPG", isFavorite: false, pixelWidth: 4032, pixelHeight: 3024, albumTitle: "Google", appleAsset: nil, localURL: nil, contentHash: "hash")
        XCTAssertEqual(MediaIdentityMatcher.deduplicated([apple, google]).map(\.id), ["apple:a"])
    }

    @MainActor
    func testTimingSettingsPersist() {
        let suiteName = "CanvasTests.timing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = SettingsStore(defaults: defaults)
        first.settings.photoDuration = 127
        first.settings.livePhotoDuration = 305
        first.settings.videoDuration = 901

        let restored = SettingsStore(defaults: defaults)
        XCTAssertEqual(restored.settings.photoDuration, 127)
        XCTAssertEqual(restored.settings.livePhotoDuration, 305)
        XCTAssertEqual(restored.settings.videoDuration, 901)
    }

    @MainActor
    func testTransitionSelectionPersistsAcrossSettingsStoreReload() {
        let suiteName = "CanvasTests.transition.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = SettingsStore(defaults: defaults)
        first.update { $0.transition = .slideRight }

        let restored = SettingsStore(defaults: defaults)
        XCTAssertEqual(restored.settings.transition, .slideRight)
        XCTAssertEqual(
            HomePlaybackSummary.label(queueMode: restored.settings.queueMode, transition: restored.settings.transition),
            "Shuffle · Slide right"
        )
    }

    @MainActor
    func testOverlayOpacitySettingsUpdateAndPersistAsOneSnapshot() {
        let suiteName = "CanvasTests.overlay-opacity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = SettingsStore(defaults: defaults)
        first.update {
            $0.overlays.opacity = 0.43
            $0.overlays.backgroundTransparency = 0.72
            $0.overlays.clockOpacity = 0.67
            $0.overlays.clockFont = .serif
            $0.overlays.clockColor = .orange
            $0.overlays.clockStyle = .analog
            $0.overlays.analogClockFace = .roman
            $0.overlays.dateFormat = .numbersOnly
            $0.overlays.textWeight = .bold
            $0.overlays.textStrokeEnabled = true
            $0.overlays.textStrokeColor = .cyan
            $0.overlays.textStrokeWidth = 4.5
            $0.overlays.clockStrokeEnabled = false
            $0.overlays.clockStrokeColor = .orange
            $0.overlays.clockStrokeWidth = 2
            $0.overlays.captureDateStyle = .lightBadgeDarkText
            $0.framingMode = .fillZoom
        }
        XCTAssertEqual(first.settings.overlays.opacity, 0.43, accuracy: 0.0001)
        XCTAssertEqual(first.settings.overlays.backgroundTransparency ?? 0, 0.72, accuracy: 0.0001)
        XCTAssertEqual(first.settings.overlays.clockOpacity ?? 0, 0.67, accuracy: 0.0001)

        let restored = SettingsStore(defaults: defaults)
        XCTAssertEqual(restored.settings.overlays.opacity, 0.43, accuracy: 0.0001)
        XCTAssertEqual(restored.settings.overlays.clockOpacity ?? 0, 0.67, accuracy: 0.0001)
        XCTAssertEqual(restored.settings.overlays.backgroundTransparency ?? 0, 0.72, accuracy: 0.0001)
        XCTAssertEqual(restored.settings.overlays.clockFont, .serif)
        XCTAssertEqual(restored.settings.overlays.clockColor, .orange)
        XCTAssertEqual(restored.settings.overlays.clockStyle, .analog)
        XCTAssertEqual(restored.settings.overlays.analogClockFace, .roman)
        XCTAssertEqual(restored.settings.overlays.dateFormat, .numbersOnly)
        XCTAssertEqual(restored.settings.overlays.textWeight, .bold)
        XCTAssertEqual(restored.settings.overlays.textStrokeEnabled, true)
        XCTAssertEqual(restored.settings.overlays.textStrokeColor, .cyan)
        XCTAssertEqual(restored.settings.overlays.textStrokeWidth ?? 0, 4.5, accuracy: 0.001)
        XCTAssertEqual(restored.settings.overlays.clockStrokeEnabled, false)
        XCTAssertEqual(restored.settings.overlays.clockStrokeColor, .orange)
        XCTAssertEqual(restored.settings.overlays.clockStrokeWidth ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(restored.settings.overlays.captureDateStyle, .lightBadgeDarkText)
        XCTAssertEqual(restored.settings.effectiveFramingMode, .fillZoom)
    }

    @MainActor
    func testSettingsMigrationPersistsNeutralFullscreenDefaults() throws {
        let suiteName = "CanvasTests.settings-migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var legacy = CanvasSettings()
        legacy.backgroundHex = "#0B1020"
        legacy.fitMode = true
        legacy.overlays.textStrokeEnabled = true
        legacy.overlays.textStrokeColor = .cyan
        legacy.overlays.textStrokeWidth = 4
        legacy.overlays.clockStrokeEnabled = nil
        legacy.overlays.clockStrokeColor = nil
        legacy.overlays.clockStrokeWidth = nil
        defaults.set(try JSONEncoder().encode(legacy), forKey: "canvas.settings.v1")

        let migrated = SettingsStore(defaults: defaults)
        XCTAssertFalse(migrated.settings.fitMode)
        XCTAssertEqual(migrated.settings.backgroundHex, "#151513")
        XCTAssertEqual(migrated.settings.overlays.clockStrokeEnabled, true)
        XCTAssertEqual(migrated.settings.overlays.clockStrokeColor, .cyan)
        XCTAssertEqual(migrated.settings.overlays.clockStrokeWidth ?? 0, 4, accuracy: 0.001)
        let relaunched = SettingsStore(defaults: defaults)
        XCTAssertFalse(relaunched.settings.fitMode)
        XCTAssertEqual(relaunched.settings.backgroundHex, "#151513")
        XCTAssertEqual(relaunched.settings.overlays.clockStrokeEnabled, true)
    }

    @MainActor
    func testSchemaFourForcedFitIsRestoredOnceToFillZoom() throws {
        let suiteName = "CanvasTests.framing-migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var affected = CanvasSettings()
        affected.framingMode = .fitWithBorder
        defaults.set(try JSONEncoder().encode(affected), forKey: "canvas.settings.v1")
        defaults.set(4, forKey: "canvas.settings.schema")

        let migrated = SettingsStore(defaults: defaults)
        XCTAssertEqual(migrated.settings.effectiveFramingMode, .fillZoom)
        XCTAssertEqual(defaults.integer(forKey: "canvas.settings.schema"), 5)

        migrated.update { $0.framingMode = .fitWithBorder }
        let userSelectedFit = SettingsStore(defaults: defaults)
        XCTAssertEqual(userSelectedFit.settings.effectiveFramingMode, .fitWithBorder)
    }

    @MainActor
    func testSchemaThreeExplicitFramingChoiceIsPreservedWhenAdvancingSchema() throws {
        for framingMode in [MediaFramingMode.fillZoom, .fitWithBorder] {
            let suiteName = "CanvasTests.framing-preserve-\(framingMode)-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }

            var settings = CanvasSettings()
            settings.framingMode = framingMode
            defaults.set(try JSONEncoder().encode(settings), forKey: "canvas.settings.v1")
            defaults.set(3, forKey: "canvas.settings.schema")

            let restored = SettingsStore(defaults: defaults)
            XCTAssertEqual(restored.settings.effectiveFramingMode, framingMode)
            XCTAssertEqual(defaults.integer(forKey: "canvas.settings.schema"), 5)
        }
    }

    @MainActor
    func testUnlimitedVideoMaximumPersists() {
        let suiteName = "CanvasTests.unlimited.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = SettingsStore(defaults: defaults)
        first.settings.videoDuration = 0
        XCTAssertEqual(SettingsStore(defaults: defaults).settings.videoDuration, 0)
    }

    @MainActor
    func testMutedVideoAudioStateIsAppliedToPlayer() {
        let player = AVPlayer()
        VideoAudioState.apply(to: player, muted: true, volume: 0.8)
        XCTAssertTrue(player.isMuted)
        XCTAssertEqual(player.volume, 0)
        VideoAudioState.apply(to: player, muted: false, volume: 0.35)
        XCTAssertFalse(player.isMuted)
        XCTAssertEqual(player.volume, 0.35, accuracy: 0.001)
    }

    @MainActor
    func testGlobalMuteIsAppliedToLivePhotos() {
        let view = PHLivePhotoView()
        VideoAudioState.apply(to: view, muted: true)
        XCTAssertTrue(view.isMuted)
        VideoAudioState.apply(to: view, muted: false)
        XCTAssertFalse(view.isMuted)
    }

    @MainActor
    func testGoogleOAuthClientIsBundled() {
        XCTAssertTrue(GooglePhotosService().configurationAvailable)
    }

    func testGooglePickerBrowserFallbackUsesAutoclose() {
        let picker = URL(string: "https://photos.google.com/picker/session-123")!
        XCTAssertEqual(GooglePhotosService.browserURL(for: picker).absoluteString, "https://photos.google.com/picker/session-123/autoclose")
        let alreadyClosed = URL(string: "https://photos.google.com/picker/session-123/autoclose")!
        XCTAssertEqual(GooglePhotosService.browserURL(for: alreadyClosed), alreadyClosed)
        let withQuery = URL(string: "https://photospicker.google.com/picker/session-123?account=1")!
        XCTAssertEqual(GooglePhotosService.browserURL(for: withQuery).absoluteString, "https://photospicker.google.com/picker/session-123/autoclose?account=1")
    }

    func testGooglePickerRouteValidationRejectsRawOrBlankURL() {
        XCTAssertNotNil(GooglePhotosService.validatedPickerURL(URL(string: "https://photos.google.com/picker/session-123")!))
        XCTAssertNil(GooglePhotosService.validatedPickerURL(URL(string: "http://photos.google.com/picker/session-123")!))
        XCTAssertNil(GooglePhotosService.validatedPickerURL(URL(string: "https://photos.google.com")!))
        XCTAssertEqual(GooglePhotosService.pickerHandoff(nativeLinkOpened: true), .nativeApp)
        XCTAssertEqual(GooglePhotosService.pickerHandoff(nativeLinkOpened: false), .browserFallback)
        XCTAssertTrue(GooglePhotosService.pickerSessionCanContinueAfterAppReturn(state: .selecting))
        XCTAssertTrue(GooglePhotosService.pickerSessionCanContinueAfterAppReturn(state: .syncing(completed: 1, total: 3)))
        XCTAssertFalse(GooglePhotosService.pickerSessionCanContinueAfterAppReturn(state: .failed("timed out")))
    }

    func testGooglePickerWaitIsBounded() {
        XCTAssertEqual(GooglePhotosService.maximumPickerWait, 300, accuracy: 0.001)
        XCTAssertEqual(GooglePhotosService.maximumPickerItemCount, 2_000)
    }

    func testGooglePickerPaginationTracksPagesAndStopsOnEmptyToken() {
        var pagination = GooglePickerPaginationState()
        XCTAssertFalse(pagination.hasNextPage)
        XCTAssertTrue(pagination.markPageTokenRequested("page-2"))
        XCTAssertFalse(pagination.markPageTokenRequested("page-2"))
        pagination.consume(nextPageToken: "page-2")
        XCTAssertEqual(pagination.pagesFetched, 1)
        XCTAssertEqual(pagination.nextPageToken, "page-2")
        XCTAssertTrue(pagination.hasNextPage)
        pagination.consume(nextPageToken: "")
        XCTAssertEqual(pagination.pagesFetched, 2)
        XCTAssertNil(pagination.nextPageToken)
        XCTAssertFalse(pagination.hasNextPage)
    }

    func testGooglePickerReadinessRaceRetriesOnlyBoundedPreconditions() {
        XCTAssertTrue(GooglePhotosService.pickerReadinessRetryAllowed(message: "FAILED_PRECONDITION: mediaItems are not ready", attempt: 0))
        XCTAssertTrue(GooglePhotosService.pickerReadinessRetryAllowed(message: "mediaItemsSet is false", attempt: 2))
        XCTAssertFalse(GooglePhotosService.pickerReadinessRetryAllowed(message: "HTTP 401 unauthorized", attempt: 0))
        XCTAssertFalse(GooglePhotosService.pickerReadinessRetryAllowed(message: "not ready", attempt: 3))
    }

    func testGooglePartialImportSummaryExplainsSavedSkippedAndRetry() {
        let summary = GooglePhotosImportSummary(
            albumID: "google-album:test",
            title: "Shared family",
            selectedCount: 404,
            savedCount: 20,
            preservedCount: 50,
            totalSavedCount: 70,
            skippedCount: 384,
            failureSummaries: [GoogleImportFailureSummary(category: .rateLimited, count: 300, example: "HTTP 429"), GoogleImportFailureSummary(category: .processing, count: 84, example: "HTTP 404")],
            canRetryFailedItems: true,
            updatedExistingAlbum: false
        )
        XCTAssertTrue(summary.isPartial)
        XCTAssertTrue(summary.message.contains("20 saved of 404 selected"))
        XCTAssertTrue(summary.message.contains("kept 50 previously saved items"))
        XCTAssertTrue(summary.message.contains("70 total items are available"))
        XCTAssertEqual(summary.failureSummaries.map(\.count).reduce(0, +), 384)
        XCTAssertTrue(summary.canRetryFailedItems)
    }

    func testGoogleSameNameSessionsRetainMixedContributorItemsAndStableAlbumIdentity() throws {
        // Picker does not expose contributor metadata. These IDs model items
        // returned from separate sessions after each contributor's media became
        // selectable in the signed-in Google library.
        let mine = makeGoogleRecord(id: "john-upload", timestamp: 100)
        let contributed = makeGoogleRecord(id: "wife-upload", timestamp: 200)
        let original = GoogleAlbumRecord(
            id: "google-album:google-home",
            title: "Google Home",
            items: [mine],
            updatedAt: Date(timeIntervalSince1970: 100),
            matchedAppleAlbumID: "apple-family"
        )

        let plan = GoogleAlbumImportPolicy.adding(
            title: "Google Home",
            records: [contributed],
            matchedAppleAlbumID: nil,
            to: [original],
            updatedAt: Date(timeIntervalSince1970: 300),
            newAlbumID: "must-not-replace-stable-id"
        )

        XCTAssertTrue(plan.updatedExistingAlbum)
        XCTAssertEqual(plan.albumID, original.id)
        XCTAssertEqual(plan.itemMerge.records.map(\.googleID), [mine.googleID, contributed.googleID])
        XCTAssertEqual(plan.itemMerge.preservedCount, 1)
        XCTAssertEqual(plan.itemMerge.addedCount, 1)
        XCTAssertEqual(plan.itemMerge.refreshedCount, 0)
        XCTAssertEqual(plan.albums.first?.matchedAppleAlbumID, "apple-family")

        let persisted = try JSONDecoder().decode(
            [GoogleAlbumRecord].self,
            from: JSONEncoder().encode(plan.albums)
        )
        XCTAssertEqual(persisted, plan.albums)
    }

    func testGoogleDifferentAlbumNameNeverCollapsesOnSharedSubset() {
        let shared = makeGoogleRecord(id: "shared")
        let original = GoogleAlbumRecord(
            id: "google-album:first",
            title: "First album",
            items: [shared, makeGoogleRecord(id: "first-only")],
            updatedAt: .now,
            matchedAppleAlbumID: nil
        )

        let plan = GoogleAlbumImportPolicy.adding(
            title: "Second album",
            records: [shared],
            matchedAppleAlbumID: nil,
            to: [original],
            newAlbumID: "google-album:second"
        )

        XCTAssertFalse(plan.updatedExistingAlbum)
        XCTAssertEqual(plan.albums.count, 2)
        XCTAssertEqual(plan.albumID, "google-album:second")
        XCTAssertEqual(plan.albums.first(where: { $0.id == original.id })?.title, original.title)
    }

    func testGoogleRetryRefreshPreservesFailuresOmittedByPicker() {
        struct RetryItem: Equatable { let id: String; let urlVersion: Int }
        let previous = [
            RetryItem(id: "returned", urlVersion: 1),
            RetryItem(id: "omitted", urlVersion: 1)
        ]
        let refreshed = [RetryItem(id: "returned", urlVersion: 2)]

        let merged = GoogleFailedItemRefreshPolicy.merging(
            refreshed: refreshed,
            into: previous,
            id: \.id
        )

        XCTAssertEqual(merged, [
            RetryItem(id: "returned", urlVersion: 2),
            RetryItem(id: "omitted", urlVersion: 1)
        ])
    }

    func testGoogleStableIDRefreshDeduplicatesAndNewestRecordWins() {
        let old = makeGoogleRecord(id: "same-google-id", timestamp: 100, relativePath: "same-google-id/old.jpg", contentHash: "old-hash")
        let firstRefresh = makeGoogleRecord(id: "same-google-id", timestamp: 100, relativePath: "same-google-id/new.jpg", contentHash: "new-hash")
        let finalRefresh = makeGoogleRecord(id: "same-google-id", timestamp: 100, relativePath: "same-google-id/final.jpg", contentHash: "final-hash")

        let result = GoogleMediaMergePolicy.adding([firstRefresh, finalRefresh], to: [old])

        XCTAssertEqual(result.records, [finalRefresh])
        XCTAssertEqual(result.preservedCount, 0)
        XCTAssertEqual(result.addedCount, 0)
        XCTAssertEqual(result.refreshedCount, 1)
    }

    func testGoogleDownloadPathsAreContentVersionedBeforeAlbumCommit() {
        let first = GoogleMediaStoragePathPolicy.relativePath(
            sanitizedGoogleID: "same-google-id",
            sanitizedFilename: "family.jpg",
            contentHash: "first-version"
        )
        let retry = GoogleMediaStoragePathPolicy.relativePath(
            sanitizedGoogleID: "same-google-id",
            sanitizedFilename: "family.jpg",
            contentHash: "first-version"
        )
        let refreshed = GoogleMediaStoragePathPolicy.relativePath(
            sanitizedGoogleID: "same-google-id",
            sanitizedFilename: "family.jpg",
            contentHash: "second-version"
        )

        XCTAssertEqual(first, retry)
        XCTAssertNotEqual(first, refreshed)
        XCTAssertTrue(first.hasPrefix("same-google-id/"))
        XCTAssertTrue(first.hasSuffix("/family.jpg"))
    }

    func testGoogleFailedAlbumCommitCleansOnlyUnreferencedStagedPaths() {
        let prior = makeGoogleRecord(id: "prior", relativePath: "prior/stable.jpg")
        let reused = makeGoogleRecord(id: "reused", relativePath: prior.relativePath)
        let staged = makeGoogleRecord(id: "staged", relativePath: "staged/new-hash-family.jpg")

        let cleanup = GoogleAlbumMediaCleanup.pathsFromUncommittedDownloads(
            [reused, staged],
            previouslyReferencedPaths: [prior.relativePath]
        )

        XCTAssertEqual(cleanup, [staged.relativePath])
        XCTAssertFalse(cleanup.contains(prior.relativePath))
    }

    func testGooglePartialRefreshPreservesOmittedRecordsAndCleansOnlySupersededPath() {
        let contributed = makeGoogleRecord(id: "wife-upload", timestamp: 100, relativePath: "wife-upload/wife.jpg")
        let oldMine = makeGoogleRecord(id: "john-upload", timestamp: 200, relativePath: "john-upload/old.jpg", contentHash: "old-hash")
        let refreshedMine = makeGoogleRecord(id: "john-upload", timestamp: 200, relativePath: "john-upload/new.jpg", contentHash: "new-hash")
        let album = GoogleAlbumRecord(
            id: "google-album:google-home",
            title: "Google Home",
            items: [contributed, oldMine],
            updatedAt: .now,
            matchedAppleAlbumID: nil
        )

        let plan = GoogleAlbumImportPolicy.adding(
            title: "Google Home",
            records: [refreshedMine],
            matchedAppleAlbumID: nil,
            to: [album],
            newAlbumID: "unused"
        )
        let removable = GoogleAlbumMediaCleanup.pathsNoLongerReferenced(
            replacing: 0,
            with: plan.itemMerge.records,
            in: [album]
        )

        XCTAssertEqual(Set(plan.itemMerge.records.map(\.googleID)), [contributed.googleID, refreshedMine.googleID])
        XCTAssertEqual(plan.itemMerge.preservedCount, 1)
        XCTAssertEqual(removable, [oldMine.relativePath])
        XCTAssertFalse(removable.contains(contributed.relativePath))
    }

    func testGoogleContentVersionCleanupRemovesUnreferencedOrphansOnly() {
        let stored = Set(["google-album/item/old.jpg", "google-album/item/new.jpg", "other/keep.jpg"])
        let referenced = Set(["google-album/item/new.jpg", "other/keep.jpg"])

        XCTAssertEqual(
            GoogleAlbumMediaCleanup.unreferencedStoredPaths(
                storedRelativePaths: stored,
                referencedPaths: referenced
            ),
            ["google-album/item/old.jpg"]
        )
    }

    @MainActor
    func testGoogleAdditiveRefreshKeepsPersistedAlbumSelectionStable() {
        let suiteName = "CanvasTests.google-additive-selection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = SettingsStore(defaults: defaults)
        let original = GoogleAlbumRecord(
            id: "google-album:google-home",
            title: "Google Home",
            items: [makeGoogleRecord(id: "john-upload")],
            updatedAt: .now,
            matchedAppleAlbumID: nil
        )
        first.settings.selectedAlbums = [original.reference]

        let plan = GoogleAlbumImportPolicy.adding(
            title: original.title,
            records: [makeGoogleRecord(id: "wife-upload", timestamp: 200)],
            matchedAppleAlbumID: nil,
            to: [original],
            newAlbumID: "unused"
        )
        let refreshed = plan.albums.first(where: { $0.id == plan.albumID })!.reference
        first.settings.selectedAlbums = first.settings.selectedAlbums.map { $0.id == plan.albumID ? refreshed : $0 }

        let restored = SettingsStore(defaults: defaults).settings.selectedAlbums
        XCTAssertEqual(restored.map(\.id), [original.id])
        XCTAssertEqual(restored.first?.estimatedCount, 2)
    }

    @MainActor
    func testGoogleSelectedAlbumPersistsForPlayback() {
        let suiteName = "CanvasTests.google-selection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        let album = AlbumReference(id: "google-album:test", title: "Shared family", subtype: 0, estimatedCount: 20, isSmart: false, isShared: true, source: .googlePhotos)
        store.settings.selectedAlbums = [album]
        XCTAssertEqual(SettingsStore(defaults: defaults).settings.selectedAlbums, [album])
    }

    func testDeletingOldGoogleAlbumRemovesOnlyItsLocalRecordAndFiles() {
        let oldItem = GoogleMediaRecord(googleID: "old", kind: .photo, creationDate: nil, filename: "old.jpg", pixelWidth: 100, pixelHeight: 100, relativePath: "old/old.jpg", contentHash: "old-hash")
        let retainedItem = GoogleMediaRecord(googleID: "new", kind: .photo, creationDate: nil, filename: "new.jpg", pixelWidth: 100, pixelHeight: 100, relativePath: "new/new.jpg", contentHash: "new-hash")
        let albums = [
            GoogleAlbumRecord(id: "google-album:old", title: "Old", items: [oldItem], updatedAt: .now, matchedAppleAlbumID: nil),
            GoogleAlbumRecord(id: "google-album:new", title: "New", items: [retainedItem], updatedAt: .now, matchedAppleAlbumID: nil)
        ]
        let plan = GoogleAlbumDeletionPlan.removing(albumID: "google-album:old", from: albums)
        XCTAssertEqual(plan?.remainingAlbums.map(\.id), ["google-album:new"])
        XCTAssertEqual(plan?.removableRelativePaths, ["old/old.jpg"])
    }

    func testDeletingSelectedGoogleAlbumCleansOnlyThatSourceSelection() {
        let selected = [
            AlbumReference(id: "google-album:old", title: "Old", subtype: 0, estimatedCount: 2, isSmart: false, isShared: true, source: .googlePhotos),
            AlbumReference(id: "google-album:new", title: "New", subtype: 0, estimatedCount: 2, isSmart: false, isShared: true, source: .googlePhotos),
            AlbumReference(id: "google-album:old", title: "Apple album with same ID", subtype: 0, estimatedCount: 2, isSmart: false, isShared: false, source: .applePhotos)
        ]
        let cleaned = AlbumSelectionCleanup.removingGoogleAlbum("google-album:old", from: selected)
        XCTAssertEqual(cleaned.map(\.title), ["New", "Apple album with same ID"])
    }

    func testStaleGoogleAlbumSelectionIsPrunedWithoutTouchingAppleSelection() {
        let selected = [
            AlbumReference(id: "google-album:missing", title: "Removed Google", subtype: 0, estimatedCount: 2, isSmart: false, isShared: true, source: .googlePhotos),
            AlbumReference(id: "google-album:kept", title: "Kept Google", subtype: 0, estimatedCount: 2, isSmart: false, isShared: true, source: .googlePhotos),
            AlbumReference(id: "apple-album:favorites", title: "Favorites", subtype: 0, estimatedCount: 4, isSmart: true, isShared: false)
        ]
        let repaired = AlbumSelectionCleanup.removingMissingGoogleAlbums(from: selected, validIDs: ["google-album:kept"])
        XCTAssertEqual(repaired.map(\.id), ["google-album:kept", "apple-album:favorites"])
    }

    @MainActor
    func testDeletingSelectedGoogleAlbumUpdatesPersistedSelectionAndRemainingPlayableMedia() {
        let suiteName = "CanvasTests.google-delete-selection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        let google = AlbumReference(id: "google-album:old", title: "Old Google", subtype: 0, estimatedCount: 2, isSmart: false, isShared: true, source: .googlePhotos)
        let apple = AlbumReference(id: "apple-album:favorites", title: "Favorites", subtype: 0, estimatedCount: 4, isSmart: true, isShared: false)
        store.settings.selectedAlbums = [google, apple]
        store.settings.selectedAlbums = AlbumSelectionCleanup.removingGoogleAlbum(google.id, from: store.settings.selectedAlbums)

        let restored = SettingsStore(defaults: defaults)
        XCTAssertEqual(restored.settings.selectedAlbums, [apple])
        let remaining = CanvasMediaItem(id: "apple:remaining", source: .applePhotos, kind: .photo, creationDate: nil, filename: "remaining.jpg", isFavorite: false, pixelWidth: 100, pixelHeight: 100, albumTitle: apple.title, appleAsset: nil, localURL: nil, contentHash: nil)
        XCTAssertTrue(FrameLaunchPolicy.hasPlayableMedia([remaining]))
    }

    func testDeletingGoogleAlbumPreservesSharedDownloadedMedia() {
        let shared = GoogleMediaRecord(googleID: "shared", kind: .photo, creationDate: nil, filename: "shared.jpg", pixelWidth: 100, pixelHeight: 100, relativePath: "shared/shared.jpg", contentHash: "shared-hash")
        let onlyOld = GoogleMediaRecord(googleID: "only-old", kind: .photo, creationDate: nil, filename: "old.jpg", pixelWidth: 100, pixelHeight: 100, relativePath: "only-old/old.jpg", contentHash: "old-hash")
        let albums = [
            GoogleAlbumRecord(id: "google-album:old", title: "Old", items: [shared, onlyOld], updatedAt: .now, matchedAppleAlbumID: nil),
            GoogleAlbumRecord(id: "google-album:other", title: "Other", items: [shared], updatedAt: .now, matchedAppleAlbumID: nil)
        ]
        let plan = GoogleAlbumDeletionPlan.removing(albumID: "google-album:old", from: albums)
        XCTAssertEqual(plan?.removableRelativePaths, ["only-old/old.jpg"])
        XCTAssertFalse(plan?.removableRelativePaths.contains("shared/shared.jpg") == true)
    }

    func testRefreshingGoogleAlbumPreservesFilesSharedWithAnotherAlbum() {
        let shared = GoogleMediaRecord(googleID: "shared", kind: .photo, creationDate: nil, filename: "shared.jpg", pixelWidth: 100, pixelHeight: 100, relativePath: "shared/shared.jpg", contentHash: "shared-hash")
        let removedFromRefresh = GoogleMediaRecord(googleID: "old", kind: .photo, creationDate: nil, filename: "old.jpg", pixelWidth: 100, pixelHeight: 100, relativePath: "old/old.jpg", contentHash: "old-hash")
        let replacement = GoogleMediaRecord(googleID: "new", kind: .photo, creationDate: nil, filename: "new.jpg", pixelWidth: 100, pixelHeight: 100, relativePath: "new/new.jpg", contentHash: "new-hash")
        let albums = [
            GoogleAlbumRecord(id: "google-album:refresh", title: "Refresh", items: [shared, removedFromRefresh], updatedAt: .now, matchedAppleAlbumID: nil),
            GoogleAlbumRecord(id: "google-album:other", title: "Other", items: [shared], updatedAt: .now, matchedAppleAlbumID: nil)
        ]
        let removable = GoogleAlbumMediaCleanup.pathsNoLongerReferenced(replacing: 0, with: [replacement], in: albums)
        XCTAssertEqual(removable, ["old/old.jpg"])
        XCTAssertFalse(removable.contains("shared/shared.jpg"))
    }

    func testGoogleAlbumPersistenceStoreTreatsCorruptDataAsLoadErrorAndPreservesIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-google-albums-corrupt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("albums.json")
        let original = Data("not-json".utf8)
        try original.write(to: url, options: .atomic)

        let store = GoogleAlbumPersistenceStore(url: url)
        XCTAssertEqual(store.albums, [])
        XCTAssertEqual(store.loadError, .corrupt)
        XCTAssertThrowsError(try store.persist([GoogleAlbumRecord(id: "must-not-write", title: "Lost", items: [], updatedAt: .now, matchedAppleAlbumID: nil)])) { error in
            XCTAssertEqual(error as? GoogleAlbumPersistenceError, .corrupt)
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testGoogleAlbumPersistenceStoreRefusesNewerSchemaWithoutOverwriting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-google-albums-newer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("albums.json")
        let newer = GoogleAlbumPersistenceDocument(
            schemaVersion: GoogleAlbumPersistenceDocument.currentSchemaVersion + 1,
            albums: []
        )
        let original = try JSONEncoder().encode(newer)
        try original.write(to: url, options: .atomic)

        let store = GoogleAlbumPersistenceStore(url: url)
        XCTAssertEqual(store.loadError, .unsupportedSchema(GoogleAlbumPersistenceDocument.currentSchemaVersion + 1))
        XCTAssertThrowsError(try store.persist([])) { error in
            XCTAssertEqual(error as? GoogleAlbumPersistenceError, .unsupportedSchema(GoogleAlbumPersistenceDocument.currentSchemaVersion + 1))
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testGoogleAlbumPersistenceStoreReadsPreservedWIPArrayFormat() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-google-albums-legacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("albums.json")
        let album = GoogleAlbumRecord(
            id: "google-album:legacy",
            title: "Google Home",
            items: [makeGoogleRecord(id: "legacy")],
            updatedAt: .now,
            matchedAppleAlbumID: nil
        )
        try JSONEncoder().encode([album]).write(to: url, options: .atomic)

        let store = GoogleAlbumPersistenceStore(url: url)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.albums, [album])
    }

    func testGoogleAlbumDeletePersistenceFailurePreservesAlbumAndPickerRetryState() {
        let album = GoogleAlbumRecord(
            id: "google-album:pending",
            title: "Google Home",
            items: [makeGoogleRecord(id: "pending")],
            updatedAt: .now,
            matchedAppleAlbumID: nil
        )

        let failed = GoogleAlbumDeletionCommitPolicy.decide(
            albumID: album.id,
            from: [album],
            pendingAlbumID: album.id,
            persistenceSucceeded: false
        )
        XCTAssertEqual(failed?.albums, [album])
        XCTAssertEqual(failed?.removableRelativePaths, [])
        XCTAssertEqual(failed?.discardPendingImport, false)

        let committed = GoogleAlbumDeletionCommitPolicy.decide(
            albumID: album.id,
            from: [album],
            pendingAlbumID: album.id,
            persistenceSucceeded: true
        )
        XCTAssertEqual(committed?.albums, [])
        XCTAssertEqual(committed?.discardPendingImport, true)
    }

    func testGoogleAppleMirrorRequiresFullReadWriteAuthorization() {
        XCTAssertTrue(GooglePhotosMirrorAuthorizationPolicy.permitsNamedAlbumMirroring(.authorized))
        XCTAssertFalse(GooglePhotosMirrorAuthorizationPolicy.permitsNamedAlbumMirroring(.limited))
        XCTAssertFalse(GooglePhotosMirrorAuthorizationPolicy.permitsNamedAlbumMirroring(.denied))
        XCTAssertFalse(GooglePhotosMirrorAuthorizationPolicy.permitsNamedAlbumMirroring(.restricted))
        XCTAssertFalse(GooglePhotosMirrorAuthorizationPolicy.permitsNamedAlbumMirroring(.notDetermined))
    }

    func testGooglePhotosAuthorizationCopyExplainsLimitedAndDeniedMirrorBehavior() {
        XCTAssertTrue(PhotoAuthorizationState.limited.explanation?.contains("Full Access") == true)
        XCTAssertTrue(PhotoAuthorizationState.limited.explanation?.contains("dedicated Apple Photos album") == true)
        XCTAssertTrue(PhotoAuthorizationState.denied.explanation?.contains("saved Google import") == true)
    }

    func testGoogleAppleMirrorRetryRemainsAvailableAcrossRelaunchForPendingItems() {
        let pending = GooglePhotosMirrorAlbumEntry(
            title: "Google Home",
            appleAlbumID: "apple-album",
            albumRemovedByUser: false,
            pendingReason: "1 item still needs copying.",
            assetsByGoogleID: [:],
            updatedAt: .now
        )
        let removed = GooglePhotosMirrorAlbumEntry(
            title: "Google Home",
            appleAlbumID: "deleted-album",
            albumRemovedByUser: true,
            pendingReason: nil,
            assetsByGoogleID: [:],
            updatedAt: .now
        )

        XCTAssertTrue(GooglePhotosMirrorRetryPolicy.shouldOfferRetry(entry: nil, expectedItemCount: 1, indexLoadFailed: false))
        XCTAssertTrue(GooglePhotosMirrorRetryPolicy.shouldOfferRetry(entry: pending, expectedItemCount: 1, indexLoadFailed: false))
        XCTAssertFalse(GooglePhotosMirrorRetryPolicy.shouldOfferRetry(entry: removed, expectedItemCount: 1, indexLoadFailed: false))
        XCTAssertFalse(GooglePhotosMirrorRetryPolicy.shouldOfferRetry(entry: pending, expectedItemCount: 1, indexLoadFailed: true))
    }

    func testGoogleAppleMirrorAlbumResolutionNeverGuesses() {
        XCTAssertEqual(
            GooglePhotosMirrorAlbumResolutionPolicy.resolve(
                persistedAlbumID: "apple-managed",
                persistedAlbumRemoved: false,
                persistedAlbumAccessible: true,
                markerVerifiedAlbumIDs: [],
                exactEditableAlbumIDs: ["same-name-user-album"]
            ),
            .reuse("apple-managed")
        )
        XCTAssertEqual(
            GooglePhotosMirrorAlbumResolutionPolicy.resolve(
                persistedAlbumID: "apple-deleted",
                persistedAlbumRemoved: false,
                persistedAlbumAccessible: false,
                markerVerifiedAlbumIDs: ["same-album-new-identifier"],
                exactEditableAlbumIDs: ["same-album-new-identifier"]
            ),
            .reuse("same-album-new-identifier")
        )
        XCTAssertEqual(
            GooglePhotosMirrorAlbumResolutionPolicy.resolve(
                persistedAlbumID: "apple-deleted",
                persistedAlbumRemoved: false,
                persistedAlbumAccessible: false,
                markerVerifiedAlbumIDs: [],
                exactEditableAlbumIDs: []
            ),
            .failRemoved
        )
        XCTAssertEqual(
            GooglePhotosMirrorAlbumResolutionPolicy.resolve(
                persistedAlbumID: nil,
                persistedAlbumRemoved: false,
                persistedAlbumAccessible: false,
                markerVerifiedAlbumIDs: ["marker-verified"],
                exactEditableAlbumIDs: ["unique-exact"]
            ),
            .reuse("marker-verified")
        )
        XCTAssertEqual(
            GooglePhotosMirrorAlbumResolutionPolicy.resolve(
                persistedAlbumID: nil,
                persistedAlbumRemoved: false,
                persistedAlbumAccessible: false,
                markerVerifiedAlbumIDs: [],
                exactEditableAlbumIDs: ["duplicate-a", "duplicate-b"]
            ),
            .failOwnershipUnverified
        )
        XCTAssertEqual(
            GooglePhotosMirrorAlbumResolutionPolicy.resolve(
                persistedAlbumID: nil,
                persistedAlbumRemoved: false,
                persistedAlbumAccessible: false,
                markerVerifiedAlbumIDs: [],
                exactEditableAlbumIDs: ["one-user-album"]
            ),
            .failOwnershipUnverified
        )
        XCTAssertEqual(
            GooglePhotosMirrorAlbumResolutionPolicy.resolve(
                persistedAlbumID: nil,
                persistedAlbumRemoved: false,
                persistedAlbumAccessible: false,
                markerVerifiedAlbumIDs: ["marker-a", "marker-b"],
                exactEditableAlbumIDs: ["marker-a", "marker-b"]
            ),
            .failAmbiguous
        )
        XCTAssertEqual(
            GooglePhotosMirrorAlbumResolutionPolicy.resolve(
                persistedAlbumID: nil,
                persistedAlbumRemoved: false,
                persistedAlbumAccessible: false,
                markerVerifiedAlbumIDs: [],
                exactEditableAlbumIDs: []
            ),
            .create
        )
    }

    func testGoogleAppleMirrorOwnershipFailuresNeverAdoptOrRecreateUserAlbums() {
        XCTAssertTrue(GoogleApplePhotosMirrorError.ownershipUnverified.errorDescription?.contains("did not adopt") == true)
        XCTAssertTrue(GoogleApplePhotosMirrorError.managedAlbumRemoved.errorDescription?.contains("did not create another album") == true)
        XCTAssertTrue(GoogleApplePhotosMirrorError.albumCreationFailed.errorDescription?.contains("No existing user album was changed") == true)
    }

    func testGoogleAppleMirrorMarkerCarriesCanvasOwnershipWithoutProviderIdentity() {
        let albumID = "google-album:home"
        let contentHash = String(repeating: "e", count: 64)
        let marker = GoogleApplePhotosMirrorIdentity.markerFilename(
            contentHash: contentHash,
            originalFilename: "family.jpg",
            canvasAlbumID: albumID
        )

        XCTAssertEqual(GoogleApplePhotosMirrorIdentity.contentHash(fromMarkerFilename: marker), contentHash)
        XCTAssertEqual(
            GoogleApplePhotosMirrorIdentity.ownerToken(fromMarkerFilename: marker),
            GoogleApplePhotosMirrorIdentity.ownerToken(for: albumID)
        )
        XCTAssertNil(
            GoogleApplePhotosMirrorIdentity.ownerToken(
                fromMarkerFilename: GoogleApplePhotosMirrorIdentity.markerFilename(
                    contentHash: contentHash,
                    originalFilename: "family.jpg"
                )
            )
        )
        XCTAssertNil(
            GoogleApplePhotosMirrorIdentity.contentHash(
                fromMarkerFilename: "canvas-google-not-an-owner-\(contentHash).jpg"
            )
        )
        XCTAssertNil(
            GoogleApplePhotosMirrorIdentity.contentHash(
                fromMarkerFilename: "canvas-google--\(contentHash).jpg"
            )
        )
    }

    func testGoogleAppleMirrorCrashMarkerRecoversAndDeduplicatesSameContent() {
        let first = makeGoogleRecord(id: "first", contentHash: String(repeating: "a", count: 64))
        let duplicate = makeGoogleRecord(id: "duplicate", contentHash: String(repeating: "a", count: 64))
        let marker = GoogleApplePhotosMirrorIdentity.markerFilename(
            contentHash: first.contentHash,
            originalFilename: first.filename
        )

        XCTAssertEqual(GoogleApplePhotosMirrorIdentity.contentHash(fromMarkerFilename: marker), first.contentHash)
        let result = GooglePhotosMirrorAssetReconciliationPolicy.reconcile(
            records: [first, duplicate],
            persistedEntries: [:],
            accessibleAssetIDs: ["apple-recovered"],
            recoveredAssetIDsByContentHash: [first.contentHash: "apple-recovered"],
            verifiedAt: Date(timeIntervalSince1970: 500)
        )

        XCTAssertTrue(result.recordsNeedingCreationByHash.isEmpty)
        XCTAssertEqual(result.alreadyMirroredCount, 2)
        XCTAssertEqual(result.entriesByGoogleID[first.googleID]?.appleAssetID, "apple-recovered")
        XCTAssertEqual(result.entriesByGoogleID[duplicate.googleID]?.appleAssetID, "apple-recovered")
    }

    func testGoogleAppleMirrorStaleAssetBecomesUserDeletionTombstone() {
        let removed = makeGoogleRecord(id: "removed", contentHash: String(repeating: "b", count: 64))
        let sameBytesNewID = makeGoogleRecord(id: "same-bytes", contentHash: removed.contentHash)
        let persisted = GooglePhotosMirrorAssetEntry(
            contentHash: removed.contentHash,
            appleAssetID: "missing-apple-asset",
            markerFilename: GoogleApplePhotosMirrorIdentity.markerFilename(
                contentHash: removed.contentHash,
                originalFilename: removed.filename
            ),
            state: .active,
            lastVerifiedAt: Date(timeIntervalSince1970: 100)
        )

        let result = GooglePhotosMirrorAssetReconciliationPolicy.reconcile(
            records: [removed, sameBytesNewID],
            persistedEntries: [removed.googleID: persisted],
            accessibleAssetIDs: [],
            recoveredAssetIDsByContentHash: [:],
            verifiedAt: Date(timeIntervalSince1970: 500)
        )

        XCTAssertEqual(result.entriesByGoogleID[removed.googleID]?.state, .removedByUser)
        XCTAssertEqual(result.entriesByGoogleID[sameBytesNewID.googleID]?.state, .removedByUser)
        XCTAssertTrue(result.recordsNeedingCreationByHash.isEmpty)
        XCTAssertEqual(result.alreadyMirroredCount, 0)
    }

    func testGoogleAppleMirrorStaleAssetIdentifierRecoversByCanvasMarker() {
        let record = makeGoogleRecord(id: "migrated", contentHash: String(repeating: "d", count: 64))
        let persisted = GooglePhotosMirrorAssetEntry(
            contentHash: record.contentHash,
            appleAssetID: "stale-apple-identifier",
            markerFilename: GoogleApplePhotosMirrorIdentity.markerFilename(
                contentHash: record.contentHash,
                originalFilename: record.filename
            ),
            state: .active,
            lastVerifiedAt: Date(timeIntervalSince1970: 100)
        )

        let result = GooglePhotosMirrorAssetReconciliationPolicy.reconcile(
            records: [record],
            persistedEntries: [record.googleID: persisted],
            accessibleAssetIDs: [],
            recoveredAssetIDsByContentHash: [record.contentHash: "recovered-apple-identifier"],
            verifiedAt: Date(timeIntervalSince1970: 500)
        )

        XCTAssertEqual(result.entriesByGoogleID[record.googleID]?.state, .active)
        XCTAssertEqual(result.entriesByGoogleID[record.googleID]?.appleAssetID, "recovered-apple-identifier")
        XCTAssertTrue(result.recordsNeedingCreationByHash.isEmpty)
        XCTAssertEqual(result.alreadyMirroredCount, 1)
    }

    func testGoogleAppleMirrorReusesStableIDAcrossAlbumsAndAddsMembershipOnly() {
        let record = makeGoogleRecord(id: "shared-google-id", contentHash: String(repeating: "f", count: 64))
        let result = GooglePhotosMirrorAssetReconciliationPolicy.reconcile(
            records: [record],
            persistedEntries: [:],
            accessibleAssetIDs: ["apple-shared"],
            recoveredAssetIDsByContentHash: [:],
            sharedAssetIDsByGoogleID: [record.googleID: "apple-shared"],
            assetIDsInTargetAlbum: [],
            assetIDsAlreadyInTargetAlbum: [],
            verifiedAt: .now
        )

        XCTAssertTrue(result.recordsNeedingCreationByHash.isEmpty)
        XCTAssertEqual(result.entriesByGoogleID[record.googleID]?.appleAssetID, "apple-shared")
        XCTAssertEqual(result.assetIDsToAddToTargetByGoogleID[record.googleID], "apple-shared")
        XCTAssertEqual(result.alreadyMirroredCount, 1)

        let alreadyMember = GooglePhotosMirrorAssetReconciliationPolicy.reconcile(
            records: [record],
            persistedEntries: [:],
            accessibleAssetIDs: ["apple-shared"],
            recoveredAssetIDsByContentHash: [:],
            sharedAssetIDsByGoogleID: [record.googleID: "apple-shared"],
            assetIDsInTargetAlbum: ["apple-shared"],
            assetIDsAlreadyInTargetAlbum: ["apple-shared"],
            verifiedAt: .now
        )
        XCTAssertTrue(alreadyMember.assetIDsToAddToTargetByGoogleID.isEmpty)
    }

    func testGoogleAppleMirrorReusesVerifiedContentHashAcrossAlbumsButHonorsUserRemoval() {
        let hash = String(repeating: "1", count: 64)
        let record = makeGoogleRecord(id: "second-google-id", contentHash: hash)
        let reused = GooglePhotosMirrorAssetReconciliationPolicy.reconcile(
            records: [record],
            persistedEntries: [:],
            accessibleAssetIDs: ["apple-shared"],
            recoveredAssetIDsByContentHash: [:],
            sharedAssetIDsByContentHash: [hash: "apple-shared"],
            verifiedAt: .now
        )
        XCTAssertEqual(reused.entriesByGoogleID[record.googleID]?.state, .active)
        XCTAssertTrue(reused.recordsNeedingCreationByHash.isEmpty)

        let prior = makeGoogleRecord(id: "first-google-id", contentHash: hash)
        let persisted = GooglePhotosMirrorAssetEntry(
            contentHash: hash,
            appleAssetID: "apple-shared",
            markerFilename: GoogleApplePhotosMirrorIdentity.markerFilename(contentHash: hash, originalFilename: prior.filename),
            state: .active,
            lastVerifiedAt: .now
        )
        let removed = GooglePhotosMirrorAssetReconciliationPolicy.reconcile(
            records: [prior, record],
            persistedEntries: [prior.googleID: persisted],
            accessibleAssetIDs: ["apple-shared"],
            recoveredAssetIDsByContentHash: [:],
            assetIDsInTargetAlbum: [],
            verifiedAt: .now
        )
        XCTAssertEqual(removed.entriesByGoogleID[prior.googleID]?.state, .removedByUser)
        XCTAssertEqual(removed.entriesByGoogleID[record.googleID]?.state, .removedByUser)
        XCTAssertTrue(removed.recordsNeedingCreationByHash.isEmpty)
        XCTAssertTrue(removed.assetIDsToAddToTargetByGoogleID.isEmpty)
    }

    func testGoogleAppleMirrorRejectsInvalidDownloadedPhotoBytesBeforeCommit() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-invalid-google-photo-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let lastKnownGood = Data("last-known-good".utf8)
        try lastKnownGood.write(to: url, options: .atomic)

        do {
            try await GooglePhotosService.validateDownloadedMedia(at: url, kind: .photo)
            XCTFail("Invalid photo bytes should not pass validation")
        } catch let error as GooglePhotosError {
            guard case .importFailed = error else {
                return XCTFail("Unexpected Google error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: url), lastKnownGood)
    }

    func testGoogleAppleMirrorIndexIsAtomicAndSurvivesCanvasLocalDeletion() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-mirror-index-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let indexURL = tempRoot.appendingPathComponent("mirror.json")
        let store = GooglePhotosMirrorIndexStore(url: indexURL)
        let asset = GooglePhotosMirrorAssetEntry(
            contentHash: String(repeating: "c", count: 64),
            appleAssetID: "apple-asset",
            markerFilename: "canvas-google-\(String(repeating: "c", count: 64)).jpg",
            state: .active,
            lastVerifiedAt: Date(timeIntervalSince1970: 100)
        )
        let mirrorAlbum = GooglePhotosMirrorAlbumEntry(
            title: "Google Home",
            appleAlbumID: "apple-album",
            albumRemovedByUser: false,
            pendingReason: nil,
            assetsByGoogleID: ["google-item": asset],
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let index = GooglePhotosMirrorIndex(albumsByCanvasID: ["google-album:home": mirrorAlbum])
        try store.persist(index)

        let localItem = makeGoogleRecord(id: "google-item")
        let localAlbum = GoogleAlbumRecord(
            id: "google-album:home",
            title: "Google Home",
            items: [localItem],
            updatedAt: .now,
            matchedAppleAlbumID: nil
        )
        XCTAssertNotNil(GoogleAlbumDeletionPlan.removing(albumID: localAlbum.id, from: [localAlbum]))

        let restored = GooglePhotosMirrorIndexStore(url: indexURL)
        XCTAssertNil(restored.loadError)
        XCTAssertEqual(restored.index, index)
        XCTAssertEqual(restored.index.albumsByCanvasID[localAlbum.id]?.appleAlbumID, "apple-album")
    }

    func testGoogleAppleMirrorIndexRefusesToOverwriteNewerSchema() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-mirror-newer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let indexURL = tempRoot.appendingPathComponent("mirror.json")
        let newer = GooglePhotosMirrorIndex(
            schemaVersion: GooglePhotosMirrorIndex.currentSchemaVersion + 1,
            albumsByCanvasID: [:]
        )
        let originalData = try JSONEncoder().encode(newer)
        try originalData.write(to: indexURL, options: .atomic)

        let store = GooglePhotosMirrorIndexStore(url: indexURL)
        XCTAssertNotNil(store.loadError)
        XCTAssertThrowsError(try store.persist(GooglePhotosMirrorIndex()))
        XCTAssertEqual(try Data(contentsOf: indexURL), originalData)
    }

    @MainActor
    func testGoogleAppleMirrorSerialQueuePreventsConcurrentIndexPlanningAcrossAlbums() async throws {
        let queue = GooglePhotosMirrorSerialQueue()
        var events: [String] = []
        let firstStarted = expectation(description: "first mirror started")
        let first = Task { @MainActor in
            try await queue.run {
                events.append("first-start")
                firstStarted.fulfill()
                try await Task.sleep(nanoseconds: 20_000_000)
                events.append("first-end")
            }
        }
        await fulfillment(of: [firstStarted], timeout: 1)
        let second = Task { @MainActor in
            try await queue.run {
                events.append("second-start")
                events.append("second-end")
            }
        }
        try await first.value
        try await second.value

        XCTAssertEqual(events, ["first-start", "first-end", "second-start", "second-end"])
    }

    func testGoogleAppleMirrorSummaryExplainsAllPhotosAndRetryWithoutPicker() {
        let success = GoogleApplePhotosMirrorSummary(
            albumTitle: "Google Home",
            addedCount: 2,
            alreadyMirroredCount: 3,
            failedCount: 0,
            preservedUserRemovalCount: 0,
            issue: nil,
            retryAvailable: false
        )
        XCTAssertTrue(success.message.contains("All Photos"))
        XCTAssertTrue(success.isComplete)

        let issue = GoogleApplePhotosMirrorSummary(
            albumTitle: "Google Home",
            addedCount: 0,
            alreadyMirroredCount: 0,
            failedCount: 5,
            preservedUserRemovalCount: 0,
            issue: "Full Photos access is required.",
            retryAvailable: true
        )
        XCTAssertTrue(issue.message.contains("kept every downloaded item locally"))
        XCTAssertTrue(issue.canRetry)
    }

    private func makeGoogleRecord(
        id: String,
        timestamp: TimeInterval = 100,
        relativePath: String? = nil,
        contentHash: String? = nil
    ) -> GoogleMediaRecord {
        GoogleMediaRecord(
            googleID: id,
            kind: .photo,
            creationDate: Date(timeIntervalSince1970: timestamp),
            filename: "\(id).jpg",
            pixelWidth: 1_200,
            pixelHeight: 800,
            relativePath: relativePath ?? "\(id)/\(id).jpg",
            contentHash: contentHash ?? "hash-\(id)"
        )
    }

    private func makeSnapshot(
        temperature: String,
        timestamp: Date = .now
    ) -> CanvasWeatherSnapshot {
        CanvasWeatherSnapshot(
            symbolName: "sun.max.fill",
            condition: "Clear",
            temperature: temperature,
            updatedAt: timestamp
        )
    }

    private func makeResult(
        temperature: String,
        timestamp: Date = .now
    ) -> CanvasWeatherProviderResult {
        CanvasWeatherProviderResult(
            snapshot: makeSnapshot(temperature: temperature, timestamp: timestamp),
            attributionURL: URL(string: "https://ambientweather.com")!,
            attributionMarkURL: nil
        )
    }

    @MainActor
    private func makeAmbientService(
        provider: TestWeatherProvider,
        interval: TimeInterval,
        defaults: UserDefaults? = nil
    ) -> CanvasWeatherService {
        let configuration = CanvasWeatherConfiguration(
            source: .ambientStation,
            ambientDeviceMAC: "00:10:FA:AA:BB:CC",
            ambientAPIKey: "test-api-key"
        )
        let resolvedDefaults = defaults ?? UserDefaults(suiteName: "CanvasTests.weather.service.\(UUID().uuidString)")!
        return CanvasWeatherService(
            weatherProvider: provider,
            airQualityProvider: TestAirQualityProvider(),
            autoRequestLocation: false,
            initialLocation: CLLocation(latitude: 40.44, longitude: -79.98),
            ambientPollingInterval: interval,
            defaults: resolvedDefaults,
            configurationProvider: { configuration }
        )
    }

    @MainActor
    private func waitFor(
        timeout: TimeInterval = 1,
        condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func makeTestDefaults() throws -> UserDefaults {
        let suiteName = "CanvasTests.weather.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw NSError(domain: "CanvasTests", code: 1)
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private struct TestAirQualityProvider: CanvasAirQualityProviding {
    func currentUSAirQualityIndex(for location: CLLocation) async throws -> Int? {
        nil
    }
}

private final class TestWeatherProvider: CanvasWeatherProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let results: [CanvasWeatherProviderResult]
    private let delayNanoseconds: UInt64
    private var nextResultIndex = 0
    private var calls = 0
    private var activeCalls = 0
    private var maximumActiveCalls = 0

    init(results: [CanvasWeatherProviderResult], delayNanoseconds: UInt64 = 0) {
        self.results = results
        self.delayNanoseconds = delayNanoseconds
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var maximumConcurrentCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumActiveCalls
    }

    func currentWeather(for location: CLLocation) async throws -> CanvasWeatherProviderResult {
        let result = beginCall()
        defer { endCall() }

        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        try Task.checkCancellation()
        return result
    }

    private func beginCall() -> CanvasWeatherProviderResult {
        lock.lock()
        defer { lock.unlock() }
        precondition(!results.isEmpty)
        calls += 1
        activeCalls += 1
        maximumActiveCalls = max(maximumActiveCalls, activeCalls)
        let index = min(nextResultIndex, max(0, results.count - 1))
        let result = results[index]
        nextResultIndex += 1
        return result
    }

    private func endCall() {
        lock.lock()
        activeCalls -= 1
        lock.unlock()
    }
}
