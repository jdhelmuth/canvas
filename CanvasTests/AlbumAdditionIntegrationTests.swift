import XCTest
import Photos
import UIKit
@testable import Canvas

@MainActor
final class AlbumAdditionIntegrationTests: XCTestCase {
    private func change(_ block: @escaping () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges(block) { success, error in
                if success { continuation.resume() }
                else { continuation.resume(throwing: error ?? NSError(domain: "Fixture", code: 1)) }
            }
        }
    }

    func testRunningSlideshowSurvivesAlbumReadGapAfterRealPhotoInsertion() async throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Disposable Photos fixture is simulator-only; never modify a physical library.")
#else
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            XCTFail("Grant Photos only to the dedicated Canvas simulator before running this integration test")
            return
        }
        let suite = "canvas-addition-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 48)).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
        }
        var createdIDs: [String] = []
        var albumID = ""
        try await change {
            let album = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: suite)
            albumID = album.placeholderForCreatedAssetCollection.localIdentifier
            let placeholders = (0..<3).compactMap { _ in PHAssetChangeRequest.creationRequestForAsset(from: image).placeholderForCreatedAsset }
            createdIDs = placeholders.map(\.localIdentifier)
            album.addAssets(placeholders as NSArray)
        }
        do {
            let album = try XCTUnwrap(PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject)
            let selected = AlbumReference(id: albumID, title: suite, subtype: album.assetCollectionSubtype.rawValue,
                estimatedCount: 3, isSmart: false, isShared: false)
            let reader = PhotoLibraryReadAccess()
            let library = PhotoLibraryService(defaults: defaults, readAccess: reader)
            library.track([selected])
            var settings = CanvasSettings()
            settings.selectedAlbums = [selected]
            settings.queueMode = .shuffle
            settings.photoDuration = 600
            let cycleStore = ShuffleCycleStore(defaults: defaults)
            let model = PlaybackViewModel(settings: settings,
                mediaItems: { library.mediaItems(for: $0.selectedAlbums, filters: $0.filters) },
                imageLoader: { _, _ in image }, cycleStore: cycleStore,
                libraryIsComplete: { library.selectionsAreResolved($0.selectedAlbums) })
            defer { model.stop(); library.setRecoveryActive(false) }
            await model.reload()
            XCTAssertEqual(model.queueCount, 3)
            let frame = try XCTUnwrap(model.displayedFrame?.id)
            let before = try XCTUnwrap(cycleStore.load())
            let liveCatalog = reader.catalog, liveCollection = reader.collection
            reader.catalog = { _ in [] }; reader.collection = { _ in nil }
            try await change {
                let added = PHAssetChangeRequest.creationRequestForAsset(from: image).placeholderForCreatedAsset!
                createdIDs.append(added.localIdentifier)
                PHAssetCollectionChangeRequest(for: album)?.addAssets([added] as NSArray)
            }
            // Reproduce a non-incremental catalog read racing the real asset
            // insertion. This is an injected PhotoKit read failure, not proof
            // that the simulator reproduces an iCloud outage.
            library.refreshAlbums(contentChanged: true)
            await model.refreshLibrary()
            XCTAssertGreaterThanOrEqual(model.queueCount, 3, "A transient lookup must not discard the known membership")
            XCTAssertEqual(model.displayedFrame?.id, frame, "The running frame must remain committed")
            XCTAssertEqual(cycleStore.load()?.displayedIDs, before.displayedIDs)
            reader.catalog = liveCatalog; reader.collection = liveCollection
            library.refreshAuthorization()
            await model.refreshLibrary()
            XCTAssertEqual(model.queueCount, 4)
            settings.selectedAlbums = library.reconciled([selected])
            await model.updateSettings(settings)
            XCTAssertEqual(model.displayedFrame?.id, frame, "Album count/identity metadata must not reload a frame")
            XCTAssertEqual(Set(cycleStore.load()?.orderedIDs ?? []).count, 4)
            XCTAssertEqual(cycleStore.load()?.displayedIDs, before.displayedIDs)
            XCTAssertNil(library.selectionWarning(for: [selected]))
            XCTAssertEqual(library.reconciled([selected]).map(\.id), [albumID])
            // A readable collection can still return a temporary empty member
            // fetch. Preserve membership and the committed frame in that case.
            let liveMembers = reader.members
            reader.members = { _ in PHAsset.fetchAssets(withLocalIdentifiers: [], options: nil) }
            library.refreshAuthorization()
            await model.refreshLibrary()
            XCTAssertEqual(model.queueCount, 4)
            XCTAssertEqual(model.displayedFrame?.id, frame)
            XCTAssertNil(library.playbackSelectionWarning(for: [selected]))
            XCTAssertNotNil(library.selectionWarning(for: [selected]))
            // A new service instance restores metadata without requiring a
            // successful album lookup during launch.
            reader.catalog = { _ in [] }; reader.collection = { _ in nil }
            let restarted = PhotoLibraryService(defaults: defaults, readAccess: reader)
            restarted.track([selected])
            XCTAssertEqual(restarted.assets(for: [selected], filters: settings.filters).count, 4)
            XCTAssertNil(restarted.playbackSelectionWarning(for: [selected]))
            XCTAssertFalse(restarted.selectionsAreResolved([selected]))
            restarted.setRecoveryActive(false)
            // Reconciliation may publish a repaired ID before track() receives
            // the new settings. Its verified member cache must work immediately.
            reader.members = liveMembers
            reader.collection = { id in id == "fixture-old-reference" ? album : liveCollection(id) }
            let legacy = AlbumReference(id: "fixture-old-reference", title: selected.title, subtype: selected.subtype, estimatedCount: selected.estimatedCount, isSmart: selected.isSmart, isShared: selected.isShared)
            let migrating = PhotoLibraryService(defaults: defaults, readAccess: reader)
            migrating.track([legacy])
            let repaired = migrating.reconciled([legacy])
            XCTAssertEqual(repaired.map(\.id), [albumID])
            reader.collection = { _ in nil }
            XCTAssertEqual(migrating.assets(for: repaired, filters: settings.filters).count, 4)
            migrating.setRecoveryActive(false)
            let aliasRestart = PhotoLibraryService(defaults: defaults, readAccess: reader)
            aliasRestart.track([legacy])
            XCTAssertEqual(aliasRestart.assets(for: [legacy], filters: settings.filters).count, 4)
            XCTAssertNil(aliasRestart.playbackSelectionWarning(for: [legacy]))
            aliasRestart.setRecoveryActive(false)
            reader.catalog = liveCatalog; reader.collection = liveCollection; reader.members = liveMembers
            library.refreshAuthorization()
            await model.refreshLibrary()
            XCTAssertEqual(model.displayedFrame?.id, frame)
            XCTAssertEqual(cycleStore.load()?.displayedIDs, before.displayedIDs)
            // Real incremental removal from this disposable album is distinct
            // from an empty read gap: membership must converge immediately.
            let addedAsset = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [createdIDs.last!], options: nil).firstObject)
            try await change { PHAssetCollectionChangeRequest(for: album)?.removeAssets([addedAsset] as NSArray) }
            for _ in 0..<100 {
                if library.assets(for: [selected], filters: settings.filters).count == 3 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(library.assets(for: [selected], filters: settings.filters).count, 3)
            await model.refreshLibrary()
            XCTAssertEqual(model.displayedFrame?.id, frame)
            // Simulate permission transitions only at the read boundary. Never
            // change the device's real authorization from a regression test.
            reader.catalog = { _ in [] }; reader.collection = { _ in nil }
            reader.authorization = { .denied }
            library.refreshAuthorization()
            XCTAssertTrue(library.assets(for: [selected], filters: settings.filters).isEmpty)
            XCTAssertNotNil(library.playbackSelectionWarning(for: [selected]))
            reader.authorization = { .limited }
            library.refreshAuthorization()
            XCTAssertTrue(library.assets(for: [selected], filters: settings.filters).isEmpty)
            reader.authorization = { .authorized }
            library.refreshAuthorization()
            XCTAssertTrue(library.assets(for: [selected], filters: settings.filters).isEmpty, "A new grant cannot revive the prior access scope")
            reader.catalog = liveCatalog; reader.collection = liveCollection
            library.refreshAuthorization()
            XCTAssertEqual(library.assets(for: [selected], filters: settings.filters).count, 3)
        } catch {
            cleanup(albumID: albumID, assetIDs: createdIDs)
            throw error
        }
        cleanup(albumID: albumID, assetIDs: createdIDs)
#endif
    }

    func testRestartRetriesSavedAssetsWithoutAlbumLookupOrManualReconnect() async throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Disposable Photos fixture is simulator-only")
#else
        XCTAssertEqual(PHPhotoLibrary.authorizationStatus(for: .readWrite), .authorized)
        let suite = "canvas-restoration-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var albumID = "", ids: [String] = []
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { c in
            UIColor.systemTeal.setFill(); c.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        try await change {
            let album = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: suite)
            albumID = album.placeholderForCreatedAssetCollection.localIdentifier
            let asset = PHAssetChangeRequest.creationRequestForAsset(from: image).placeholderForCreatedAsset!
            ids = [asset.localIdentifier]; album.addAssets([asset] as NSArray)
        }
        defer { cleanup(albumID: albumID, assetIDs: ids) }
        let selected = AlbumReference(id: albumID, title: suite, subtype: PHAssetCollectionSubtype.albumRegular.rawValue,
            estimatedCount: 1, isSmart: false, isShared: false, cloudIdentifier: "fixture-current-cloud")
        var oldPreset = selected; oldPreset.cloudIdentifier = "fixture-older-cloud"
        let writingReader = PhotoLibraryReadAccess()
        writingReader.cloudIdentity = { _ in nil }; writingReader.localIdentity = { _ in nil }
        let writer = PhotoLibraryService(defaults: defaults, readAccess: writingReader)
        writer.track([selected, oldPreset]); writer.setRecoveryActive(false)
        XCTAssertEqual(writer.assets(for: [selected], filters: CanvasFilters()).count, 1)
        XCTAssertEqual(writer.reconciled([selected, oldPreset]), [selected], "An old preset must not overwrite the current saved cloud identity")
        let reader = PhotoLibraryReadAccess()
        reader.cloudIdentity = { _ in nil }; reader.localIdentity = { _ in nil }
        let liveAssets = reader.assets
        reader.catalog = { _ in [] }; reader.collection = { _ in nil }
        reader.assets = { _ in PHAsset.fetchAssets(withLocalIdentifiers: [], options: nil) }
        let restarted = PhotoLibraryService(defaults: defaults, readAccess: reader)
        restarted.track([selected])
        defer { restarted.setRecoveryActive(false) }
        XCTAssertTrue(restarted.assets(for: [selected], filters: CanvasFilters()).isEmpty)
        let revision = restarted.libraryRevision
        // Photos becomes readable without emitting a notification. Do not
        // reconnect, retrack, or explicitly refresh the service.
        reader.assets = liveAssets
        for _ in 0..<100 {
            if restarted.assets(for: [selected], filters: CanvasFilters()).count == 1 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(restarted.assets(for: [selected], filters: CanvasFilters()).count, 1)
        XCTAssertGreaterThan(restarted.libraryRevision, revision, "Restored readable assets must wake the player")
        XCTAssertNil(restarted.playbackSelectionWarning(for: [selected]))
        XCTAssertNotNil(restarted.selectionWarning(for: [selected]), "Settings must still explain the unresolved album catalog")
        XCTAssertEqual(restarted.reconciled([selected]), [selected])
#endif
    }

    private func cleanup(albumID: String, assetIDs: [String]) {
        // PhotoKit deletion prompts require a UI runner. Preserve an exact
        // receipt for the simulator-only UI cleanup flow; never match names.
        let key = "canvas.simulator-fixture-cleanup"
        var receipts = UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []
        receipts.append(["albumID": albumID, "assetIDs": assetIDs])
        UserDefaults.standard.set(receipts, forKey: key)
    }
}
