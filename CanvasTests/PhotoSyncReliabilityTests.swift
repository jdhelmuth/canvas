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
