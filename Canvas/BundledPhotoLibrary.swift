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

struct BundledAlbumCatalog: Hashable, Identifiable {
    let id: String
    let title: String
    let directory: String
    let photos: [BundledPhotoRecord]

    var albumID: String { "bundled:\(id)" }

    var reference: AlbumReference {
        AlbumReference(
            id: albumID,
            title: title,
            subtype: 0,
            estimatedCount: photos.count,
            isSmart: false,
            isShared: false,
            source: .bundled
        )
    }
}

/// Public-domain themed albums that ship with Canvas, similar to a Nest Hub
/// default library. They are available without Photos or Google authorization
/// so a new install can start a frame immediately.
enum BundledPhotoLibrary {
    static let landscapesAlbumID = "bundled:landscapes"
    static let cityscapesAlbumID = "bundled:cityscapes"
    static let abstractAlbumID = "bundled:abstract"
    static let landscapesTitle = "Landscapes"

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

    static let cityscapesPhotos: [BundledPhotoRecord] = [
        BundledPhotoRecord(id: "gateway-arch", filename: "gateway-arch.jpg", title: "Gateway Arch", credit: "National Park Service, Gateway Arch National Park", creationDate: nil),
        BundledPhotoRecord(id: "national-mall", filename: "national-mall.jpg", title: "National Mall", credit: "NPS staff, National Mall and Memorial Parks", creationDate: nil),
        BundledPhotoRecord(id: "independence-hall", filename: "independence-hall.jpg", title: "Independence Hall", credit: "National Park Service, Independence National Historical Park", creationDate: date("2004-04-01")),
        BundledPhotoRecord(id: "golden-gate", filename: "golden-gate.jpg", title: "Golden Gate Bridge", credit: "NASA / Expedition 64, International Space Station", creationDate: date("2021-04-04")),
        BundledPhotoRecord(id: "chicago-night", filename: "chicago-night.jpg", title: "Chicago at night", credit: "NASA / Expedition 7, International Space Station", creationDate: date("2003-10-07")),
        BundledPhotoRecord(id: "los-angeles-night", filename: "los-angeles-night.jpg", title: "Los Angeles at night", credit: "NASA / Reid Wiseman, Expedition 40", creationDate: date("2014-07-21")),
        BundledPhotoRecord(id: "san-francisco-night", filename: "san-francisco-night.jpg", title: "San Francisco at night", credit: "NASA / Expedition 40, International Space Station", creationDate: date("2014-07-19")),
        BundledPhotoRecord(id: "tokyo-night", filename: "tokyo-night.jpg", title: "Tokyo at night", credit: "NASA / Expedition 40, International Space Station", creationDate: date("2014-07-19")),
        BundledPhotoRecord(id: "montreal-night", filename: "montreal-night.jpg", title: "Montreal at night", credit: "NASA / Expedition 26, International Space Station", creationDate: date("2010-12-24"))
    ]

    static let abstractPhotos: [BundledPhotoRecord] = [
        BundledPhotoRecord(id: "cosmic-cliffs", filename: "cosmic-cliffs.jpg", title: "Cosmic Cliffs", credit: "NASA, ESA, CSA, STScI / James Webb Space Telescope", creationDate: date("2022-07-12")),
        BundledPhotoRecord(id: "webb-deep-field", filename: "webb-deep-field.jpg", title: "Webb First Deep Field", credit: "NASA, ESA, CSA, STScI / James Webb Space Telescope", creationDate: date("2022-07-12")),
        BundledPhotoRecord(id: "pillars-of-creation", filename: "pillars-of-creation.jpg", title: "Pillars of Creation", credit: "NASA, ESA, and the Hubble Heritage Team (STScI/AURA)", creationDate: date("2015-01-06")),
        BundledPhotoRecord(id: "lagoon-nebula", filename: "lagoon-nebula.jpg", title: "Lagoon Nebula", credit: "NASA / ESA / Hubble", creationDate: nil),
        BundledPhotoRecord(id: "crab-nebula", filename: "crab-nebula.jpg", title: "Crab Nebula", credit: "NASA / ESA / JPL-Caltech / Hubble", creationDate: nil),
        BundledPhotoRecord(id: "antennae-galaxies", filename: "antennae-galaxies.jpg", title: "Antennae Galaxies", credit: "NASA / ESA / Hubble", creationDate: nil),
        BundledPhotoRecord(id: "whirlpool-galaxy", filename: "whirlpool-galaxy.jpg", title: "Whirlpool Galaxy", credit: "NASA / ESA / Hubble / JPL-Caltech", creationDate: nil),
        BundledPhotoRecord(id: "van-gogh-from-space", filename: "van-gogh-from-space.jpg", title: "Van Gogh from Space", credit: "NASA Earth Observatory / GSFC", creationDate: nil),
        BundledPhotoRecord(id: "akpatok-island", filename: "akpatok-island.jpg", title: "Akpatok Island", credit: "NASA Earth Observatory / GSFC", creationDate: nil)
    ]

    static let catalogs: [BundledAlbumCatalog] = [
        BundledAlbumCatalog(id: "landscapes", title: landscapesTitle, directory: "Landscapes", photos: landscapesPhotos),
        BundledAlbumCatalog(id: "cityscapes", title: "Cityscapes", directory: "Cityscapes", photos: cityscapesPhotos),
        BundledAlbumCatalog(id: "abstract", title: "Abstract", directory: "Abstract", photos: abstractPhotos)
    ]

    static var albums: [AlbumReference] { catalogs.map(\.reference) }

    static var landscapesAlbum: AlbumReference { catalogs[0].reference }
    static var cityscapesAlbum: AlbumReference { catalogs[1].reference }
    static var abstractAlbum: AlbumReference { catalogs[2].reference }

    static func url(for filename: String, in directory: String) -> URL? {
        let name = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        return resourceBundle.url(forResource: name, withExtension: ext, subdirectory: "IncludedAlbums/\(directory)")
            ?? resourceBundle.url(forResource: name, withExtension: ext, subdirectory: directory)
            ?? resourceBundle.url(forResource: name, withExtension: ext)
    }

    static func url(for filename: String) -> URL? {
        url(for: filename, in: "Landscapes")
    }

    static func items(for references: [AlbumReference], filters: CanvasFilters) -> [CanvasMediaItem] {
        let selected = Set(references.filter { $0.source == .bundled }.map(\.id))
        guard selected.isEmpty == false else { return [] }
        return catalogs.flatMap { catalog -> [CanvasMediaItem] in
            guard selected.contains(catalog.albumID) else { return [] }
            return catalog.photos.compactMap { photo in
                guard let url = url(for: photo.filename, in: catalog.directory) else { return nil }
                let size = pixelSize(at: url)
                let item = CanvasMediaItem(
                    id: "bundled:\(catalog.id):\(photo.id)",
                    source: .bundled,
                    kind: .photo,
                    creationDate: photo.creationDate,
                    filename: photo.filename,
                    isFavorite: false,
                    pixelWidth: size.width,
                    pixelHeight: size.height,
                    albumTitle: catalog.title,
                    appleAsset: nil,
                    localURL: url,
                    contentHash: nil,
                    libraryID: catalog.albumID
                )
                return filters.accepts(item.descriptor) ? item : nil
            }
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
