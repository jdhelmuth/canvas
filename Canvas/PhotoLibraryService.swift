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
    var explanation: String? {
        switch self {
        case .limited: "Photos access is limited. Canvas can only show the items you selected in Photos; choose More Photos in Settings for a complete frame."
        case .denied: "Photos access is off. Enable it in Settings to choose albums and start a frame."
        case .restricted: "Photos access is restricted by this device or account."
        default: nil
        }
    }
}

@MainActor
final class PhotoLibraryService: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    /// Canvas applies its own fit/fill decision after the image is loaded.
    /// Requesting aspectFill here would crop the source photo to the square
    /// thumbnail bounds before LayoutCanvas can calculate the correct crop.
    nonisolated static let displayImageContentMode: PHImageContentMode = .aspectFit

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
                output.append(CanvasMediaItem(id: "apple:\(asset.localIdentifier)", source: .applePhotos, kind: kind, creationDate: asset.creationDate, filename: asset.value(forKey: "filename") as? String ?? "", isFavorite: asset.isFavorite, pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight, albumTitle: reference.title, appleAsset: asset, localURL: nil, contentHash: nil))
            }
        }
        return output
    }

    /// Returns an Apple album only for a near-exact metadata match. Partial overlap stays visible
    /// as a Google album while queue-level identity matching removes duplicated media.
    func bestMatchingAlbum(for googleItems: [GoogleMediaRecord]) -> String? {
        guard authorization.canRead, !googleItems.isEmpty else { return nil }
        let googleKeys = Set(googleItems.map { item in
            let base = (item.filename as NSString).deletingPathExtension.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let timestamp = item.creationDate.map { Int($0.timeIntervalSince1970.rounded()) } ?? 0
            return "\(item.kind.rawValue)|\(base)|\(timestamp)|\(item.pixelWidth)x\(item.pixelHeight)"
        })
        var best: (id: String, score: Double)?
        for album in albums where album.source == .applePhotos {
            guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album.id], options: nil).firstObject else { continue }
            let fetch = PHAsset.fetchAssets(in: collection, options: nil)
            guard fetch.count == googleItems.count else { continue }
            var keys = Set<String>()
            fetch.enumerateObjects { asset, _, _ in
                let kind: MediaKind = asset.mediaType == .video ? .video : (asset.mediaSubtypes.contains(.photoLive) ? .livePhoto : .photo)
                let filename = asset.value(forKey: "filename") as? String ?? ""
                let base = (filename as NSString).deletingPathExtension.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                let timestamp = asset.creationDate.map { Int($0.timeIntervalSince1970.rounded()) } ?? 0
                keys.insert("\(kind.rawValue)|\(base)|\(timestamp)|\(asset.pixelWidth)x\(asset.pixelHeight)")
            }
            let score = Double(keys.intersection(googleKeys).count) / Double(max(1, googleKeys.count))
            if score >= 0.98, score > (best?.score ?? 0) { best = (album.id, score) }
        }
        return best?.id
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

enum PhotoLibraryError: LocalizedError { case imageUnavailable; var errorDescription: String? { "This photo is unavailable right now." } }

@MainActor
final class AssetImageLoader: ObservableObject {
    @Published private(set) var cache = NSCache<NSString, UIImage>()
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
            cache.setObject(image, forKey: key)
            return image
        } catch { return nil }
    }
    func image(for item: CanvasMediaItem, service: PhotoLibraryService, size: CGSize) async -> UIImage? {
        let key = "\(item.id)-\(Int(size.width))x\(Int(size.height))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        var image: UIImage?
        if let asset = item.appleAsset {
            image = await self.image(for: asset, service: service, size: size)
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
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
    func clear() { cache.removeAllObjects() }
    func prefetch(_ assets: [PHAsset], service: PhotoLibraryService, size: CGSize) {
        for asset in assets.prefix(4) {
            Task { _ = await image(for: asset, service: service, size: size) }
        }
    }
    func prefetch(_ items: [CanvasMediaItem], service: PhotoLibraryService, size: CGSize) {
        for item in items.prefix(4) { Task { _ = await image(for: item, service: service, size: size) } }
    }
}
