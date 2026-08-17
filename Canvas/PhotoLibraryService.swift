import Foundation
import Photos
import UIKit
import AVFoundation

enum PhotoAuthorizationState: Equatable {
    case notDetermined, limited, authorized, denied, restricted
    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .limited: self = .limited
        case .authorized: self = .authorized
        case .denied: self = .denied
        case .restricted: self = .restricted
        @unknown default: self = .denied
        }
    }
    var canRead: Bool { self == .authorized || self == .limited }
    /// Full read/write access is required to create, re-fetch, and verify a
    /// dedicated user album without risking duplicate or misplaced copies.
    var canManageGoogleMirrorAlbums: Bool { self == .authorized }
    var explanation: String? {
        switch self {
        case .limited: "Photos access is limited. Canvas can browse the items you selected in Photos, but Full Access is required to create or reuse the dedicated Apple Photos album for a Google import."
        case .denied: "Photos access is off. Enable it in Settings to choose albums or mirror a saved Google import into its dedicated Apple Photos album."
        case .restricted: "Photos access is restricted by this device or account."
        default: nil
        }
    }
}

struct GoogleApplePhotosMirrorResult: Equatable {
    let albumID: String
    let assetIDsByGoogleID: [String: String]
    let tombstoneGoogleIDs: Set<String>
    let addedCount: Int
    let alreadyMirroredCount: Int
    let failedGoogleIDs: Set<String>
}

enum GooglePhotosMirrorAssetState: String, Codable, Equatable {
    case active
    case removedByUser
}

struct GooglePhotosMirrorAssetEntry: Codable, Equatable {
    var contentHash: String
    var appleAssetID: String
    var markerFilename: String
    var state: GooglePhotosMirrorAssetState
    var lastVerifiedAt: Date
}

struct GooglePhotosMirrorAlbumEntry: Codable, Equatable {
    var title: String
    var appleAlbumID: String
    var albumRemovedByUser: Bool
    var pendingReason: String?
    var assetsByGoogleID: [String: GooglePhotosMirrorAssetEntry]
    var updatedAt: Date
}

struct GooglePhotosMirrorIndex: Codable, Equatable {
    static let currentSchemaVersion = 1
    var schemaVersion = currentSchemaVersion
    var albumsByCanvasID: [String: GooglePhotosMirrorAlbumEntry] = [:]
}

enum GooglePhotosMirrorIndexError: LocalizedError {
    case unsupportedSchema(Int)
    case couldNotPersist

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            "Canvas found a newer Apple Photos mirror index (schema \(version)) and stopped rather than overwrite it."
        case .couldNotPersist:
            "Canvas could not durably save the Apple Photos mirror mapping. The photos already added to Apple Photos were left untouched."
        }
    }
}

enum GooglePhotosMirrorAuthorizationPolicy {
    static func permitsNamedAlbumMirroring(_ status: PHAuthorizationStatus) -> Bool {
        status == .authorized
    }
}

enum GooglePhotosMirrorRetryPolicy {
    static func shouldOfferRetry(
        entry: GooglePhotosMirrorAlbumEntry?,
        expectedItemCount: Int,
        indexLoadFailed: Bool
    ) -> Bool {
        guard !indexLoadFailed else { return false }
        guard let entry else { return expectedItemCount > 0 }
        guard !entry.albumRemovedByUser else { return false }
        if entry.pendingReason != nil { return true }
        return entry.assetsByGoogleID.count < expectedItemCount
    }
}

enum GooglePhotosMirrorAlbumResolution: Equatable {
    case reuse(String)
    case create
    case failRemoved
    case failAmbiguous
    case failOwnershipUnverified
}

enum GooglePhotosMirrorAlbumResolutionPolicy {
    static func resolve(
        persistedAlbumID: String?,
        persistedAlbumRemoved: Bool,
        persistedAlbumAccessible: Bool,
        markerVerifiedAlbumIDs: [String],
        exactEditableAlbumIDs: [String]
    ) -> GooglePhotosMirrorAlbumResolution {
        if persistedAlbumRemoved { return .failRemoved }
        if let persistedAlbumID, !persistedAlbumID.isEmpty {
            if persistedAlbumAccessible { return .reuse(persistedAlbumID) }
            if markerVerifiedAlbumIDs.count > 1 { return .failAmbiguous }
            if let recovered = markerVerifiedAlbumIDs.first { return .reuse(recovered) }
            return .failRemoved
        }
        if markerVerifiedAlbumIDs.count > 1 { return .failAmbiguous }
        if let verified = markerVerifiedAlbumIDs.first { return .reuse(verified) }
        if !exactEditableAlbumIDs.isEmpty { return .failOwnershipUnverified }
        return .create
    }
}

struct GooglePhotosMirrorAssetReconciliation {
    let entriesByGoogleID: [String: GooglePhotosMirrorAssetEntry]
    let recordsNeedingCreationByHash: [String: [GoogleMediaRecord]]
    /// Existing PHAssets found in another Canvas-owned mirror can be added to
    /// the current album. The Google ID mapping is retained so a failed
    /// membership write can remain pending without creating a duplicate asset.
    let assetIDsToAddToTargetByGoogleID: [String: String]
    let alreadyMirroredCount: Int
}

enum GooglePhotosMirrorAssetReconciliationPolicy {
    static func reconcile(
        records: [GoogleMediaRecord],
        persistedEntries: [String: GooglePhotosMirrorAssetEntry],
        accessibleAssetIDs: Set<String>,
        recoveredAssetIDsByContentHash: [String: String],
        sharedAssetIDsByGoogleID: [String: String] = [:],
        sharedAssetIDsByContentHash: [String: String] = [:],
        assetIDsInTargetAlbum: Set<String>? = nil,
        assetIDsAlreadyInTargetAlbum: Set<String> = [],
        verifiedAt: Date
    ) -> GooglePhotosMirrorAssetReconciliation {
        let recordIDs = Set(records.map(\.googleID))
        var entries = persistedEntries
        let recoveredAssetIDs = Set(recoveredAssetIDsByContentHash.values)
        let verifiedAssetIDs = accessibleAssetIDs.union(recoveredAssetIDs)
        for googleID in Array(entries.keys) where recordIDs.contains(googleID) {
            guard var entry = entries[googleID], entry.state == .active else { continue }
            if entry.appleAssetID.isEmpty || !accessibleAssetIDs.contains(entry.appleAssetID) {
                let hash = GoogleApplePhotosMirrorIdentity.canonicalContentHash(entry.contentHash)
                if let recoveredID = recoveredAssetIDsByContentHash[hash] {
                    entry.appleAssetID = recoveredID
                } else {
                    entry.state = .removedByUser
                }
            } else if let assetIDsInTargetAlbum,
                      !assetIDsInTargetAlbum.contains(entry.appleAssetID) {
                // The PHAsset still exists in All Photos, but the person
                // removed it from this Canvas-managed album. Preserve that
                // intent so a new Google ID with the same bytes cannot add it
                // back through cross-album deduplication.
                entry.state = .removedByUser
            }
            entry.lastVerifiedAt = verifiedAt
            entries[googleID] = entry
        }

        var assetIDByHash = recoveredAssetIDsByContentHash
        for entry in entries.values
        where entry.state == .active && verifiedAssetIDs.contains(entry.appleAssetID) {
            assetIDByHash[GoogleApplePhotosMirrorIdentity.canonicalContentHash(entry.contentHash)] = entry.appleAssetID
        }
        let tombstonedHashes = Set(entries.values.compactMap {
            $0.state == .removedByUser ? GoogleApplePhotosMirrorIdentity.canonicalContentHash($0.contentHash) : nil
        })

        var alreadyMirroredCount = 0
        var needsCreation: [String: [GoogleMediaRecord]] = [:]
        var assetIDsToAddToTargetByGoogleID: [String: String] = [:]
        for record in records {
            if let persisted = entries[record.googleID] {
                if persisted.state == .active { alreadyMirroredCount += 1 }
                continue
            }
            let hash = GoogleApplePhotosMirrorIdentity.canonicalContentHash(record.contentHash)
            let marker = GoogleApplePhotosMirrorIdentity.markerFilename(
                contentHash: hash,
                originalFilename: record.filename
            )
            if tombstonedHashes.contains(hash) {
                entries[record.googleID] = GooglePhotosMirrorAssetEntry(
                    contentHash: hash,
                    appleAssetID: "",
                    markerFilename: marker,
                    state: .removedByUser,
                    lastVerifiedAt: verifiedAt
                )
            } else if let assetID = sharedAssetIDsByGoogleID[record.googleID]
                        ?? assetIDByHash[hash]
                        ?? sharedAssetIDsByContentHash[hash] {
                entries[record.googleID] = GooglePhotosMirrorAssetEntry(
                    contentHash: hash,
                    appleAssetID: assetID,
                    markerFilename: marker,
                    state: .active,
                    lastVerifiedAt: verifiedAt
                )
                alreadyMirroredCount += 1
                if !assetIDsAlreadyInTargetAlbum.contains(assetID) {
                    assetIDsToAddToTargetByGoogleID[record.googleID] = assetID
                }
            } else {
                needsCreation[hash, default: []].append(record)
            }
        }
        return GooglePhotosMirrorAssetReconciliation(
            entriesByGoogleID: entries,
            recordsNeedingCreationByHash: needsCreation,
            assetIDsToAddToTargetByGoogleID: assetIDsToAddToTargetByGoogleID,
            alreadyMirroredCount: alreadyMirroredCount
        )
    }
}

final class GooglePhotosMirrorIndexStore {
    private let fileManager: FileManager
    let url: URL
    private(set) var index: GooglePhotosMirrorIndex
    private(set) var loadError: Error?

    init(fileManager: FileManager = .default, url: URL? = nil) {
        self.fileManager = fileManager
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Canvas", isDirectory: true)
        self.url = url ?? applicationSupport.appendingPathComponent("google-photos-mirror-index.json")
        do {
            let data = try Data(contentsOf: self.url)
            let decoded = try JSONDecoder().decode(GooglePhotosMirrorIndex.self, from: data)
            guard decoded.schemaVersion <= GooglePhotosMirrorIndex.currentSchemaVersion else {
                throw GooglePhotosMirrorIndexError.unsupportedSchema(decoded.schemaVersion)
            }
            index = decoded
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            index = GooglePhotosMirrorIndex()
        } catch {
            index = GooglePhotosMirrorIndex()
            loadError = error
        }
    }

    func persist(_ updated: GooglePhotosMirrorIndex) throws {
        if let loadError { throw loadError }
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(updated)
            try data.write(to: url, options: .atomic)
            index = updated
        } catch {
            throw GooglePhotosMirrorIndexError.couldNotPersist
        }
    }
}

enum GoogleApplePhotosMirrorError: LocalizedError {
    case fullAccessRequired
    case managedAlbumRemoved
    case ambiguousRecovery
    case ownershipUnverified
    case albumCreationFailed
    case photoLibraryChangeFailed(String)

    var errorDescription: String? {
        switch self {
        case .fullAccessRequired:
            "Full Photos access is required to safely create and reuse a named Apple Photos album. In Settings, open Canvas → Photos and choose Full Access, then retry the Apple Photos album."
        case .managedAlbumRemoved:
            "The Apple Photos album previously created by Canvas was removed. Canvas preserved that deletion and did not create another album automatically."
        case .ambiguousRecovery:
            "Canvas found more than one editable Apple Photos album with the saved name and stopped rather than choosing a destination incorrectly. Rename or remove the extra album, then retry."
        case .ownershipUnverified:
            "Canvas found an Apple Photos album with the saved name, but it was not created by Canvas. Canvas did not adopt it or add anything to it; rename that album or choose a different Canvas album name, then retry."
        case .albumCreationFailed:
            "Apple Photos did not create the dedicated album. No existing user album was changed."
        case .photoLibraryChangeFailed(let message):
            "Apple Photos could not save this batch: \(message)"
        }
    }
}

private struct GoogleApplePhotosMirrorCandidate {
    let record: GoogleMediaRecord
    let sourceURL: URL
    let markerFilename: String
}

private final class PhotoKitPlaceholderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var albumIdentifier: String?
    private var assetIdentifiers: [String: String] = [:]

    func setAlbumIdentifier(_ identifier: String) {
        lock.lock()
        albumIdentifier = identifier
        lock.unlock()
    }

    func setAssetIdentifier(_ identifier: String, for googleID: String) {
        lock.lock()
        assetIdentifiers[googleID] = identifier
        lock.unlock()
    }

    var snapshot: (albumID: String?, assets: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        return (albumIdentifier, assetIdentifiers)
    }
}

/// PhotoKit must return an uncropped source for every Canvas media surface.
/// The foreground view is the single owner of the user's fit/fill choice; if
/// the request also uses aspect fill, Live Photos and stills can be cropped
/// once by PhotoKit and then cropped again by the renderer.
enum PhotoKitSourceFramingPolicy {
    nonisolated static let contentMode: PHImageContentMode = .aspectFit
}

@MainActor
final class PhotoLibraryService: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    /// Canvas applies its own fit/fill decision after the image is loaded.
    /// Requesting aspectFill here would crop the source photo to the square
    /// thumbnail bounds before LayoutCanvas can calculate the correct crop.
    nonisolated static let displayImageContentMode = PhotoKitSourceFramingPolicy.contentMode

    @Published private(set) var authorization: PhotoAuthorizationState
    @Published private(set) var albums: [AlbumReference] = []
    @Published private(set) var libraryRevision = 0
    private let imageManager = PHCachingImageManager()

    override init() {
        authorization = PhotoAuthorizationState(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        super.init()
        PHPhotoLibrary.shared().register(self)
        if authorization.canRead { refreshAlbums() }
    }

    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }

    func requestAccess() async {
        let result = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorization = PhotoAuthorizationState(result)
        if authorization.canRead { refreshAlbums() }
    }

    /// Re-reads the system authorization when Canvas becomes active again.
    /// People commonly grant Photos access from Settings or the limited
    /// library sheet while onboarding is open; relying only on the value read
    /// during init leaves the picker/Home stuck in the old denied state until
    /// a relaunch.
    func refreshAuthorization() {
        let current = PhotoAuthorizationState(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        guard current != authorization else {
            if current.canRead { refreshAlbums() }
            return
        }
        authorization = current
        if current.canRead { refreshAlbums() } else { albums = [] }
    }

    func refreshAlbums() {
        guard authorization.canRead else { albums = []; return }
        var result: [AlbumReference] = []
        let collections: [(PHFetchResult<PHAssetCollection>, Bool, Bool)] = [
            (PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil), false, false),
            (PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil), true, false),
            (PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumCloudShared, options: nil), false, true)
        ]
        for (fetch, smart, shared) in collections {
            fetch.enumerateObjects { collection, _, _ in
                let assets = PHAsset.fetchAssets(in: collection, options: PHFetchOptions())
                let title = collection.localizedTitle ?? "Untitled album"
                guard !title.isEmpty else { return }
                result.append(AlbumReference(id: collection.localIdentifier, title: title, subtype: collection.assetCollectionSubtype.rawValue, estimatedCount: assets.count, isSmart: smart, isShared: shared))
            }
        }
        var seen = Set<String>()
        albums = result.filter { seen.insert($0.id).inserted }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func assets(for references: [AlbumReference], filters: CanvasFilters) -> [PHAsset] {
        guard authorization.canRead else { return [] }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        var output: [PHAsset] = []
        var seen = Set<String>()
        for reference in references {
            guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [reference.id], options: nil).firstObject else { continue }
            let fetch = PHAsset.fetchAssets(in: collection, options: options)
            fetch.enumerateObjects { asset, _, _ in
                guard seen.insert(asset.localIdentifier).inserted else { return }
                guard filters.includeHidden || !asset.isHidden else { return }
                let kind: MediaKind = asset.mediaType == .video ? .video : (asset.mediaSubtypes.contains(.photoLive) ? .livePhoto : .photo)
                let descriptor = MediaDescriptor(id: asset.localIdentifier, kind: kind, creationDate: asset.creationDate, modificationDate: asset.modificationDate, filename: asset.value(forKey: "filename") as? String ?? "", isFavorite: asset.isFavorite, pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight, albumTitles: [reference.title], isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot), isBurst: asset.burstIdentifier != nil || asset.representsBurst, hasLocation: asset.location != nil)
                if filters.accepts(descriptor) { output.append(asset) }
            }
        }
        return output
    }

    func mediaItems(for references: [AlbumReference], filters: CanvasFilters) -> [CanvasMediaItem] {
        guard authorization.canRead else { return [] }
        let appleReferences = references.filter { $0.source == .applePhotos }
        var output: [CanvasMediaItem] = []
        var seen = Set<String>()
        output.reserveCapacity(appleReferences.reduce(into: 0) { $0 += max(0, $1.estimatedCount) })

        // Build items album-by-album so the queue can balance the complete
        // selected-library pool. A media asset shared by multiple selected
        // albums remains one queue item, attributed to its first selected
        // album, preserving the existing duplicate-suppression behavior.
        for reference in appleReferences {
            for asset in assets(for: [reference], filters: filters) {
                guard seen.insert(asset.localIdentifier).inserted else { continue }
                let kind: MediaKind = asset.mediaType == .video ? .video : (asset.mediaSubtypes.contains(.photoLive) ? .livePhoto : .photo)
                output.append(CanvasMediaItem(id: "apple:\(asset.localIdentifier)", source: .applePhotos, kind: kind, creationDate: asset.creationDate, filename: asset.value(forKey: "filename") as? String ?? "", isFavorite: asset.isFavorite, pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight, albumTitle: reference.title, appleAsset: asset, localURL: nil, contentHash: nil, libraryID: reference.id))
            }
        }
        return output
    }

    func descriptors(for assets: [PHAsset], albumTitle: String? = nil) -> [MediaDescriptor] {
        assets.map { asset in
            let kind: MediaKind = asset.mediaType == .video ? .video : (asset.mediaSubtypes.contains(.photoLive) ? .livePhoto : .photo)
            return MediaDescriptor(id: asset.localIdentifier, kind: kind, creationDate: asset.creationDate, modificationDate: asset.modificationDate, filename: asset.value(forKey: "filename") as? String ?? "", isFavorite: asset.isFavorite, pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight, albumTitles: albumTitle.map { [$0] } ?? [], isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot), isBurst: asset.burstIdentifier != nil || asset.representsBurst, hasLocation: asset.location != nil)
        }
    }

    func requestImage(for asset: PHAsset, targetSize: CGSize, contentMode: PHImageContentMode = PhotoLibraryService.displayImageContentMode) async throws -> UIImage {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let options = PHImageRequestOptions()
                options.deliveryMode = .highQualityFormat
                options.resizeMode = .fast
                options.isNetworkAccessAllowed = true
                imageManager.requestImage(for: asset, targetSize: targetSize, contentMode: contentMode, options: options) { image, info in
                    if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled { return }
                    if let error = info?[PHImageErrorKey] as? Error { continuation.resume(throwing: error); return }
                    guard let image else { continuation.resume(throwing: PhotoLibraryError.imageUnavailable); return }
                    continuation.resume(returning: image)
                }
            }
        } onCancel: {
            self.imageManager.stopCachingImages(for: [], targetSize: .zero, contentMode: contentMode, options: nil)
        }
    }

    func toggleFavorite(_ asset: PHAsset) async {
        guard authorization == .authorized else { return }
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges({ PHAssetChangeRequest(for: asset).isFavorite = !asset.isFavorite }) { _, _ in continuation.resume() }
        }
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.libraryRevision += 1
            self.refreshAlbums()
        }
    }
}

/// Serializes Google-to-PhotoKit mirroring independently from the Google
/// Picker/download service. The Google album is already committed locally
/// before this service runs, so a Photos permission or write failure never
/// discards provider media. This service intentionally has no delete/remove
/// operation: Canvas cleanup never mutates Apple Photos content.
@MainActor
final class GooglePhotosMirrorSerialQueue {
    private var tail: Task<Void, Never>?

    func run<Value>(
        operation: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        let prior = tail
        let task = Task { @MainActor in
            await prior?.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}

@MainActor
final class GooglePhotosMirrorService {
    static let batchSize = 40

    private let indexStore: GooglePhotosMirrorIndexStore
    private let fileManager: FileManager
    private let serialQueue = GooglePhotosMirrorSerialQueue()

    init(indexStore: GooglePhotosMirrorIndexStore = GooglePhotosMirrorIndexStore(), fileManager: FileManager = .default) {
        self.indexStore = indexStore
        self.fileManager = fileManager
    }

    func statusDescription(for canvasAlbumID: String) -> String {
        if let loadError = indexStore.loadError {
            return "Apple Photos mapping needs attention · \(loadError.localizedDescription)"
        }
        guard let entry = indexStore.index.albumsByCanvasID[canvasAlbumID] else {
            return "Apple Photos copy pending"
        }
        if entry.albumRemovedByUser { return "Apple Photos album was removed; Canvas will not recreate it automatically" }
        if let pendingReason = entry.pendingReason { return "Apple Photos copy pending · \(pendingReason)" }
        if !entry.appleAlbumID.isEmpty {
            let activeCount = entry.assetsByGoogleID.values.filter { $0.state == .active }.count
            return "Apple Photos album linked · \(activeCount) mapped item\(activeCount == 1 ? "" : "s")"
        }
        return "Apple Photos copy pending"
    }

    func shouldOfferRetry(for canvasAlbumID: String, expectedItemCount: Int) -> Bool {
        GooglePhotosMirrorRetryPolicy.shouldOfferRetry(
            entry: indexStore.index.albumsByCanvasID[canvasAlbumID],
            expectedItemCount: expectedItemCount,
            indexLoadFailed: indexStore.loadError != nil
        )
    }

    func mirror(
        canvasAlbumID: String,
        title: String,
        records: [GoogleMediaRecord],
        sourceURLsByGoogleID: [String: URL],
        photoLibrary: PhotoLibraryService
    ) async throws -> GoogleApplePhotosMirrorResult {
        // The index is shared by every imported album. Serialize the complete
        // read/PhotoKit-write/index-commit sequence so concurrent imports of
        // different albums cannot overwrite each other's durable mappings.
        try await serialQueue.run { [self] in
            try await performMirror(
                canvasAlbumID: canvasAlbumID,
                title: title,
                records: records,
                sourceURLsByGoogleID: sourceURLsByGoogleID,
                photoLibrary: photoLibrary
            )
        }
    }

    private func performMirror(
        canvasAlbumID: String,
        title: String,
        records: [GoogleMediaRecord],
        sourceURLsByGoogleID: [String: URL],
        photoLibrary: PhotoLibraryService
    ) async throws -> GoogleApplePhotosMirrorResult {
        if let loadError = indexStore.loadError { throw loadError }
        var index = indexStore.index
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            photoLibrary.refreshAuthorization()
        }
        guard GooglePhotosMirrorAuthorizationPolicy.permitsNamedAlbumMirroring(status) else {
            var pending = index.albumsByCanvasID[canvasAlbumID] ?? GooglePhotosMirrorAlbumEntry(
                title: title,
                appleAlbumID: "",
                albumRemovedByUser: false,
                pendingReason: "Full Photos access is required.",
                assetsByGoogleID: [:],
                updatedAt: Date()
            )
            pending.title = title
            pending.pendingReason = "Full Photos access is required."
            pending.updatedAt = Date()
            index.albumsByCanvasID[canvasAlbumID] = pending
            try indexStore.persist(index)
            throw GoogleApplePhotosMirrorError.fullAccessRequired
        }

        let now = Date()
        var entry = index.albumsByCanvasID[canvasAlbumID]

        let persistedAlbumID = entry?.appleAlbumID
        let persistedAlbum = persistedAlbumID.flatMap(editableUserAlbum(identifier:))
        let exactMatches = editableUserAlbums(named: title)
        let markerMatches = markerVerifiedAlbums(
            canvasAlbumID: canvasAlbumID,
            title: title,
            records: records,
            persistedEntry: entry
        )
        let resolution = GooglePhotosMirrorAlbumResolutionPolicy.resolve(
            persistedAlbumID: persistedAlbumID,
            persistedAlbumRemoved: entry?.albumRemovedByUser == true,
            persistedAlbumAccessible: persistedAlbum != nil,
            markerVerifiedAlbumIDs: markerMatches.map(\.localIdentifier),
            exactEditableAlbumIDs: exactMatches.map(\.localIdentifier)
        )
        var album: PHAssetCollection?
        switch resolution {
        case .reuse(let identifier):
            album = persistedAlbum?.localIdentifier == identifier
                ? persistedAlbum
                : (exactMatches.first(where: { $0.localIdentifier == identifier })
                    ?? markerMatches.first(where: { $0.localIdentifier == identifier }))
            if let album, entry?.appleAlbumID != album.localIdentifier {
                entry = GooglePhotosMirrorAlbumEntry(
                    title: title,
                    appleAlbumID: album.localIdentifier,
                    albumRemovedByUser: false,
                    pendingReason: nil,
                    assetsByGoogleID: entry?.assetsByGoogleID ?? [:],
                    updatedAt: now
                )
            }
        case .create:
            album = nil
        case .failRemoved:
            if var existingEntry = entry {
                existingEntry.albumRemovedByUser = true
                existingEntry.pendingReason = nil
                existingEntry.updatedAt = now
                index.albumsByCanvasID[canvasAlbumID] = existingEntry
                try indexStore.persist(index)
            }
            throw GoogleApplePhotosMirrorError.managedAlbumRemoved
        case .failAmbiguous:
            var ambiguousEntry = entry ?? GooglePhotosMirrorAlbumEntry(
                title: title,
                appleAlbumID: persistedAlbumID ?? "",
                albumRemovedByUser: false,
                pendingReason: nil,
                assetsByGoogleID: [:],
                updatedAt: now
            )
            ambiguousEntry.pendingReason = "More than one editable Apple Photos album has this name."
            ambiguousEntry.updatedAt = now
            index.albumsByCanvasID[canvasAlbumID] = ambiguousEntry
            try indexStore.persist(index)
            throw GoogleApplePhotosMirrorError.ambiguousRecovery
        case .failOwnershipUnverified:
            var unverifiedEntry = entry ?? GooglePhotosMirrorAlbumEntry(
                title: title,
                appleAlbumID: "",
                albumRemovedByUser: false,
                pendingReason: nil,
                assetsByGoogleID: [:],
                updatedAt: now
            )
            unverifiedEntry.pendingReason = "An existing Apple Photos album has this name, but Canvas could not verify that it owns it."
            unverifiedEntry.updatedAt = now
            index.albumsByCanvasID[canvasAlbumID] = unverifiedEntry
            try indexStore.persist(index)
            throw GoogleApplePhotosMirrorError.ownershipUnverified
        }

        var workingEntry = entry ?? GooglePhotosMirrorAlbumEntry(
            title: title,
            appleAlbumID: "",
            albumRemovedByUser: false,
            pendingReason: nil,
            assetsByGoogleID: [:],
            updatedAt: now
        )
        workingEntry.title = title
        workingEntry.pendingReason = nil
        workingEntry.updatedAt = now

        let targetRecoveredAssetIDsByContentHash = album.map(recoveredAssetIDsByContentHash(in:)) ?? [:]
        let allPersistedAssetIDs = Set(index.albumsByCanvasID.values.flatMap { entry in
            entry.assetsByGoogleID.values.compactMap { asset in
                asset.state == .active && !asset.appleAssetID.isEmpty ? asset.appleAssetID : nil
            }
        })
        let accessibleAssetIDs = accessibleAssets(identifiers: allPersistedAssetIDs)
        let sharedMappings = sharedMirrorAssetMappings(
            in: index,
            excludingCanvasAlbumID: canvasAlbumID,
            accessibleAssetIDs: accessibleAssetIDs
        )
        var failedGoogleIDs = Set<String>()
        let reconciliation = GooglePhotosMirrorAssetReconciliationPolicy.reconcile(
            records: records,
            persistedEntries: workingEntry.assetsByGoogleID,
            accessibleAssetIDs: accessibleAssetIDs,
            recoveredAssetIDsByContentHash: targetRecoveredAssetIDsByContentHash,
            sharedAssetIDsByGoogleID: sharedMappings.byGoogleID,
            sharedAssetIDsByContentHash: sharedMappings.byContentHash,
            assetIDsInTargetAlbum: album.map(assetIDs(in:)),
            assetIDsAlreadyInTargetAlbum: Set(targetRecoveredAssetIDsByContentHash.values),
            verifiedAt: now
        )
        workingEntry.assetsByGoogleID = reconciliation.entriesByGoogleID
        let recordsNeedingCreationByHash = reconciliation.recordsNeedingCreationByHash

        var candidates: [GoogleApplePhotosMirrorCandidate] = []
        var googleIDsByCandidateID: [String: [String]] = [:]
        for recordsForHash in recordsNeedingCreationByHash.values {
            guard let sourceRecord = recordsForHash.first(where: {
                sourceURLsByGoogleID[$0.googleID].map { fileManager.fileExists(atPath: $0.path) } == true
            }), let sourceURL = sourceURLsByGoogleID[sourceRecord.googleID] else {
                failedGoogleIDs.formUnion(recordsForHash.map(\.googleID))
                continue
            }
            let candidate = GoogleApplePhotosMirrorCandidate(
                record: sourceRecord,
                sourceURL: sourceURL,
                markerFilename: GoogleApplePhotosMirrorIdentity.markerFilename(
                    contentHash: sourceRecord.contentHash,
                    originalFilename: sourceRecord.filename,
                    canvasAlbumID: canvasAlbumID
                )
            )
            candidates.append(candidate)
            googleIDsByCandidateID[sourceRecord.googleID] = recordsForHash.map(\.googleID)
        }

        var addedAssetIDsByCandidateID: [String: String] = [:]
        var newlyCreatedAppleAssetIDs = Set<String>()
        var sharedAssetIDsAlreadyAddedToAlbum = Set<String>()
        if album == nil {
            // The first valid asset and album are committed together, closing
            // the crash window where an untracked empty album could be created.
            while album == nil, !candidates.isEmpty {
                let candidate = candidates.removeFirst()
                do {
                    let created = try await createAlbum(named: title, with: candidate)
                    album = created.album
                    workingEntry.appleAlbumID = created.album.localIdentifier
                    workingEntry.albumRemovedByUser = false
                    addedAssetIDsByCandidateID.merge(created.assetIDsByGoogleID) { _, new in new }
                    newlyCreatedAppleAssetIDs.formUnion(created.assetIDsByGoogleID.values)
                } catch {
                    failedGoogleIDs.formUnion(googleIDsByCandidateID[candidate.record.googleID] ?? [candidate.record.googleID])
                }
            }
            if album == nil, !reconciliation.assetIDsToAddToTargetByGoogleID.isEmpty {
                let existingIDs = Set(reconciliation.assetIDsToAddToTargetByGoogleID.values)
                let existingAssets = fetchAssets(identifiers: existingIDs)
                guard existingAssets.count == existingIDs.count else {
                    failedGoogleIDs.formUnion(reconciliation.assetIDsToAddToTargetByGoogleID.keys)
                    for googleID in reconciliation.assetIDsToAddToTargetByGoogleID.keys {
                        workingEntry.assetsByGoogleID.removeValue(forKey: googleID)
                    }
                    throw GoogleApplePhotosMirrorError.albumCreationFailed
                }
                do {
                    album = try await createAlbum(named: title, adding: existingAssets)
                    sharedAssetIDsAlreadyAddedToAlbum = existingIDs
                } catch {
                    failedGoogleIDs.formUnion(reconciliation.assetIDsToAddToTargetByGoogleID.keys)
                    for googleID in reconciliation.assetIDsToAddToTargetByGoogleID.keys {
                        workingEntry.assetsByGoogleID.removeValue(forKey: googleID)
                    }
                    throw GoogleApplePhotosMirrorError.albumCreationFailed
                }
            }
            guard let album else { throw GoogleApplePhotosMirrorError.albumCreationFailed }
            workingEntry.appleAlbumID = album.localIdentifier
            applyCreatedMappings(
                addedAssetIDsByCandidateID,
                candidatesToGoogleIDs: googleIDsByCandidateID,
                records: records,
                canvasAlbumID: canvasAlbumID,
                entry: &workingEntry,
                verifiedAt: now
            )
        } else if workingEntry.appleAlbumID.isEmpty, let album {
            workingEntry.appleAlbumID = album.localIdentifier
        }

        guard let resolvedAlbum = album else { throw GoogleApplePhotosMirrorError.albumCreationFailed }
        var alreadyMirroredCount = reconciliation.alreadyMirroredCount
        let sharedMappingsToAdd = reconciliation.assetIDsToAddToTargetByGoogleID
            .filter { !sharedAssetIDsAlreadyAddedToAlbum.contains($0.value) }
        if !sharedMappingsToAdd.isEmpty {
            let membership = await addExistingAssetsResiliently(
                identifiers: Set(sharedMappingsToAdd.values),
                to: resolvedAlbum
            )
            sharedAssetIDsAlreadyAddedToAlbum.formUnion(membership.addedAssetIDs)
            let failedSharedGoogleIDs = Set(sharedMappingsToAdd.compactMap { googleID, assetID in
                membership.failedAssetIDs.contains(assetID) ? googleID : nil
            })
            if !failedSharedGoogleIDs.isEmpty {
                failedGoogleIDs.formUnion(failedSharedGoogleIDs)
                alreadyMirroredCount -= failedSharedGoogleIDs.count
                for googleID in failedSharedGoogleIDs {
                    workingEntry.assetsByGoogleID.removeValue(forKey: googleID)
                }
            }
        }
        index.albumsByCanvasID[canvasAlbumID] = workingEntry
        try indexStore.persist(index)
        for start in stride(from: 0, to: candidates.count, by: Self.batchSize) {
            let end = min(start + Self.batchSize, candidates.count)
            let batch = Array(candidates[start..<end])
            let batchResult = await createResiliently(batch, in: resolvedAlbum)
            failedGoogleIDs.formUnion(batchResult.failedGoogleIDs.flatMap { googleIDsByCandidateID[$0] ?? [$0] })
            newlyCreatedAppleAssetIDs.formUnion(batchResult.assetIDsByGoogleID.values)
            applyCreatedMappings(
                batchResult.assetIDsByGoogleID,
                candidatesToGoogleIDs: googleIDsByCandidateID,
                records: records,
                canvasAlbumID: canvasAlbumID,
                entry: &workingEntry,
                verifiedAt: Date()
            )
            index.albumsByCanvasID[canvasAlbumID] = workingEntry
            try indexStore.persist(index)
        }

        workingEntry.pendingReason = failedGoogleIDs.isEmpty
            ? nil
            : "\(failedGoogleIDs.count) item\(failedGoogleIDs.count == 1 ? "" : "s") still need copying."
        workingEntry.updatedAt = Date()
        index.albumsByCanvasID[canvasAlbumID] = workingEntry
        try indexStore.persist(index)

        photoLibrary.refreshAlbums()
        return GoogleApplePhotosMirrorResult(
            albumID: resolvedAlbum.localIdentifier,
            assetIDsByGoogleID: workingEntry.assetsByGoogleID.compactMapValues {
                $0.state == .active ? $0.appleAssetID : nil
            },
            tombstoneGoogleIDs: Set(workingEntry.assetsByGoogleID.compactMap {
                $0.value.state == .removedByUser ? $0.key : nil
            }),
            addedCount: newlyCreatedAppleAssetIDs.count,
            alreadyMirroredCount: alreadyMirroredCount,
            failedGoogleIDs: failedGoogleIDs
        )
    }

    private func applyCreatedMappings(
        _ created: [String: String],
        candidatesToGoogleIDs: [String: [String]],
        records: [GoogleMediaRecord],
        canvasAlbumID: String,
        entry: inout GooglePhotosMirrorAlbumEntry,
        verifiedAt: Date
    ) {
        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.googleID, $0) })
        for (candidateGoogleID, appleAssetID) in created {
            for googleID in candidatesToGoogleIDs[candidateGoogleID] ?? [candidateGoogleID] {
                guard let record = recordsByID[googleID] else { continue }
                entry.assetsByGoogleID[googleID] = GooglePhotosMirrorAssetEntry(
                    contentHash: GoogleApplePhotosMirrorIdentity.canonicalContentHash(record.contentHash),
                    appleAssetID: appleAssetID,
                    markerFilename: GoogleApplePhotosMirrorIdentity.markerFilename(
                        contentHash: record.contentHash,
                        originalFilename: record.filename,
                        canvasAlbumID: canvasAlbumID
                    ),
                    state: .active,
                    lastVerifiedAt: verifiedAt
                )
            }
        }
        entry.updatedAt = verifiedAt
    }

    private func sharedMirrorAssetMappings(
        in index: GooglePhotosMirrorIndex,
        excludingCanvasAlbumID: String,
        accessibleAssetIDs: Set<String>
    ) -> (byGoogleID: [String: String], byContentHash: [String: String]) {
        var byGoogleID: [String: String] = [:]
        var byContentHash: [String: String] = [:]
        for (canvasID, albumEntry) in index.albumsByCanvasID where canvasID != excludingCanvasAlbumID {
            for (googleID, assetEntry) in albumEntry.assetsByGoogleID
            where assetEntry.state == .active && accessibleAssetIDs.contains(assetEntry.appleAssetID) {
                byGoogleID[googleID] = assetEntry.appleAssetID
                byContentHash[GoogleApplePhotosMirrorIdentity.canonicalContentHash(assetEntry.contentHash)] = assetEntry.appleAssetID
            }
            guard let album = readableAlbum(identifier: albumEntry.appleAlbumID) else { continue }
            for (hash, assetID) in recoveredAssetIDsByContentHash(in: album) {
                byContentHash[hash] = assetID
            }
        }
        return (byGoogleID, byContentHash)
    }

    private func readableAlbum(identifier: String) -> PHAssetCollection? {
        guard !identifier.isEmpty,
              let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil).firstObject,
              album.assetCollectionType == .album,
              album.assetCollectionSubtype != .albumCloudShared else { return nil }
        return album
    }

    private func assetIDs(in album: PHAssetCollection) -> Set<String> {
        let fetch = PHAsset.fetchAssets(in: album, options: nil)
        var result = Set<String>()
        fetch.enumerateObjects { asset, _, _ in result.insert(asset.localIdentifier) }
        return result
    }

    private func fetchAssets(identifiers: Set<String>) -> [PHAsset] {
        guard !identifiers.isEmpty else { return [] }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: Array(identifiers), options: nil)
        var result: [PHAsset] = []
        fetch.enumerateObjects { asset, _, _ in result.append(asset) }
        return result
    }

    private func addExistingAssetsResiliently(
        identifiers: Set<String>,
        to album: PHAssetCollection
    ) async -> (addedAssetIDs: Set<String>, failedAssetIDs: Set<String>) {
        guard !identifiers.isEmpty else { return ([], []) }
        do {
            try await addExistingAssets(identifiers: identifiers, to: album)
            return (identifiers, [])
        } catch {
            guard identifiers.count > 1 else { return ([], identifiers) }
            let values = Array(identifiers)
            let midpoint = values.count / 2
            let first = await addExistingAssetsResiliently(
                identifiers: Set(values[..<midpoint]),
                to: album
            )
            let second = await addExistingAssetsResiliently(
                identifiers: Set(values[midpoint...]),
                to: album
            )
            return (
                first.addedAssetIDs.union(second.addedAssetIDs),
                first.failedAssetIDs.union(second.failedAssetIDs)
            )
        }
    }

    private func addExistingAssets(identifiers: Set<String>, to album: PHAssetCollection) async throws {
        let assets = fetchAssets(identifiers: identifiers)
        guard assets.count == identifiers.count else {
            throw GoogleApplePhotosMirrorError.photoLibraryChangeFailed("One or more existing Apple Photos assets are no longer available.")
        }
        let alreadyMembers = assetIDs(in: album)
        let toAdd = assets.filter { !alreadyMembers.contains($0.localIdentifier) }
        guard !toAdd.isEmpty else { return }
        try await performChanges {
            guard let request = PHAssetCollectionChangeRequest(for: album) else { return }
            request.addAssets(toAdd as NSArray)
        }
    }

    private func editableUserAlbum(identifier: String) -> PHAssetCollection? {
        guard !identifier.isEmpty,
              let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil).firstObject,
              album.assetCollectionType == .album,
              album.assetCollectionSubtype != .albumCloudShared,
              album.canPerform(.addContent) else { return nil }
        return album
    }

    private func editableUserAlbums(named title: String) -> [PHAssetCollection] {
        editableUserAlbums().filter { $0.localizedTitle?.googleMirrorTitleKey == title.googleMirrorTitleKey }
    }

    private func editableUserAlbums() -> [PHAssetCollection] {
        let fetch = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var matches: [PHAssetCollection] = []
        fetch.enumerateObjects { album, _, _ in
            guard album.assetCollectionSubtype != .albumCloudShared,
                  album.canPerform(.addContent) else { return }
            matches.append(album)
        }
        return matches
    }

    /// A title is only a search hint. Ownership is established by a persisted
    /// local identifier or by a Canvas resource marker in the collection.
    /// Without the new per-Canvas-album owner token, marker recovery is
    /// intentionally limited to same-title collections so a one-item overlap
    /// cannot collapse a differently named Google import into an older Apple
    /// album.
    private func markerVerifiedAlbums(
        canvasAlbumID: String,
        title: String,
        records: [GoogleMediaRecord],
        persistedEntry: GooglePhotosMirrorAlbumEntry?
    ) -> [PHAssetCollection] {
        let expectedHashes = Set(records.map { GoogleApplePhotosMirrorIdentity.canonicalContentHash($0.contentHash) })
            .union(persistedEntry?.assetsByGoogleID.values.map { GoogleApplePhotosMirrorIdentity.canonicalContentHash($0.contentHash) } ?? [])
        guard !expectedHashes.isEmpty else { return [] }
        let expectedOwnerToken = GoogleApplePhotosMirrorIdentity.ownerToken(for: canvasAlbumID)
        let titleScopedAlbumIDs = Set(editableUserAlbums(named: title).map(\.localIdentifier))
        // A new owner-token marker is enough to recover a Canvas-created
        // collection after a crash or an index-write failure, even if the
        // person renamed that collection. Preserved WIP markers contain only a
        // content hash, so they remain title-scoped and can never bridge a
        // differently named import.
        let candidates = editableUserAlbums()
        return candidates.filter { album in
            let fetch = PHAsset.fetchAssets(in: album, options: nil)
            var verified = false
            fetch.enumerateObjects { asset, _, stop in
                for resource in PHAssetResource.assetResources(for: asset) {
                    guard let hash = GoogleApplePhotosMirrorIdentity.contentHash(fromMarkerFilename: resource.originalFilename),
                          expectedHashes.contains(hash) else { continue }
                    if let markerOwner = GoogleApplePhotosMirrorIdentity.ownerToken(fromMarkerFilename: resource.originalFilename) {
                        guard markerOwner == expectedOwnerToken else { continue }
                    } else {
                        // A legacy content-only marker remains recoverable
                        // only under the same-title search scope above.
                        guard titleScopedAlbumIDs.contains(album.localIdentifier) else { continue }
                    }
                    verified = true
                    stop.pointee = true
                    break
                }
            }
            return verified
        }
    }

    private func accessibleAssets(identifiers: Set<String>) -> Set<String> {
        guard !identifiers.isEmpty else { return [] }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: Array(identifiers), options: nil)
        var result = Set<String>()
        fetch.enumerateObjects { asset, _, _ in result.insert(asset.localIdentifier) }
        return result
    }

    private func recoveredAssetIDsByContentHash(in album: PHAssetCollection) -> [String: String] {
        let fetch = PHAsset.fetchAssets(in: album, options: nil)
        var result: [String: String] = [:]
        fetch.enumerateObjects { asset, _, _ in
            for resource in PHAssetResource.assetResources(for: asset) {
                guard let hash = GoogleApplePhotosMirrorIdentity.contentHash(fromMarkerFilename: resource.originalFilename) else { continue }
                result[hash] = asset.localIdentifier
            }
        }
        return result
    }

    private func createAlbum(
        named title: String,
        with candidate: GoogleApplePhotosMirrorCandidate
    ) async throws -> (album: PHAssetCollection, assetIDsByGoogleID: [String: String]) {
        let box = PhotoKitPlaceholderBox()
        try await performChanges {
            let albumRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            let placeholder = albumRequest.placeholderForCreatedAssetCollection
            box.setAlbumIdentifier(placeholder.localIdentifier)
            let assetRequest = Self.assetCreationRequest(for: candidate)
            guard let assetPlaceholder = assetRequest.placeholderForCreatedAsset else { return }
            box.setAssetIdentifier(assetPlaceholder.localIdentifier, for: candidate.record.googleID)
            albumRequest.addAssets([assetPlaceholder] as NSArray)
        }
        let snapshot = box.snapshot
        guard let albumID = snapshot.albumID,
              let album = editableUserAlbum(identifier: albumID),
              !snapshot.assets.isEmpty else { throw GoogleApplePhotosMirrorError.albumCreationFailed }
        return (album, snapshot.assets)
    }

    private func createAlbum(
        named title: String,
        adding existingAssets: [PHAsset]
    ) async throws -> PHAssetCollection {
        guard !existingAssets.isEmpty else { throw GoogleApplePhotosMirrorError.albumCreationFailed }
        let box = PhotoKitPlaceholderBox()
        try await performChanges {
            let albumRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            let placeholder = albumRequest.placeholderForCreatedAssetCollection
            box.setAlbumIdentifier(placeholder.localIdentifier)
            albumRequest.addAssets(existingAssets as NSArray)
        }
        let snapshot = box.snapshot
        guard let albumID = snapshot.albumID,
              let album = editableUserAlbum(identifier: albumID) else {
            throw GoogleApplePhotosMirrorError.albumCreationFailed
        }
        return album
    }

    private func createResiliently(
        _ candidates: [GoogleApplePhotosMirrorCandidate],
        in album: PHAssetCollection
    ) async -> (assetIDsByGoogleID: [String: String], failedGoogleIDs: Set<String>) {
        guard !candidates.isEmpty else { return ([:], []) }
        do {
            return (try await create(candidates, in: album), [])
        } catch {
            guard candidates.count > 1 else { return ([:], [candidates[0].record.googleID]) }
            let midpoint = candidates.count / 2
            let first = await createResiliently(Array(candidates[..<midpoint]), in: album)
            let second = await createResiliently(Array(candidates[midpoint...]), in: album)
            return (
                first.assetIDsByGoogleID.merging(second.assetIDsByGoogleID) { _, new in new },
                first.failedGoogleIDs.union(second.failedGoogleIDs)
            )
        }
    }

    private func create(
        _ candidates: [GoogleApplePhotosMirrorCandidate],
        in album: PHAssetCollection
    ) async throws -> [String: String] {
        let box = PhotoKitPlaceholderBox()
        try await performChanges {
            guard let albumRequest = PHAssetCollectionChangeRequest(for: album) else { return }
            var placeholders: [PHObjectPlaceholder] = []
            for candidate in candidates {
                let assetRequest = Self.assetCreationRequest(for: candidate)
                guard let placeholder = assetRequest.placeholderForCreatedAsset else { continue }
                box.setAssetIdentifier(placeholder.localIdentifier, for: candidate.record.googleID)
                placeholders.append(placeholder)
            }
            albumRequest.addAssets(placeholders as NSArray)
        }
        let created = box.snapshot.assets
        guard created.count == candidates.count else {
            throw GoogleApplePhotosMirrorError.photoLibraryChangeFailed("Photos did not return every created asset identifier.")
        }
        return created
    }

    private nonisolated static func assetCreationRequest(
        for candidate: GoogleApplePhotosMirrorCandidate
    ) -> PHAssetCreationRequest {
        let request = PHAssetCreationRequest.forAsset()
        request.creationDate = candidate.record.creationDate
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = candidate.markerFilename
        options.shouldMoveFile = false
        request.addResource(
            with: candidate.record.kind == .video ? .video : .photo,
            fileURL: candidate.sourceURL,
            options: options
        )
        return request
    }

    private func performChanges(_ changes: @escaping @Sendable () -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges(changes) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: GoogleApplePhotosMirrorError.photoLibraryChangeFailed(error?.localizedDescription ?? "Unknown Photos error"))
                }
            }
        }
    }
}

private extension String {
    var googleMirrorTitleKey: String {
        precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum PhotoLibraryError: LocalizedError { case imageUnavailable; var errorDescription: String? { "This photo is unavailable right now." } }

@MainActor
final class AssetImageLoader: ObservableObject {
    // NSCache has no useful default memory budget. A frame can run for days,
    // and retaining every 1,800px image eventually pushes the foreground app
    // into Jetsam territory on an iPad. Keep enough history for smooth
    // transitions while putting a hard upper bound on decoded image memory.
    static let cacheCountLimit = 48
    static let cacheTotalCostLimit = 256 * 1024 * 1024

    @Published private(set) var cache = NSCache<NSString, UIImage>()
    private var prefetchTasks: [Task<Void, Never>] = []
    private var memoryWarningObserver: NSObjectProtocol?

    init() {
        cache.countLimit = Self.cacheCountLimit
        cache.totalCostLimit = Self.cacheTotalCostLimit
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.clear()
        }
    }

    deinit {
        prefetchTasks.forEach { $0.cancel() }
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    func image(for asset: PHAsset, service: PhotoLibraryService, size: CGSize) async -> UIImage? {
        let key = "\(asset.localIdentifier)-\(Int(size.width))x\(Int(size.height))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        do {
            // Keep the complete source aspect ratio. Canvas performs the
            // intentional fit/fill crop in LayoutCanvas after loading.
            let image = try await service.requestImage(
                for: asset,
                targetSize: size,
                contentMode: PhotoLibraryService.displayImageContentMode
            )
            store(image, forKey: key)
            return image
        } catch { return nil }
    }
    func image(for item: CanvasMediaItem, service: PhotoLibraryService, size: CGSize) async -> UIImage? {
        let key = "\(item.id)-\(Int(size.width))x\(Int(size.height))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        var image: UIImage?
        if let asset = item.appleAsset {
            // The asset-keyed path already owns the cache entry. Avoid adding
            // a second key for the same decoded UIImage on every Apple item.
            return await self.image(for: asset, service: service, size: size)
        } else if let url = item.localURL, item.kind == .video {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = size
            if let frame = try? await generator.image(at: .zero) { image = UIImage(cgImage: frame.image) }
        } else if let url = item.localURL {
            image = UIImage(contentsOfFile: url.path)
        } else {
            image = nil
        }
        if let image { store(image, forKey: key) }
        return image
    }

    func clear() {
        prefetchTasks.forEach { $0.cancel() }
        prefetchTasks.removeAll()
        cache.removeAllObjects()
    }

    func prefetch(_ assets: [PHAsset], service: PhotoLibraryService, size: CGSize) {
        prefetchTasks.forEach { $0.cancel() }
        prefetchTasks = assets.prefix(4).map { asset in
            Task { [weak self] in
                guard let self else { return }
                _ = await self.image(for: asset, service: service, size: size)
            }
        }
    }

    func prefetch(_ items: [CanvasMediaItem], service: PhotoLibraryService, size: CGSize) {
        prefetchTasks.forEach { $0.cancel() }
        prefetchTasks = items.prefix(4).map { item in
            Task { [weak self] in
                guard let self else { return }
                _ = await self.image(for: item, service: service, size: size)
            }
        }
    }

    private func store(_ image: UIImage, forKey key: NSString) {
        let cost: Int
        if let cgImage = image.cgImage {
            cost = max(1, cgImage.bytesPerRow * cgImage.height)
        } else {
            let width = max(1, Int(image.size.width * image.scale))
            let height = max(1, Int(image.size.height * image.scale))
            cost = max(1, width * height * 4)
        }
        cache.setObject(image, forKey: key, cost: cost)
    }
}
