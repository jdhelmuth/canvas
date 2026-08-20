import Foundation
import SwiftUI
import UIKit

/// Marker class so bundled resources resolve from the Canvas app bundle even
/// when unit tests query `Bundle(for:)`.
private final class BundledPhotoLibraryMarker {}

struct BundledPhotoRecord: Hashable, Identifiable {
    let id: String
    let filename: String
    let title: String
    let credit: String
    let creationDate: Date?
}

/// Public-domain U.S. National Park Service landscapes that ship with Canvas.
/// The album is available without Photos or Google authorization so a new
/// install can start a frame immediately, similar to a Nest Hub default library.
enum BundledPhotoLibrary {
    static let landscapesAlbumID = "bundled:landscapes"
    static let landscapesTitle = "Landscapes"
    static let resourceSubdirectory = "IncludedAlbums/Landscapes"

    static var resourceBundle: Bundle { Bundle(for: BundledPhotoLibraryMarker.self) }

    static let landscapesPhotos: [BundledPhotoRecord] = [
        BundledPhotoRecord(id: "yellowstone-inspiration", filename: "yellowstone-inspiration.jpg", title: "Grand Canyon of the Yellowstone", credit: "NPS / Jacob W. Frank, Yellowstone National Park", creationDate: date("2019-08-16")),
        BundledPhotoRecord(id: "joshua-tree-sunset", filename: "joshua-tree-sunset.jpg", title: "Joshua Tree sunset", credit: "NPS / Emily Hassell, Joshua Tree National Park", creationDate: date("2020-06-09")),
        BundledPhotoRecord(id: "avalanche-peak", filename: "avalanche-peak.jpg", title: "Avalanche Peak", credit: "Yellowstone National Park", creationDate: date("2021-07-24")),
        BundledPhotoRecord(id: "yellowstone-lake", filename: "yellowstone-lake.jpg", title: "Yellowstone Lake", credit: "Yellowstone National Park", creationDate: date("2020-05-27")),
        BundledPhotoRecord(id: "glacier-bay", filename: "glacier-bay.jpg", title: "Glacier Bay", credit: "NPS Natural Resources, Glacier Bay National Park", creationDate: date("2008-05-28")),
        BundledPhotoRecord(id: "glacier-sunset", filename: "glacier-sunset.jpg", title: "Logan Pass sunset", credit: "NPS / Tim Rains, Glacier National Park", creationDate: date("2012-03-18")),
        BundledPhotoRecord(id: "olympic-sea-stacks", filename: "olympic-sea-stacks.jpg", title: "Olympic sea stacks", credit: "National Park Service, Olympic National Park", creationDate: nil),
        BundledPhotoRecord(id: "olympic-twilight", filename: "olympic-twilight.jpg", title: "Olympic coast twilight", credit: "NPS / S. Sheltren, Olympic National Park", creationDate: nil),
        BundledPhotoRecord(id: "delicate-arch", filename: "delicate-arch.jpg", title: "Delicate Arch", credit: "NPS / Jacob W. Frank, Arches National Park", creationDate: nil),
        BundledPhotoRecord(id: "yosemite-falls", filename: "yosemite-falls.jpg", title: "Yosemite Falls", credit: "NPS / Damon Joyce, Yosemite National Park", creationDate: nil),
        BundledPhotoRecord(id: "smoky-forest", filename: "smoky-forest.jpg", title: "Great Smoky Mountains forest", credit: "NPS / Andrea Walton, Great Smoky Mountains National Park", creationDate: date("2018-05-01")),
        BundledPhotoRecord(id: "zion-east", filename: "zion-east.jpg", title: "East Zion", credit: "NPS / Caitlin Ceci, Zion National Park", creationDate: nil),
        BundledPhotoRecord(id: "kenai-glacier", filename: "kenai-glacier.jpg", title: "Kenai Fjords glacier", credit: "NPS / Victoria Stauffenberg, Kenai Fjords National Park", creationDate: nil)
    ]

    static var albums: [AlbumReference] {
        [landscapesAlbum]
    }

    static var landscapesAlbum: AlbumReference {
        AlbumReference(
            id: landscapesAlbumID,
            title: landscapesTitle,
            subtype: 0,
            estimatedCount: landscapesPhotos.count,
            isSmart: false,
            isShared: false,
            source: .bundled
        )
    }

    static func url(for filename: String) -> URL? {
        let name = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        return resourceBundle.url(forResource: name, withExtension: ext, subdirectory: resourceSubdirectory)
            ?? resourceBundle.url(forResource: name, withExtension: ext, subdirectory: "Landscapes")
            ?? resourceBundle.url(forResource: name, withExtension: ext)
    }

    static func items(for references: [AlbumReference], filters: CanvasFilters) -> [CanvasMediaItem] {
        let selected = Set(references.filter { $0.source == .bundled }.map(\.id))
        guard selected.contains(landscapesAlbumID) else { return [] }
        return landscapesPhotos.compactMap { photo in
            guard let url = url(for: photo.filename) else { return nil }
            let size = pixelSize(at: url)
            let item = CanvasMediaItem(
                id: "bundled:\(photo.id)",
                source: .bundled,
                kind: .photo,
                creationDate: photo.creationDate,
                filename: photo.filename,
                isFavorite: false,
                pixelWidth: size.width,
                pixelHeight: size.height,
                albumTitle: landscapesTitle,
                appleAsset: nil,
                localURL: url,
                contentHash: nil,
                libraryID: landscapesAlbumID
            )
            return filters.accepts(item.descriptor) ? item : nil
        }
    }

    private static func pixelSize(at url: URL) -> (width: Int, height: Int) {
        guard let image = UIImage(contentsOfFile: url.path) else { return (0, 0) }
        if let cgImage = image.cgImage {
            return (cgImage.width, cgImage.height)
        }
        return (Int(image.size.width * image.scale), Int(image.size.height * image.scale))
    }

    private static func date(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value) ?? .distantPast
    }
}

/// Resolves the same media pool that playback, Home previews, and Settings
/// previews use so a selected included album cannot vanish from one surface.
@MainActor
enum CanvasPlaybackMedia {
    static func items(
        for references: [AlbumReference],
        filters: CanvasFilters,
        apple: PhotoLibraryService,
        google: GooglePhotosService
    ) -> [CanvasMediaItem] {
        MediaIdentityMatcher.deduplicated(
            apple.mediaItems(for: references, filters: filters)
                + google.items(for: references, filters: filters)
                + BundledPhotoLibrary.items(for: references, filters: filters)
        )
    }
}

extension PhotoSource {
    var symbolName: String {
        switch self {
        case .bundled: "mountain.2.fill"
        case .applePhotos: "photo.stack.fill"
        case .googlePhotos: "g.circle.fill"
        }
    }

    var thumbnailSymbolName: String {
        switch self {
        case .bundled: "mountain.2.fill"
        case .applePhotos: "photo.on.rectangle"
        case .googlePhotos: "g.circle.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .bundled: .teal
        case .applePhotos: .orange
        case .googlePhotos: .blue
        }
    }
}
