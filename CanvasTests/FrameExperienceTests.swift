import XCTest
import UIKit
@testable import Canvas

final class FrameExperienceTests: XCTestCase {
    func testResumeDefaultsOnForIPadAndOffForIPhone() {
        XCTAssertTrue(FrameResumePolicy.defaultEnabled(for: .pad))
        XCTAssertFalse(FrameResumePolicy.defaultEnabled(for: .phone))
        XCTAssertTrue(FrameResumePolicy.isEnabled(nil, device: .pad))
        XCTAssertFalse(FrameResumePolicy.isEnabled(nil, device: .phone))
        XCTAssertFalse(FrameResumePolicy.isEnabled(false, device: .pad))
        XCTAssertTrue(FrameResumePolicy.isEnabled(true, device: .phone))
    }

    func testResumeRequiresSavedPlayingIntentAndPlayableMedia() {
        XCTAssertTrue(
            FrameResumePolicy.shouldPresentOnOpen(
                preference: true,
                device: .phone,
                frameWasPlaying: true,
                playable: .ready,
                isPlayerPresented: false,
                isStarting: false
            )
        )
        XCTAssertFalse(
            FrameResumePolicy.shouldPresentOnOpen(
                preference: true,
                device: .pad,
                frameWasPlaying: false,
                playable: .ready,
                isPlayerPresented: false,
                isStarting: false
            )
        )
        XCTAssertFalse(
            FrameResumePolicy.shouldPresentOnOpen(
                preference: true,
                device: .pad,
                frameWasPlaying: true,
                playable: .needsSelection,
                isPlayerPresented: false,
                isStarting: false
            )
        )
        XCTAssertFalse(
            FrameResumePolicy.shouldPresentOnOpen(
                preference: true,
                device: .pad,
                frameWasPlaying: true,
                playable: .ready,
                isPlayerPresented: true,
                isStarting: false
            )
        )
    }

    func testNewFiltersOmitScreenshotsAndVideos() {
        let filters = CanvasFilters()
        XCTAssertFalse(filters.includeScreenshots)
        XCTAssertFalse(filters.includeVideos)
        let screenshot = MediaDescriptor(
            id: "shot", kind: .photo, creationDate: Date(), modificationDate: nil,
            filename: "IMG.png", isFavorite: false, pixelWidth: 10, pixelHeight: 10,
            albumTitles: [], isScreenshot: true
        )
        let video = MediaDescriptor(
            id: "clip", kind: .video, creationDate: Date(), modificationDate: nil,
            filename: "IMG.mov", isFavorite: false, pixelWidth: 10, pixelHeight: 10,
            albumTitles: []
        )
        XCTAssertFalse(filters.accepts(screenshot))
        XCTAssertFalse(filters.accepts(video))
    }

    func testLegacyCaptionAndLocationKeepTechnicalOverlays() {
        var overlays = OverlaySettings()
        overlays.showCaption = true
        overlays.showLocation = true
        XCTAssertTrue(overlays.migrateLegacyCaptionAndLocation())
        XCTAssertEqual(overlays.showFilename, true)
        XCTAssertEqual(overlays.showCoordinates, true)
        XCTAssertFalse(overlays.migrateLegacyCaptionAndLocation())
    }

    func testNewCaptionOverlayOmitsFilenameAndCoordinates() {
        XCTAssertNil(
            PhotoOverlayTextPolicy.caption(
                photoCaption: nil,
                filename: "IMG_1000.HEIC",
                showPhotoCaption: true,
                showFilename: false
            )
        )
        XCTAssertEqual(
            PhotoOverlayTextPolicy.caption(
                photoCaption: "Lake morning",
                filename: "IMG_1000.HEIC",
                showPhotoCaption: true,
                showFilename: false
            ),
            "Lake morning"
        )
        XCTAssertNil(
            PhotoOverlayTextPolicy.location(
                placeName: nil,
                coordinateText: "40.447, -79.982",
                showPlace: true,
                showCoordinates: false
            )
        )
        XCTAssertEqual(
            PhotoOverlayTextPolicy.location(
                placeName: "Murrysville",
                coordinateText: "40.447, -79.982",
                showPlace: true,
                showCoordinates: false
            ),
            "Murrysville"
        )
    }

    func testEmbeddedMetadataParserReadsIPTCWithoutGeocoding() {
        let properties: [String: Any] = [
            "{IPTC}": [
                "Caption/Abstract": "Family dinner",
                "City": "Pittsburgh",
                "Province/State": "Pennsylvania"
            ]
        ]
        XCTAssertEqual(PhotoMetadataParser.caption(from: properties), "Family dinner")
        XCTAssertEqual(PhotoMetadataParser.placeName(from: properties), "Pittsburgh, Pennsylvania")
    }

    func testShelfFrameUsesExistingFeaturesWithoutClearingAlbums() {
        var settings = CanvasSettings()
        settings.selectedAlbums = [
            AlbumReference(id: "a", title: "Recents", subtype: 0, estimatedCount: 4, isSmart: true, isShared: false)
        ]
        settings.keepAwake = false
        let applied = ShelfFrameSetup.applying(to: settings)
        XCTAssertEqual(applied.selectedAlbums, settings.selectedAlbums)
        XCTAssertTrue(applied.keepAwake)
        XCTAssertTrue(applied.overlays.showTime)
        XCTAssertTrue(applied.overlays.showWeather)
        XCTAssertTrue(applied.overlays.showDate)
        XCTAssertFalse(settings.overlays.showTime)
    }

    func testFavoriteRequiresFullAccessAndExcludeNeverImpliesDeletion() {
        XCTAssertEqual(
            SlideshowItemActionPolicy.favoriteAvailability(source: .applePhotos, authorization: .limited),
            .needsFullAccess
        )
        XCTAssertEqual(
            SlideshowItemActionPolicy.favoriteAvailability(source: .applePhotos, authorization: .authorized),
            .allowed
        )
        XCTAssertEqual(
            SlideshowItemActionPolicy.favoriteAvailability(source: .googlePhotos, authorization: .authorized),
            .notApplePhoto
        )
        XCTAssertEqual(SlideshowItemActionPolicy.excluding("a", from: ["b"]), ["a", "b"])
    }

    func testGoogleStorageCountsRegularFilesOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 2048).write(to: root.appendingPathComponent("nested/photo.jpg"))
        XCTAssertEqual(GooglePhotosStorageUsage.byteCount(at: root), 2048)
        XCTAssertFalse(GooglePhotosStorageUsage.formattedByteCount(2048).isEmpty)
    }

    func testPhotoProgressIgnoresStaleIdentitiesAndReplacesPreview() {
        XCTAssertTrue(PhotoImageProgressPolicy.shouldPublishPreview(isDegraded: true, hasFinalImage: false))
        XCTAssertFalse(PhotoImageProgressPolicy.shouldPublishPreview(isDegraded: true, hasFinalImage: true))
        XCTAssertTrue(PhotoImageProgressPolicy.shouldReplacePreview(currentIsDegraded: true, incomingIsDegraded: false, sameIdentity: true))
        XCTAssertFalse(PhotoImageProgressPolicy.shouldReplacePreview(currentIsDegraded: true, incomingIsDegraded: false, sameIdentity: false))
        XCTAssertTrue(PhotoImageProgressPolicy.shouldIgnoreStale(expectedID: "a", incomingID: "b", generation: 1, incomingGeneration: 1))
        XCTAssertTrue(PhotoImageProgressPolicy.shouldIgnoreStale(expectedID: "a", incomingID: "a", generation: 1, incomingGeneration: 2))
        XCTAssertFalse(PhotoImageProgressPolicy.shouldIgnoreStale(expectedID: "a", incomingID: "a", generation: 3, incomingGeneration: 3))
    }
}

@MainActor
final class FrameExperiencePersistenceTests: XCTestCase {
    func testLegacySettingsKeepScreenshotVideoChoicesAndMigrateCaption() throws {
        let suite = "CanvasTests.experience.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var original = CanvasSettings()
        original.filters.includeScreenshots = true
        original.filters.includeVideos = true
        original.overlays.showCaption = true
        original.overlays.showLocation = true
        original.resumeFrameOnOpen = nil
        defaults.set(try JSONEncoder().encode(original), forKey: "canvas.settings.v1")
        defaults.set(5, forKey: "canvas.settings.schema")
        let store = SettingsStore(defaults: defaults)
        XCTAssertTrue(store.settings.filters.includeScreenshots)
        XCTAssertTrue(store.settings.filters.includeVideos)
        XCTAssertEqual(store.settings.overlays.showFilename, true)
        XCTAssertEqual(store.settings.overlays.showCoordinates, true)
        XCTAssertNil(store.settings.resumeFrameOnOpen)
    }

    func testFramePlayingIntentIsIndependentOfSettingsPresets() {
        let suite = "CanvasTests.playing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.frameWasPlaying = true
        XCTAssertTrue(defaults.bool(forKey: "canvas.frame-was-playing"))
        store.update { $0.photoDuration = 12 }
        XCTAssertTrue(store.frameWasPlaying)
        let restored = SettingsStore(defaults: defaults)
        XCTAssertTrue(restored.frameWasPlaying)
        XCTAssertEqual(restored.settings.photoDuration, 12)
    }
}

final class PhotoImagePreviewRequestTests: XCTestCase {
    func testPreviewIsDeliveredAndFinalImageWins() async throws {
        let request = PhotoImageRequest()
        let preview = UIImage()
        let final = UIImage()
        var previews: [UIImage] = []
        request.installPreviewHandler { previews.append($0) }
        let image: UIImage = try await withCheckedThrowingContinuation {
            request.install($0)
            request.deliverPreview(preview)
            request.finish(.success(final))
            request.deliverPreview(UIImage())
            request.finish(.success(UIImage()))
        }
        XCTAssertTrue(image === final)
        XCTAssertEqual(previews.count, 1)
        XCTAssertTrue(previews[0] === preview)
    }

    func testTimeoutKeepsPreviewInsteadOfFailing() async throws {
        let request = PhotoImageRequest()
        let preview = UIImage()
        let image: UIImage = try await withCheckedThrowingContinuation {
            request.install($0)
            request.deliverPreview(preview)
            request.finishUsingPreviewIfNeeded()
        }
        XCTAssertTrue(image === preview)
    }

    func testCancelledRequestIgnoresLateHQ() async {
        let request = PhotoImageRequest()
        request.finish(.failure(CancellationError()))
        request.deliverPreview(UIImage())
        do {
            let _: UIImage = try await withCheckedThrowingContinuation { request.install($0) }
            XCTFail("Cancelled request must throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}

@MainActor
final class PlaybackPreviewReplacementTests: XCTestCase {
    private func item(_ id: String) -> CanvasMediaItem {
        CanvasMediaItem(
            id: id, source: .applePhotos, kind: .photo, creationDate: nil,
            filename: "\(id).jpg", isFavorite: false, pixelWidth: 100, pixelHeight: 100,
            albumTitle: "Test", appleAsset: nil, localURL: nil, contentHash: nil
        )
    }

    func testHQCallbackReplacesPreviewForSamePhoto() async {
        let preview = UIImage()
        let hq = UIImage()
        let items = [item("cloud")]
        let model = PlaybackViewModel(
            settings: {
                var value = CanvasSettings()
                value.layout = .single
                value.photoDuration = 100
                return value
            }(),
            mediaItems: { _ in items },
            previewImageLoader: { _, _, onPreview in
                onPreview(preview)
                return hq
            }
        )
        defer { model.stop() }
        await model.reload()
        XCTAssertTrue(model.displayedFrame?.image === hq)
        XCTAssertEqual(model.currentAsset?.id, "cloud")
    }

    func testStaleHQForPreviousPhotoIsIgnored() async {
        let firstHQ = UIImage()
        let second = UIImage()
        let items = [item("one"), item("two")]
        var continueFirst: CheckedContinuation<UIImage?, Never>?
        let model = PlaybackViewModel(
            settings: {
                var value = CanvasSettings()
                value.queueMode = .albumOrder
                value.layout = .single
                value.photoDuration = 100
                return value
            }(),
            mediaItems: { _ in items },
            previewImageLoader: { item, _, onPreview in
                if item.id == "one" {
                    onPreview(UIImage())
                    return await withCheckedContinuation { continueFirst = $0 }
                }
                return second
            }
        )
        defer { model.stop() }
        let load = Task { await model.reload() }
        for _ in 0..<200 where continueFirst == nil {
            await Task.yield()
        }
        XCTAssertNotNil(continueFirst)
        for _ in 0..<200 where model.displayedFrame == nil {
            await Task.yield()
        }
        XCTAssertEqual(model.currentAsset?.id, "one")
        XCTAssertTrue(model.next())
        continueFirst?.resume(returning: firstHQ)
        await load.value
        for _ in 0..<200 where model.currentAsset?.id != "two" {
            await Task.yield()
        }
        XCTAssertEqual(model.currentAsset?.id, "two")
        XCTAssertTrue(model.displayedFrame?.image === second)
    }
}
