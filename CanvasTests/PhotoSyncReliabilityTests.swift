import XCTest
import Photos
import UIKit
import ImageIO
@testable import Canvas

final class PhotoSyncReliabilityTests: XCTestCase {
    func testDeletedAlbumCannotRecoverFromItsAssetSharedIntoAnotherAlbum() {
        // Album B contains the same PHAsset created for A, including A's
        // resource filename. That is not evidence that collection B is A.
        XCTAssertEqual(GooglePhotosMirrorAlbumResolutionPolicy.resolve(
            persistedAlbumID: "apple-A",
            persistedAlbumRemoved: false,
            persistedAlbumAccessible: false,
            markerVerifiedAlbumIDs: ["apple-B"],
            exactEditableAlbumIDs: ["apple-B"]
        ), .failRemoved)
    }

    func testUntrackedCollectionWithCopiedMarkerIsNeverAdopted() {
        XCTAssertEqual(GooglePhotosMirrorAlbumResolutionPolicy.resolve(
            persistedAlbumID: nil,
            persistedAlbumRemoved: false,
            persistedAlbumAccessible: false,
            markerVerifiedAlbumIDs: ["user-album-containing-shared-asset"],
            exactEditableAlbumIDs: ["user-album-containing-shared-asset"]
        ), .failOwnershipUnverified)
    }

    func testExactCreationReceiptRecoversBeforeMainIndexCommitAndSurvivesRename() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = GooglePhotosMirrorCreationReceiptStore(directory: directory)
        try writer.record(canvasAlbumID: "canvas-A", appleAlbumID: "apple-created-A")
        // Simulate a restart after Photos committed but the main index did not.
        let restarted = GooglePhotosMirrorCreationReceiptStore(directory: directory)
        let recoveredID = try restarted.albumID(for: "canvas-A")
        XCTAssertEqual(recoveredID, "apple-created-A")
        XCTAssertNil(try restarted.albumID(for: "canvas-B"))
        XCTAssertEqual(GooglePhotosMirrorAlbumResolutionPolicy.resolve(
            persistedAlbumID: nil,
            persistedAlbumRemoved: false,
            persistedAlbumAccessible: false,
            markerVerifiedAlbumIDs: ["unrelated-album"],
            exactEditableAlbumIDs: [], // Person renamed the created album.
            creationReceiptAlbumID: recoveredID,
            creationReceiptAlbumAccessible: true
        ), .reuse("apple-created-A"))
        XCTAssertEqual(GooglePhotosMirrorAlbumResolutionPolicy.resolve(
            persistedAlbumID: nil,
            persistedAlbumRemoved: false,
            persistedAlbumAccessible: false,
            markerVerifiedAlbumIDs: [],
            exactEditableAlbumIDs: [],
            creationReceiptAlbumID: recoveredID,
            creationReceiptAlbumAccessible: false
        ), .failRemoved)
    }

    func testUnreadableCreationReceiptFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GooglePhotosMirrorCreationReceiptStore(directory: directory)
        try store.record(canvasAlbumID: "canvas-A", appleAlbumID: "apple-A")
        let file = directory.appendingPathComponent(GoogleApplePhotosMirrorIdentity.ownerToken(for: "canvas-A") + ".json")
        try Data("corrupted".utf8).write(to: file)
        XCTAssertThrowsError(try store.albumID(for: "canvas-A"))
    }

    func testConfirmedFailedCreationClearsOnlyItsOwnReceipt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GooglePhotosMirrorCreationReceiptStore(directory: directory)
        try store.record(canvasAlbumID: "canvas-A", appleAlbumID: "new-attempt")
        try store.discardFailedCreation(canvasAlbumID: "canvas-A", appleAlbumID: "older-attempt")
        XCTAssertEqual(try store.albumID(for: "canvas-A"), "new-attempt")
        try store.discardFailedCreation(canvasAlbumID: "canvas-A", appleAlbumID: "new-attempt")
        XCTAssertNil(try store.albumID(for: "canvas-A"))
    }

    func testLocalDecodeBoundsPixelsAndAppliesOrientationWithoutCropping() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 2400, height: 1600, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let original = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, original, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let decoded = try XCTUnwrap(LocalPhotoImageDecoder.cgImage(at: url, maximumSize: CGSize(width: 600, height: 600)))
        XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), 600)
        XCTAssertEqual(decoded.width, 400)
        XCTAssertEqual(decoded.height, 600)
        XCTAssertLessThan(decoded.bytesPerRow * decoded.height, original.bytesPerRow * original.height / 8)
    }

    func testAppleImageCacheChangesWhenPhotoIsEditedOrLibraryChanges() {
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        let size = CGSize(width: 1800, height: 1800)
        let original = AssetImageCacheKey.apple(identifier: "same-asset", modificationDate: date, libraryRevision: 1, size: size)
        let edited = AssetImageCacheKey.apple(identifier: "same-asset", modificationDate: date.addingTimeInterval(1), libraryRevision: 1, size: size)
        let refreshed = AssetImageCacheKey.apple(identifier: "same-asset", modificationDate: date, libraryRevision: 2, size: size)
        XCTAssertNotEqual(original, edited)
        XCTAssertNotEqual(original, refreshed)
        XCTAssertEqual(original, AssetImageCacheKey.apple(identifier: "same-asset", modificationDate: date, libraryRevision: 1, size: size))
    }

    @MainActor
    func testGoogleReimportDisplaysNewBytesForSameMediaID() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        func image(_ color: UIColor) -> UIImage {
            renderer.image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            }
        }
        func item(_ filename: String, hash: String) throws -> CanvasMediaItem {
            let url = directory.appendingPathComponent(filename)
            try XCTUnwrap(image(filename == "old.png" ? .red : .blue).pngData()).write(to: url)
            return CanvasMediaItem(id: "google:stable-id", source: .googlePhotos, kind: .photo, creationDate: nil,
                                   filename: filename, isFavorite: false, pixelWidth: 4, pixelHeight: 4,
                                   albumTitle: "Saved", appleAsset: nil, localURL: url, contentHash: hash)
        }
        let old = try item("old.png", hash: "old-hash")
        let refreshed = try item("new.png", hash: "new-hash")
        let loader = AssetImageLoader()
        let library = PhotoLibraryService()
        let size = CGSize(width: 700, height: 700)
        let first = await loader.image(for: old, service: library, size: size)
        let second = await loader.image(for: refreshed, service: library, size: size)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first?.pngData(), second?.pngData())
        let repeated = await loader.image(for: refreshed, service: library, size: size)
        XCTAssertTrue(second === repeated)
    }

    @MainActor
    func testHiddenSettingIsAppliedBeforePhotoKitFetch() {
        XCTAssertFalse(PhotoLibraryService.assetFetchOptions(includeHidden: false).includeHiddenAssets)
        XCTAssertTrue(PhotoLibraryService.assetFetchOptions(includeHidden: true).includeHiddenAssets)
    }
}

@MainActor
final class AlbumSelectionResolutionTests: XCTestCase {
    private func album(_ id: String, title: String = "Family", source: PhotoSource = .applePhotos, shared: Bool = false) -> AlbumReference {
        AlbumReference(id: id, title: title, subtype: 2, estimatedCount: 1_400, isSmart: false, isShared: shared, source: source)
    }

    func testSameNameDoesNotResolveMissingIdentifierOrChangeSelection() {
        let selected = [album("old"), album("google", source: .googlePhotos)]
        XCTAssertEqual(AlbumSelectionResolution.missing(selected, available: [album("new")]), [selected[0]])
        XCTAssertTrue(AlbumSelectionResolution.warning(selected: selected, available: [album("new")], authorization: .authorized)!.contains("Family"))
        XCTAssertEqual(selected[0].id, "old")
    }

    func testRenamedExistingAlbumResolvesByIdentity() {
        XCTAssertTrue(AlbumSelectionResolution.missing([album("same")], available: [album("same", title: "Renamed")]).isEmpty)
        XCTAssertNil(AlbumSelectionResolution.warning(selected: [album("same")], available: [album("same", title: "Renamed")], authorization: .authorized))
    }

    func testExplicitUniqueRepairPreservesUnrelatedSelectionAndOrder() throws {
        let selected = [album("favorites", title: "Favorites"), album("old"), album("google", source: .googlePhotos)]
        let repaired = try AlbumSelectionResolution.repairing(selected, mapping: ["old": "new"], available: [selected[0], album("new")], authorization: .authorized)
        XCTAssertEqual(repaired.map(\.id), ["favorites", "new", "google"])
        XCTAssertEqual(repaired[1].previousLocalIdentifiers, ["old"])
        XCTAssertEqual(repaired[0], selected[0])
        XCTAssertEqual(repaired[2], selected[2])
    }

    func testRepairRejectsAmbiguityWrongTypeAndWrongMappedID() {
        for available in [[album("new"), album("duplicate")], [album("new", shared: true)], [album("other")]] {
            XCTAssertThrowsError(try AlbumSelectionResolution.repairing([album("old")], mapping: ["old": "new"], available: available, authorization: .authorized))
        }
    }

    func testRepairCannotReplaceResolvedOrUnknownSelection() {
        XCTAssertThrowsError(try AlbumSelectionResolution.repairing([album("old")], mapping: ["old": "new"], available: [album("old"), album("new")], authorization: .authorized))
        XCTAssertThrowsError(try AlbumSelectionResolution.repairing([album("old")], mapping: ["unselected": "new"], available: [album("new")], authorization: .authorized))
    }

    func testLimitedOrDeniedAccessNeverAllowsRepair() {
        for authorization in [PhotoAuthorizationState.limited, .denied, .restricted, .notDetermined] {
            XCTAssertThrowsError(try AlbumSelectionResolution.repairing([album("old")], mapping: ["old": "new"], available: [album("new")], authorization: authorization))
            XCTAssertNotNil(AlbumSelectionResolution.warning(selected: [album("old")], available: [], authorization: authorization))
        }
        XCTAssertNil(AlbumSelectionResolution.warning(selected: [album("google", source: .googlePhotos)], available: [], authorization: .denied))
    }
}

@MainActor
final class AlbumRecoveryTests: XCTestCase {
    private func album(_ id: String, cloud: String? = nil, previous: [String] = []) -> AlbumReference {
        AlbumReference(id: id, title: "Family", subtype: 2, estimatedCount: 1_400,
                       isSmart: false, isShared: false, cloudIdentifier: cloud, previousLocalIdentifiers: previous)
    }

    private func resolve(_ selected: AlbumReference, known: [AlbumReference] = [], access: PhotoAuthorizationState = .authorized,
                         available: [AlbumReference], mappings: [String: String] = [:]) -> AlbumReference? {
        AlbumIdentityResolver.resolve(selected, known: known, authorization: access,
            lookup: { id in available.first { $0.id == id } },
            cloudID: { id in available.first { $0.id == id }?.cloudIdentifier },
            localID: { mappings[$0] })
    }

    func testLegacyAlbumGainsDurableIdentityAndSurvivesTwoIdentifierChanges() throws {
        let first = try XCTUnwrap(resolve(album("a"), available: [album("a", cloud: "cloud-family")]))
        let archived = try JSONDecoder().decode(AlbumReference.self, from: JSONEncoder().encode(first))
        let second = try XCTUnwrap(resolve(archived, available: [album("b")], mappings: ["cloud-family": "b"]))
        let third = try XCTUnwrap(resolve(second, available: [album("c")], mappings: ["cloud-family": "c"]))
        XCTAssertEqual(third.id, "c")
        XCTAssertEqual(third.cloudIdentifier, "cloud-family")
        XCTAssertEqual(third.previousLocalIdentifiers, ["a", "b"])
    }

    func testMissingLegacyOrFailedAmbiguousMappingNeverSubstitutesByName() {
        XCTAssertNil(resolve(album("old"), available: [album("same-name")]))
        XCTAssertNil(resolve(album("old", cloud: "cloud"), available: [album("one"), album("two")]))
        // The PhotoKit adapter exposes only successful unique mappings. Errors,
        // including multiple-local-identifiers, supply no local ID.
        XCTAssertNil(resolve(album("old", cloud: "cloud"), available: [album("new")], mappings: ["cloud": "missing"]))
    }

    func testMappingCannotChangeCollectionKindOrSource() {
        let wrongKind = AlbumReference(id: "new", title: "Family", subtype: 203, estimatedCount: 100, isSmart: true, isShared: false)
        XCTAssertNil(resolve(album("old", cloud: "cloud"), available: [wrongKind], mappings: ["cloud": "new"]))
        let google = AlbumReference(id: "new", title: "Family", subtype: 2, estimatedCount: 100, isSmart: false, isShared: false, source: .googlePhotos)
        XCTAssertNil(resolve(album("old", cloud: "cloud"), available: [google], mappings: ["cloud": "new"]))
    }

    func testPermissionRevocationClearsResolutionAndLimitedNeverCloudRecovers() {
        for access in [PhotoAuthorizationState.denied, .restricted, .notDetermined] {
            XCTAssertNil(resolve(album("same"), access: access, available: [album("same")]))
        }
        XCTAssertNil(resolve(album("old", cloud: "cloud"), access: .limited, available: [album("new")], mappings: ["cloud": "new"]))
        XCTAssertNotNil(resolve(album("same"), access: .limited, available: [album("same")]))
    }

    func testTransientFailureKeepsSelectionAndRecoveryWorksAfterRestart() throws {
        let selected = album("a", cloud: "cloud")
        XCTAssertNil(resolve(selected, available: []))
        let committed = AlbumSelectionResolution.committing(selectedIDs: ["a"], saved: [selected], available: [])
        XCTAssertEqual(committed, [selected])
        let restarted = try JSONDecoder().decode([AlbumReference].self, from: JSONEncoder().encode(committed))
        XCTAssertEqual(resolve(restarted[0], available: [album("b")], mappings: ["cloud": "b"])?.id, "b")
    }

    func testHistoryRecoversOldPresetAfterDeselectionAndRestart() throws {
        var history = AlbumIdentityHistory()
        history.record(album("a", cloud: "cloud"))
        let persisted = try JSONDecoder().decode(AlbumIdentityHistory.self, from: JSONEncoder().encode(history))
        // Old preset lacks cloud metadata; the local identity history supplies it.
        XCTAssertEqual(resolve(album("a"), known: persisted.records, available: [album("b")], mappings: ["cloud": "b"])?.id, "b")
        history.record(album("b", cloud: "cloud", previous: ["a"]))
        history.record(album("c", cloud: "cloud", previous: ["a", "b"]))
        XCTAssertEqual(history.records.count, 1)
        let oldPreset = album("b", cloud: "cloud", previous: ["a"])
        XCTAssertEqual(resolve(album("a"), known: history.records + [oldPreset], available: [album("c")])?.id, "c")
    }

    func testConflictingIdentityHistoryIsNotGuessed() {
        XCTAssertNil(resolve(album("a"), known: [album("b", previous: ["a"]), album("c", previous: ["a"])], available: [album("b"), album("c")]))
        XCTAssertNil(resolve(album("a", cloud: "first"), known: [album("a", cloud: "other")], available: [album("a")]))
    }

    func testPickerDonePreservesUnavailableAndExplicitRemovalStillWorks() {
        let saved = [album("missing"), album("visible")]
        XCTAssertEqual(AlbumSelectionResolution.committing(selectedIDs: ["missing", "visible"], saved: saved, available: [album("visible")]), saved)
        XCTAssertEqual(AlbumSelectionResolution.committing(selectedIDs: ["visible"], saved: saved, available: [album("visible")]).map(\.id), ["visible"])
        XCTAssertEqual(AlbumSelectionResolution.committing(selectedIDs: ["missing"], saved: saved, available: []).map(\.id), ["missing"])
    }

    func testPickerRefreshDoesNotUndoCheckboxEdits() {
        let old = [album("a"), album("b")]
        let new = [album("new-a", previous: ["a"]), album("b")]
        XCTAssertEqual(AlbumSelectionResolution.updatingDraft(["b", "extra"], from: old, to: new), ["b", "extra"])
        XCTAssertEqual(AlbumSelectionResolution.updatingDraft(["a", "extra"], from: old, to: new), ["new-a", "extra"])
    }

    func testIdentityRecoveryBacksUpSettingsOnceAndPreservesOtherFields() throws {
        let suite = "album-recovery-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.update { $0.selectedAlbums = [album("a")]; $0.photoDuration = 60; $0.filters.includeLivePhotos = false }
        let original = store.settings
        var updated = original
        updated.selectedAlbums = [album("b", cloud: "cloud", previous: ["a"])]
        store.saveAlbumRecovery(updated)
        store.saveAlbumRecovery(updated)
        let backup = try XCTUnwrap(defaults.data(forKey: "canvas.album-recovery.original-settings"))
        XCTAssertEqual(try JSONDecoder().decode(CanvasSettings.self, from: backup), original)
        let restarted = SettingsStore(defaults: defaults)
        XCTAssertEqual(restarted.settings, updated)
        XCTAssertEqual(restarted.settings.photoDuration, 60)
        XCTAssertFalse(restarted.settings.filters.includeLivePhotos)
    }

    func testWarningsDistinguishCheckingLimitedAndDeniedWithoutClaimingDeletion() {
        let selected = [album("a")]
        XCTAssertTrue(AlbumSelectionResolution.warning(selected: selected, available: [], authorization: .authorized, checking: true)!.contains("Checking"))
        XCTAssertTrue(AlbumSelectionResolution.warning(selected: selected, available: [], authorization: .limited)!.contains("Limited"))
        XCTAssertTrue(AlbumSelectionResolution.warning(selected: selected, available: [], authorization: .denied)!.contains("Settings"))
        XCTAssertNil(AlbumSelectionResolution.warning(selected: selected, available: selected, authorization: .authorized))
    }
}
