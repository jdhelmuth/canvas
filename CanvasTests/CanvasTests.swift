import XCTest
import AVFoundation
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
    func testWeatherOverlayGracefullyReportsUnavailableWithoutProvider() {
        let service = CanvasWeatherService()
        service.update(showWeather: true)
        XCTAssertEqual(service.status, .entitlementMissing)
        XCTAssertFalse(service.isLoading)
        XCTAssertNil(service.snapshot)
        XCTAssertTrue(service.errorMessage?.contains("not included") == true)

        service.update(showWeather: false)
        XCTAssertEqual(service.status, .disabled)
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

    func testAutomaticFramingAvoidsExcessiveCropAndStaysCenteredAcrossAspectRatios() {
        let elevenInchLandscape = CGSize(width: 1194, height: 834)
        let elevenInchPortraitTile = CGSize(width: 593, height: 834)
        let elevenInchLandscapeTileAfterRotation = CGSize(width: 834, height: 593)
        let thirteenInchLandscape = CGSize(width: 1366, height: 1024)
        let cases: [(name: String, image: CGSize, viewport: CGSize, selectedLayout: LayoutStyle, expected: MediaFramingMode)] = [
            ("portrait on 11-inch landscape iPad", CGSize(width: 3024, height: 4032), elevenInchPortraitTile, .pairHorizontal, .fillZoom),
            ("landscape on rotated 11-inch iPad", CGSize(width: 4032, height: 3024), elevenInchLandscapeTileAfterRotation, .pairVertical, .fillZoom),
            ("landscape on 13-inch iPad", CGSize(width: 4032, height: 3024), thirteenInchLandscape, .single, .fillZoom),
            ("square", CGSize(width: 3000, height: 3000), elevenInchLandscape, .single, .fitWithBorder),
            ("panorama", CGSize(width: 8000, height: 1200), elevenInchLandscape, .single, .fitWithBorder),
            ("extreme portrait", CGSize(width: 1200, height: 8000), elevenInchPortraitTile, .pairHorizontal, .fitWithBorder)
        ]

        for value in cases {
            let plan = MediaFramingGeometry.plan(
                imageSize: value.image,
                viewportSize: value.viewport,
                preferredMode: .fillZoom,
                requestedLayout: .automatic,
                selectedLayout: value.selectedLayout
            )
            XCTAssertEqual(plan.mode, value.expected, value.name)
            XCTAssertEqual(plan.renderedFrame.midX, value.viewport.width / 2, accuracy: 0.0001, value.name)
            XCTAssertEqual(plan.renderedFrame.midY, value.viewport.height / 2, accuracy: 0.0001, value.name)
            if plan.mode == .fillZoom {
                XCTAssertLessThanOrEqual(plan.cropFraction, MediaFramingGeometry.automaticMaximumCropFraction, value.name)
                XCTAssertGreaterThanOrEqual(plan.renderedFrame.width, value.viewport.width - 0.0001, value.name)
                XCTAssertGreaterThanOrEqual(plan.renderedFrame.height, value.viewport.height - 0.0001, value.name)
            } else {
                XCTAssertLessThanOrEqual(plan.renderedFrame.width, value.viewport.width + 0.0001, value.name)
                XCTAssertLessThanOrEqual(plan.renderedFrame.height, value.viewport.height + 0.0001, value.name)
            }
        }
    }

    func testFitBlurredSelectionAlwaysPreservesWholeImage() {
        let plan = MediaFramingGeometry.plan(
            imageSize: CGSize(width: 4032, height: 3024),
            viewportSize: CGSize(width: 1366, height: 1024),
            preferredMode: .fillZoom,
            requestedLayout: .automatic,
            selectedLayout: .fitBlurred
        )
        XCTAssertEqual(plan.mode, .fitWithBorder)
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
            $0.overlays.textStrokeEnabled = true
            $0.overlays.textStrokeColor = .cyan
            $0.overlays.textStrokeWidth = 4.5
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
        XCTAssertEqual(restored.settings.overlays.textStrokeEnabled, true)
        XCTAssertEqual(restored.settings.overlays.textStrokeColor, .cyan)
        XCTAssertEqual(restored.settings.overlays.textStrokeWidth ?? 0, 4.5, accuracy: 0.001)
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
        defaults.set(try JSONEncoder().encode(legacy), forKey: "canvas.settings.v1")

        let migrated = SettingsStore(defaults: defaults)
        XCTAssertFalse(migrated.settings.fitMode)
        XCTAssertEqual(migrated.settings.backgroundHex, "#151513")
        let relaunched = SettingsStore(defaults: defaults)
        XCTAssertFalse(relaunched.settings.fitMode)
        XCTAssertEqual(relaunched.settings.backgroundHex, "#151513")
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
            skippedCount: 384,
            failureSummaries: [GoogleImportFailureSummary(category: .rateLimited, count: 300, example: "HTTP 429"), GoogleImportFailureSummary(category: .processing, count: 84, example: "HTTP 404")],
            canRetryFailedItems: true,
            updatedExistingAlbum: false
        )
        XCTAssertTrue(summary.isPartial)
        XCTAssertTrue(summary.message.contains("20 saved of 404 selected"))
        XCTAssertEqual(summary.failureSummaries.map(\.count).reduce(0, +), 384)
        XCTAssertTrue(summary.canRetryFailedItems)
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
}
