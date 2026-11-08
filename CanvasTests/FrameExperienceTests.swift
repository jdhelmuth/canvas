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
        overlays.showFilename = nil
        overlays.showCoordinates = nil
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
        // Legacy serialized settings omitted these newly introduced fields.
        original.overlays.showFilename = nil
        original.overlays.showCoordinates = nil
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

@MainActor
final class ReviewRegressionTests: XCTestCase {
    func testIdentitySnapshotRefreshesResolvedCloudMappingBeforeLocalIDChanges() {
        var cache = AlbumCloudIdentityCache()
        var cloud = "cloud-old"
        var lookups = 0
        func lookup(_ id: String) -> String? { lookups += 1; return cloud }
        cache.beginIdentitySnapshot()
        XCTAssertEqual(cache.identityForSnapshot("local", lookup: lookup), "cloud-old")
        cloud = "cloud-new"
        // Content-only updates retain the snapshot and need no PhotoKit lookup.
        XCTAssertEqual(cache.identityForSnapshot("local", lookup: lookup), "cloud-old")
        XCTAssertEqual(lookups, 1)
        cache.beginIdentitySnapshot()
        let refreshed = cache.identityForSnapshot("local", lookup: lookup)
        XCTAssertEqual(refreshed, "cloud-new")
        let selected = AlbumReference(id: "local", title: "Family", subtype: 2, estimatedCount: 1,
                                     isSmart: false, isShared: false, cloudIdentifier: refreshed)
        let replacement = AlbumReference(id: "replacement", title: "Renamed", subtype: 2,
                                        estimatedCount: 1, isSmart: false, isShared: false)
        cache.beginIdentitySnapshot()
        let recovered = AlbumIdentityResolver.resolve(selected, known: [selected], authorization: .authorized,
            lookup: { $0 == replacement.id ? replacement : nil },
            cloudID: { cache.identityForSnapshot($0) { _ in cloud } },
            localID: { $0 == "cloud-new" ? replacement.id : nil }, catalog: [], retained: nil)
        XCTAssertEqual(recovered?.id, replacement.id)
        cache.beginIdentitySnapshot()
        XCTAssertNil(cache.identityForSnapshot("replacement") { _ in nil }, "A failed refresh must not reuse stale identity")
    }

    func testFallbackIsDisplayedButNextLoadRetriesAndCachesHQ() async throws {
        for errorFallback in [false, true] {
            let loader = AssetImageLoader()
            let preview = UIImage()
            let hq = UIImage()
            let key: NSString = "cloud-photo"
            let request = PhotoImageRequest()
            var previewCount = 0
            request.installPreviewHandler { _ in previewCount += 1 }
            let first = await loader.image(forKey: key) {
                let image: UIImage = try await withCheckedThrowingContinuation {
                    request.install($0)
                    request.deliverPreview(preview)
                    if errorFallback {
                        request.finish(PhotoLibraryError.imageUnavailable, preservingPreview: true)
                    } else {
                        request.finishUsingPreviewIfNeeded()
                    }
                    request.finish(.success(hq)) // Late HQ must not change terminal quality.
                }
                return PhotoImageResult(image: image, isDegraded: request.isDegraded)
            }
            XCTAssertTrue(first === preview)
            XCTAssertEqual(previewCount, 1)
            XCTAssertNil(loader.cache.object(forKey: key))
            var retries = 0
            let second = await loader.image(forKey: key) {
                retries += 1
                return PhotoImageResult(image: hq, isDegraded: false)
            }
            XCTAssertTrue(second === hq)
            XCTAssertEqual(retries, 1)
            let cached = await loader.image(forKey: key) {
                XCTFail("HQ should be cached")
                return PhotoImageResult(image: preview, isDegraded: true)
            }
            XCTAssertTrue(cached === hq)
        }
    }

    func testCancelledLoaderDoesNotPublishOrCacheCompletedImage() async {
        let loader = AssetImageLoader()
        let key: NSString = "cancelled-photo"
        let task = Task { @MainActor in
            await loader.image(forKey: key) {
                withUnsafeCurrentTask { $0?.cancel() }
                return PhotoImageResult(image: UIImage(), isDegraded: false)
            }
        }
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertNil(loader.cache.object(forKey: key))
    }

    func testNewCaptionPreferencesAndPresetsRemainNontechnicalAfterRelaunch() {
        let suite = "Canvas.review-new.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.update {
            $0.overlays.showCaption = true
            $0.overlays.showLocation = true
            $0.presets = [CanvasPreset(name: "New", settings: $0)]
        }
        let restored = SettingsStore(defaults: defaults)
        for overlays in [restored.settings.overlays, restored.settings.presets[0].settings.overlays] {
            XCTAssertEqual(overlays.showFilename, false)
            XCTAssertEqual(overlays.showCoordinates, false)
        }
    }

    func testLegacyCaptionMigrationIsPersistedOnceIncludingDisabledPresets() throws {
        for enabled in [false, true] {
            let suite = "Canvas.review-legacy.\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            var legacy = CanvasSettings()
            legacy.overlays.showCaption = enabled
            legacy.overlays.showLocation = enabled
            legacy.overlays.showFilename = nil
            legacy.overlays.showCoordinates = nil
            legacy.presets = [CanvasPreset(name: "Legacy", settings: legacy)]
            defaults.set(try JSONEncoder().encode(legacy), forKey: "canvas.settings.v1")
            defaults.set(5, forKey: "canvas.settings.schema")
            let migrated = SettingsStore(defaults: defaults)
            for overlays in [migrated.settings.overlays, migrated.settings.presets[0].settings.overlays] {
                XCTAssertEqual(overlays.showFilename, enabled)
                XCTAssertEqual(overlays.showCoordinates, enabled)
            }
            migrated.update {
                $0.overlays.showCaption = true
                $0.overlays.showLocation = true
                $0.presets[0].settings.overlays.showCaption = true
                $0.presets[0].settings.overlays.showLocation = true
            }
            let restored = SettingsStore(defaults: defaults)
            for overlays in [restored.settings.overlays, restored.settings.presets[0].settings.overlays] {
                XCTAssertEqual(overlays.showFilename, enabled)
                XCTAssertEqual(overlays.showCoordinates, enabled)
            }
        }
    }
}
