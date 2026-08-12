import Foundation
import Photos
import SwiftUI

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

enum QueueMode: String, Codable, CaseIterable, Identifiable {
    case shuffle, albumOrder, oldestFirst, newestFirst, filename, favoritesFirst
    var id: String { rawValue }
    var title: String {
        switch self {
        case .shuffle: "Shuffle"
        case .albumOrder: "Album order"
        case .oldestFirst: "Oldest first"
        case .newestFirst: "Newest first"
        case .filename: "Filename"
        case .favoritesFirst: "Favorites first"
        }
    }
}

enum TransitionStyle: String, Codable, CaseIterable, Identifiable {
    case cut, crossfade, slideLeft, slideRight, slideUp, slideDown, push, zoomIn, zoomOut, kenBurns, blurDissolve, scaleFade, pageSwipe
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cut: "Cut"
        case .crossfade: "Crossfade"
        case .slideLeft: "Slide left"
        case .slideRight: "Slide right"
        case .slideUp: "Slide up"
        case .slideDown: "Slide down"
        case .push: "Push"
        case .zoomIn: "Zoom in"
        case .zoomOut: "Zoom out"
        case .kenBurns: "Ken Burns"
        case .blurDissolve: "Blur dissolve"
        case .scaleFade: "Scale & fade"
        case .pageSwipe: "Page swipe"
        }
    }
    var isReduceMotionSafe: Bool { self == .cut || self == .crossfade || self == .blurDissolve || self == .scaleFade }
}

enum LayoutStyle: String, Codable, CaseIterable, Identifiable {
    case automatic, single, fitBlurred, intelligentFill, solidBackground, pairHorizontal, pairVertical, portraitPair, collageThree, gridFour
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .single: "One photo"
        case .fitBlurred: "Fit with blurred fill"
        case .intelligentFill: "Intelligent fill"
        case .solidBackground: "Solid background"
        case .pairHorizontal: "Horizontal pair"
        case .pairVertical: "Vertical pair"
        case .portraitPair: "Smart portrait pair"
        case .collageThree: "Three-photo collage"
        case .gridFour: "Four-photo grid"
        }
    }
}

/// Controls how the foreground media is framed inside its tile. Fit with
/// border is the safe default: the complete original image stays visible and
/// any aspect-ratio space is supplied by Canvas's neutral/media backdrop.
enum MediaFramingMode: String, Codable, CaseIterable, Identifiable {
    case fitWithBorder
    case fillZoom

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fitWithBorder: "Fit with border"
        case .fillZoom: "Fill / zoom"
        }
    }

    var preservesEntireImage: Bool { self == .fitWithBorder }
}

enum MediaKind: String, Codable, CaseIterable, Identifiable {
    case photo, livePhoto, video
    var id: String { rawValue }
}

enum BackgroundAudioMode: String, Codable, CaseIterable, Identifiable {
    case none, localFiles
    var id: String { rawValue }
    var title: String { self == .none ? "None" : "Local audio files" }
}

enum PhotoSource: String, Codable, CaseIterable, Identifiable {
    case applePhotos, googlePhotos
    var id: String { rawValue }
    var title: String { self == .applePhotos ? "Apple Photos" : "Google Photos" }
}

struct AlbumReference: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let subtype: Int
    let estimatedCount: Int
    let isSmart: Bool
    let isShared: Bool
    let source: PhotoSource

    init(id: String, title: String, subtype: Int, estimatedCount: Int, isSmart: Bool, isShared: Bool, source: PhotoSource = .applePhotos) {
        self.id = id
        self.title = title
        self.subtype = subtype
        self.estimatedCount = estimatedCount
        self.isSmart = isSmart
        self.isShared = isShared
        self.source = source
    }

    private enum CodingKeys: String, CodingKey { case id, title, subtype, estimatedCount, isSmart, isShared, source }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        subtype = try container.decode(Int.self, forKey: .subtype)
        estimatedCount = try container.decode(Int.self, forKey: .estimatedCount)
        isSmart = try container.decode(Bool.self, forKey: .isSmart)
        isShared = try container.decode(Bool.self, forKey: .isShared)
        source = try container.decodeIfPresent(PhotoSource.self, forKey: .source) ?? .applePhotos
    }

    var localIdentifier: String { id }
}

struct GoogleMediaRecord: Codable, Hashable, Identifiable {
    let googleID: String
    let kind: MediaKind
    let creationDate: Date?
    let filename: String
    let pixelWidth: Int
    let pixelHeight: Int
    let relativePath: String
    let contentHash: String
    var id: String { "google:\(googleID)" }
}

struct GoogleAlbumRecord: Codable, Hashable, Identifiable {
    let id: String
    var title: String
    var items: [GoogleMediaRecord]
    var updatedAt: Date
    var matchedAppleAlbumID: String?

    var reference: AlbumReference {
        AlbumReference(id: id, title: title, subtype: 0, estimatedCount: items.count, isSmart: false, isShared: true, source: .googlePhotos)
    }
}

/// Computes the safe local cleanup for deleting one saved Canvas copy. A media
/// file remains on disk when another saved Google album still references its
/// Google ID or relative path.
struct GoogleAlbumDeletionPlan: Equatable {
    let remainingAlbums: [GoogleAlbumRecord]
    let removableRelativePaths: Set<String>

    static func removing(albumID: String, from albums: [GoogleAlbumRecord]) -> GoogleAlbumDeletionPlan? {
        guard let target = albums.first(where: { $0.id == albumID }) else { return nil }
        let remaining = albums.filter { $0.id != albumID }
        let remainingGoogleIDs = Set(remaining.flatMap { $0.items.map(\.googleID) })
        let remainingPaths = Set(remaining.flatMap { $0.items.map(\.relativePath) })
        let removable: Set<String> = Set(target.items.compactMap { item in
            guard !remainingGoogleIDs.contains(item.googleID), !remainingPaths.contains(item.relativePath) else { return nil }
            return item.relativePath
        })
        return GoogleAlbumDeletionPlan(remainingAlbums: remaining, removableRelativePaths: removable)
    }
}

/// Computes which files can be removed when an existing Google album is
/// refreshed.  A downloaded item may be referenced by more than one saved
/// Canvas album, so replacing one album must never remove a path still owned by
/// another album.
enum GoogleAlbumMediaCleanup {
    static func pathsNoLongerReferenced(
        replacing albumIndex: Int,
        with records: [GoogleMediaRecord],
        in albums: [GoogleAlbumRecord]
    ) -> Set<String> {
        guard albums.indices.contains(albumIndex) else { return [] }
        let oldPaths = Set(albums[albumIndex].items.map(\.relativePath))
        let incomingPaths = Set(records.map(\.relativePath))
        let otherAlbumPaths = Set(
            albums.enumerated()
                .filter { $0.offset != albumIndex }
                .flatMap { $0.element.items.map(\.relativePath) }
        )
        return oldPaths.subtracting(incomingPaths).subtracting(otherAlbumPaths)
    }
}

enum AlbumSelectionCleanup {
    static func removingGoogleAlbum(_ albumID: String, from references: [AlbumReference]) -> [AlbumReference] {
        references.filter { !($0.source == .googlePhotos && $0.id == albumID) }
    }

    /// Removes Google references whose saved local album record no longer
    /// exists. This repairs stale selections left behind by an older build or
    /// by deleting a saved Canvas copy while the app was not observing it.
    static func removingMissingGoogleAlbums(from references: [AlbumReference], validIDs: Set<String>) -> [AlbumReference] {
        references.filter { $0.source != .googlePhotos || validIDs.contains($0.id) }
    }
}

enum GoogleImportFailureCategory: String, CaseIterable, Equatable, Identifiable {
    case rateLimited
    case transientNetwork
    case authorization
    case accessDenied
    case notFound
    case processing
    case unsupported
    case invalidMedia
    case storage
    case unknown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rateLimited: "Google rate limit"
        case .transientNetwork: "Network interruption"
        case .authorization: "Google authorization"
        case .accessDenied: "Google access denied"
        case .notFound: "Media no longer available"
        case .processing: "Media still processing"
        case .unsupported: "Unsupported media"
        case .invalidMedia: "Invalid media response"
        case .storage: "Device storage"
        case .unknown: "Other download error"
        }
    }

    var guidance: String {
        switch self {
        case .rateLimited: "Google asked Canvas to slow down; retry unavailable items later."
        case .transientNetwork: "The connection interrupted the download; retry when the iPad is online."
        case .authorization: "Reconnect Google Photos before trying these items again."
        case .accessDenied: "Google did not allow Canvas to download these items from the selected source."
        case .notFound: "Google no longer returned these media files for this selection."
        case .processing: "Google is still processing some videos or motion media."
        case .unsupported: "Canvas can only save media types exposed by the Picker as photos or videos."
        case .invalidMedia: "Google returned media that Canvas could not read as a file."
        case .storage: "Free device storage or check Photos/Files permissions, then retry."
        case .unknown: "Canvas could not classify the download failure."
        }
    }
}

struct GoogleImportFailureSummary: Equatable, Identifiable {
    let category: GoogleImportFailureCategory
    let count: Int
    let example: String?

    var id: String { category.id }
}

struct GooglePhotosImportSummary: Equatable {
    let albumID: String
    let title: String
    let selectedCount: Int
    let savedCount: Int
    let skippedCount: Int
    let failureSummaries: [GoogleImportFailureSummary]
    let canRetryFailedItems: Bool
    let updatedExistingAlbum: Bool

    var itemCount: Int { savedCount }
    var isPartial: Bool { skippedCount > 0 }

    var message: String {
        let action = updatedExistingAlbum ? "updated" : "saved"
        let selectedText = "\(selectedCount) selected item\(selectedCount == 1 ? "" : "s")"
        let savedText = "\(savedCount) saved"
        if skippedCount > 0 {
            return "Google album \"\(title)\" \(action) \(savedText) of \(selectedText). \(skippedCount) item\(skippedCount == 1 ? " was" : " were") skipped and remain unavailable."
        }
        return "Google album \"\(title)\" \(action) all \(selectedText) and is selected for Canvas."
    }

    var statusTitle: String {
        if skippedCount > 0 { return "Google Photos import finished with unavailable items" }
        return "Google Photos selection is ready"
    }
}

struct CanvasMediaItem: Identifiable, Hashable {
    let id: String
    let source: PhotoSource
    let kind: MediaKind
    let creationDate: Date?
    let filename: String
    let isFavorite: Bool
    let pixelWidth: Int
    let pixelHeight: Int
    let albumTitle: String
    let appleAsset: PHAsset?
    let localURL: URL?
    let contentHash: String?
    /// Stable selected-library identity used to balance albums that happen
    /// to share the same display title.
    let libraryID: String?

    init(
        id: String,
        source: PhotoSource,
        kind: MediaKind,
        creationDate: Date?,
        filename: String,
        isFavorite: Bool,
        pixelWidth: Int,
        pixelHeight: Int,
        albumTitle: String,
        appleAsset: PHAsset?,
        localURL: URL?,
        contentHash: String?,
        libraryID: String? = nil
    ) {
        self.id = id
        self.source = source
        self.kind = kind
        self.creationDate = creationDate
        self.filename = filename
        self.isFavorite = isFavorite
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.albumTitle = albumTitle
        self.appleAsset = appleAsset
        self.localURL = localURL
        self.contentHash = contentHash
        self.libraryID = libraryID
    }

    static func == (lhs: CanvasMediaItem, rhs: CanvasMediaItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var descriptor: MediaDescriptor {
        MediaDescriptor(id: id, kind: kind, creationDate: creationDate, modificationDate: appleAsset?.modificationDate, filename: filename, isFavorite: isFavorite, pixelWidth: pixelWidth, pixelHeight: pixelHeight, albumTitles: [albumTitle], isScreenshot: appleAsset?.mediaSubtypes.contains(.photoScreenshot) == true, isBurst: appleAsset?.burstIdentifier != nil || appleAsset?.representsBurst == true, hasLocation: appleAsset?.location != nil)
    }

    /// Stable, provider-independent metadata key used when the same original is present in Apple and Google Photos.
    var crossSourceIdentity: String {
        let base = (filename as NSString).deletingPathExtension.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let timestamp = creationDate.map { Int($0.timeIntervalSince1970.rounded()) } ?? 0
        return "\(kind.rawValue)|\(base)|\(timestamp)|\(pixelWidth)x\(pixelHeight)"
    }
}

enum MediaIdentityMatcher {
    static func deduplicated(_ items: [CanvasMediaItem]) -> [CanvasMediaItem] {
        var providerIDs = Set<String>()
        var contentHashes = Set<String>()
        var crossSourceKeys: [String: PhotoSource] = [:]
        return items.filter { item in
            guard providerIDs.insert(item.id).inserted else { return false }
            if let hash = item.contentHash, !hash.isEmpty, !contentHashes.insert(hash).inserted { return false }
            let key = item.crossSourceIdentity
            if let existingSource = crossSourceKeys[key], existingSource != item.source { return false }
            crossSourceKeys[key] = item.source
            return true
        }
    }
}

struct MediaDescriptor: Hashable, Identifiable {
    let id: String
    let kind: MediaKind
    let creationDate: Date?
    let modificationDate: Date?
    let filename: String
    let isFavorite: Bool
    let pixelWidth: Int
    let pixelHeight: Int
    let albumTitles: [String]
    let isScreenshot: Bool
    let isBurst: Bool
    let hasLocation: Bool

    init(id: String, kind: MediaKind, creationDate: Date?, modificationDate: Date?, filename: String, isFavorite: Bool, pixelWidth: Int, pixelHeight: Int, albumTitles: [String], isScreenshot: Bool = false, isBurst: Bool = false, hasLocation: Bool = false) {
        self.id = id
        self.kind = kind
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.filename = filename
        self.isFavorite = isFavorite
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.albumTitles = albumTitles
        self.isScreenshot = isScreenshot
        self.isBurst = isBurst
        self.hasLocation = hasLocation
    }
}

struct CanvasFilters: Codable, Equatable {
    var includePhotos = true
    var includeLivePhotos = true
    var includeVideos = true
    var includeHidden = false
    var includeScreenshots = true
    var includeBursts = true
    var locationTaggedOnly = false
    var favoritesOnly = false
    var startDate: Date?
    var endDate: Date?
    var excludedAssetIDs: Set<String> = []

    func accepts(_ asset: MediaDescriptor) -> Bool {
        let legacyID = asset.id.hasPrefix("apple:") ? String(asset.id.dropFirst("apple:".count)) : asset.id
        guard !excludedAssetIDs.contains(asset.id), !excludedAssetIDs.contains(legacyID) else { return false }
        switch asset.kind {
        case .photo where !includePhotos, .livePhoto where !includeLivePhotos, .video where !includeVideos: return false
        default: break
        }
        if !includeScreenshots && asset.isScreenshot { return false }
        if !includeBursts && asset.isBurst { return false }
        if locationTaggedOnly && !asset.hasLocation { return false }
        if favoritesOnly && !asset.isFavorite { return false }
        if let startDate, let date = asset.creationDate, date < startDate { return false }
        if let endDate, let date = asset.creationDate, date > endDate { return false }
        return true
    }
}

struct CanvasSettings: Codable, Equatable {
    var selectedAlbums: [AlbumReference] = []
    /// Optional so settings written before the album-picker visibility control
    /// continue to decode. Missing values use the default: hide empty albums.
    var showEmptyAlbums: Bool? = false
    var queueMode: QueueMode = .shuffle
    var repeatEnabled = true
    var shuffleEachLoop = false
    var recentAvoidance = 0
    var photoDuration: Double = 10
    var livePhotoDuration: Double = 10
    var videoDuration: Double = 60
    var playFullVideo = false
    var loopLivePhotos = false
    var videoMuted = true
    var videoVolume: Double = 1
    var transition: TransitionStyle = .crossfade
    var transitionDuration: Double = 1
    var randomTransitions = false
    var excludedTransitions: Set<TransitionStyle> = []
    var layout: LayoutStyle = .automatic
    // Retained only to decode the original Fit image toggle. Current settings
    // use framingMode, whose safe default preserves the complete image.
    var fitMode = false
    /// Optional for backward-compatible decoding. New and migrated settings
    /// use Fit with border; the legacy boolean remains readable for older
    /// presets/settings.
    var framingMode: MediaFramingMode? = .fitWithBorder
    var backgroundHex = "#151513"
    var blurBackground = true
    var spacing: Double = 8
    var cornerRadius: Double = 18
    var overlays = OverlaySettings()
    var filters = CanvasFilters()
    var keepAwake = true
    var chargingOnly = false
    var lowBatteryStop = 10
    /// Optional for settings saved before Canvas offered a standalone
    /// overnight low-light mode. Missing values adopt the automatic 10 PM–7
    /// AM schedule without changing system brightness.
    var automaticNightDimmingEnabled: Bool? = true
    var nightDimmingStartMinutes: Int? = 22 * 60
    var nightDimmingStopMinutes: Int? = 7 * 60
    var controlAutoHide: Double = 4
    var lockControls = false
    var backgroundAudio: BackgroundAudioMode = .none
    var audioVolume: Double = 0.7
    var audioShuffle = false
    var audioRepeat = true
    var audioFileURLs: [URL] = []
    var schedules: [ScheduleRule] = []
    var appearanceMode: AppearanceMode = .system
    var hasCompletedOnboarding = false
    /// Optional so settings written by older builds decode unchanged. When
    /// absent, the album picker uses AppleAlbumCategory's stable default order.
    var albumCategoryOrder: [String]? = nil
    var presets: [CanvasPreset] = []

    var effectiveFramingMode: MediaFramingMode {
        framingMode ?? (fitMode ? .fitWithBorder : .fillZoom)
    }

    var effectiveShowEmptyAlbums: Bool { showEmptyAlbums ?? false }
    var effectiveAutomaticNightDimmingEnabled: Bool { automaticNightDimmingEnabled ?? true }
    var effectiveNightDimmingStartMinutes: Int { min(max(nightDimmingStartMinutes ?? 22 * 60, 0), 24 * 60 - 1) }
    var effectiveNightDimmingStopMinutes: Int { min(max(nightDimmingStopMinutes ?? 7 * 60, 0), 24 * 60 - 1) }
}

struct OverlaySettings: Codable, Equatable {
    var showTime = false
    var showDate = false
    var showWeekday = false
    var showCaptureDate = false
    /// Optional so older settings decode. A fixed style keeps every capture
    /// date badge visually consistent and is independent of Adaptive clock
    /// color.
    var captureDateStyle: CaptureDateBadgeStyle?
    var showAlbum = false
    var showLocation = false
    var showCaption = false
    var showItemCount = false
    var showBattery = false
    var showWeather = false
    /// Weather detail choices are optional so settings and presets written by
    /// earlier builds decode without losing any of their existing overlay
    /// configuration. The compact default intentionally shows only the two
    /// most glanceable pieces of information.
    var weatherShowConditions: Bool? = true
    var weatherShowAirQuality: Bool? = true
    var weatherShowFeelsLike: Bool? = false
    var weatherShowHumidity: Bool? = false
    var weatherShowWind: Bool? = false
    var weatherShowUVIndex: Bool? = false
    var weatherShowPrecipitationChance: Bool? = false
    var weatherShowDailyHighLow: Bool? = false
    var weatherShowSunriseSunset: Bool? = false
    var weatherShowNextHour: Bool? = false
    var alwaysVisible = false
    var position: OverlayPosition = .bottomLeading
    var opacity: Double = 0.9
    /// Optional so settings written by older builds continue to decode. This
    /// is the percentage of the backing that should be transparent/glass,
    /// independent of the backing opacity and clock/text opacity.
    var backgroundTransparency: Double?
    var fontSize: Double = 22
    /// Optional so existing settings retain the current long-form date while
    /// newer builds can offer the common date styles without rewriting saved
    /// settings.
    var dateFormat: OverlayDateFormat? = .long
    /// Supporting overlay labels (date, battery, album, and so on) have a
    /// separate weight from the clock. The optional field preserves older
    /// settings that did not have a supporting-text weight.
    var textWeight: ClockWeight? = .regular
    // Optional for backward-compatible decoding of existing saved settings.
    var clockSize: Double?
    var clockWeight: ClockWeight?
    var clockWidth: ClockWidth?
    var clockOpacity: Double?
    var clockFont: ClockFont?
    var clockColor: ClockColor?
    var clockStyle: ClockStyle?
    var analogClockFace: AnalogClockFace?
    /// Optional for backward-compatible decoding. When enabled, this outline
    /// is shared by the clock and the supporting overlay text.
    var textStrokeEnabled: Bool?
    var textStrokeColor: ClockColor?
    var textStrokeWidth: Double?
    /// Clock stroke settings are now independent from supporting overlay text.
    /// They fall back to the older shared text-stroke values until a user
    /// explicitly chooses a clock-specific value.
    var clockStrokeEnabled: Bool? = false
    var clockStrokeColor: ClockColor? = .black
    var clockStrokeWidth: Double? = 1.5
    /// Kept for decoding older presets. The UI now uses one neutral backing
    /// style and exposes continuous opacity/transparency controls instead of
    /// confusing material presets.
    var material: OverlayMaterial = .ultraThin

    var effectiveDateFormat: OverlayDateFormat { dateFormat ?? .long }
    var effectiveTextWeight: ClockWeight { textWeight ?? .regular }
    var effectiveClockStrokeEnabled: Bool { clockStrokeEnabled ?? textStrokeEnabled ?? false }
    var effectiveClockStrokeColor: ClockColor { clockStrokeColor ?? textStrokeColor ?? .black }
    var effectiveClockStrokeWidth: Double { clockStrokeWidth ?? textStrokeWidth ?? 1.5 }
    var effectiveWeatherShowConditions: Bool { weatherShowConditions ?? true }
    var effectiveWeatherShowAirQuality: Bool { weatherShowAirQuality ?? true }
    var effectiveWeatherShowFeelsLike: Bool { weatherShowFeelsLike ?? false }
    var effectiveWeatherShowHumidity: Bool { weatherShowHumidity ?? false }
    var effectiveWeatherShowWind: Bool { weatherShowWind ?? false }
    var effectiveWeatherShowUVIndex: Bool { weatherShowUVIndex ?? false }
    var effectiveWeatherShowPrecipitationChance: Bool { weatherShowPrecipitationChance ?? false }
    var effectiveWeatherShowDailyHighLow: Bool { weatherShowDailyHighLow ?? false }
    var effectiveWeatherShowSunriseSunset: Bool { weatherShowSunriseSunset ?? false }
    var effectiveWeatherShowNextHour: Bool { weatherShowNextHour ?? false }

    /// Converts settings written before clock and supporting-text strokes were
    /// separated. The old shared stroke remains visually unchanged once, then
    /// later edits stay independent.
    @discardableResult
    mutating func migrateLegacySharedStroke() -> Bool {
        var changed = false
        if clockStrokeEnabled == nil {
            clockStrokeEnabled = textStrokeEnabled ?? false
            changed = true
        }
        if clockStrokeColor == nil {
            clockStrokeColor = textStrokeColor ?? .black
            changed = true
        }
        if clockStrokeWidth == nil {
            clockStrokeWidth = textStrokeWidth ?? 1.5
            changed = true
        }
        return changed
    }
}

enum CaptureDateBadgeStyle: String, Codable, CaseIterable, Identifiable {
    case darkBadgeLightText
    case lightBadgeDarkText

    var id: String { rawValue }
    var title: String {
        switch self {
        case .darkBadgeLightText: "Dark badge / light text"
        case .lightBadgeDarkText: "Light badge / dark text"
        }
    }
}

enum OverlayDateFormat: String, Codable, CaseIterable, Identifiable {
    case short
    case medium
    case long
    case full
    case numbersOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .short: "Short"
        case .medium: "Medium"
        case .long: "Long"
        case .full: "Full"
        case .numbersOnly: "Numbers only"
        }
    }

    /// Uses the user's locale for the four standard styles. The numbers-only
    /// option keeps the locale's ordering and separators while omitting all
    /// month names and weekday text.
    func string(from date: Date, locale: Locale = .current, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeStyle = .none

        switch self {
        case .short:
            formatter.dateStyle = .short
        case .medium:
            formatter.dateStyle = .medium
        case .long:
            formatter.dateStyle = .long
        case .full:
            formatter.dateStyle = .full
        case .numbersOnly:
            formatter.dateStyle = .none
            formatter.setLocalizedDateFormatFromTemplate("yMd")
        }

        return formatter.string(from: date)
    }
}

enum OverlayPosition: String, Codable, CaseIterable, Identifiable { case topLeading, topTrailing, bottomLeading, bottomTrailing, center; var id: String { rawValue } }
enum OverlayMaterial: String, Codable, CaseIterable, Identifiable { case none, thin, regular, thick, ultraThin; var id: String { rawValue } }
enum ClockWeight: String, Codable, CaseIterable, Identifiable {
    case regular, medium, semibold, bold
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var fontWeight: Font.Weight { switch self { case .regular: .regular; case .medium: .medium; case .semibold: .semibold; case .bold: .bold } }
}
enum ClockWidth: String, Codable, CaseIterable, Identifiable {
    case compressed, standard, expanded
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var fontWidth: Font.Width { switch self { case .compressed: .compressed; case .standard: .standard; case .expanded: .expanded } }
}

enum ClockFont: String, Codable, CaseIterable, Identifiable {
    case system, rounded, serif, monospaced
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .rounded: "Rounded"
        case .serif: "Serif"
        case .monospaced: "Monospaced"
        }
    }
    var design: Font.Design {
        switch self {
        case .system: .default
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
    }
}

enum ClockColor: String, Codable, CaseIterable, Identifiable {
    case adaptive
    case black
    case white, warmWhite, orange, mint, cyan
    case gray, amber, red, green, blue, purple
    var id: String { rawValue }
    var title: String {
        switch self {
        case .adaptive: "Adaptive"
        case .black: "Black"
        case .white: "White"
        case .warmWhite: "Warm white"
        case .orange: "Orange"
        case .mint: "Mint"
        case .cyan: "Cyan"
        case .gray: "Gray"
        case .amber: "Amber"
        case .red: "Red"
        case .green: "Green"
        case .blue: "Blue"
        case .purple: "Purple"
        }
    }
    var color: Color {
        switch self {
        case .adaptive: .white
        case .black: .black
        case .white: .white
        case .warmWhite: Color(red: 1.0, green: 0.93, blue: 0.82)
        case .orange: .orange
        case .mint: .mint
        case .cyan: .cyan
        case .gray: .gray
        case .amber: Color(red: 1.0, green: 0.67, blue: 0.12)
        case .red: .red
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        }
    }
    var isAdaptive: Bool { self == .adaptive }
}

enum ClockStyle: String, Codable, CaseIterable, Identifiable {
    case digital, analog
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum AnalogClockFace: String, Codable, CaseIterable, Identifiable {
    case arabic, roman, dashes
    var id: String { rawValue }
    var title: String {
        switch self {
        case .arabic: "Arabic numerals"
        case .roman: "Roman numerals"
        case .dashes: "Dash markers"
        }
    }
}

extension OverlayMaterial {
    @ViewBuilder
    func backgroundView(cornerRadius: CGFloat, opacity: Double, transparency: Double = 0) -> some View {
        let clampedOpacity = OverlayBackgroundPolicy.effectiveOpacity(opacity: opacity, transparency: transparency)
        switch self {
        case .none:
            RoundedRectangle(cornerRadius: cornerRadius).fill(.clear)
        case .thin:
            RoundedRectangle(cornerRadius: cornerRadius).fill(.thinMaterial).opacity(clampedOpacity)
        case .regular:
            RoundedRectangle(cornerRadius: cornerRadius).fill(.regularMaterial).opacity(clampedOpacity)
        case .thick:
            RoundedRectangle(cornerRadius: cornerRadius).fill(.thickMaterial).opacity(clampedOpacity)
        case .ultraThin:
            RoundedRectangle(cornerRadius: cornerRadius).fill(.ultraThinMaterial).opacity(clampedOpacity)
        }
    }
}

struct CanvasPreset: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var settings: CanvasSettings
}

/// Applies a saved preset without deleting the preset library itself. Preset
/// snapshots deliberately omit their own `presets` array so restoring one does
/// not recursively duplicate every saved preset; the current library must be
/// carried across explicitly when the snapshot is applied.
enum PresetApplication {
    static func settings(for preset: CanvasPreset, preserving currentPresets: [CanvasPreset]) -> CanvasSettings {
        var restored = preset.settings
        restored.presets = currentPresets
        return restored
    }
}

enum PresetSaveError: Error, Equatable {
    case emptyName
    case duplicateName
}

/// Validates and appends a preset snapshot without recursively embedding the
/// preset library. Names are trimmed and compared case-insensitively so a
/// save can never silently create an indistinguishable duplicate.
enum PresetSavePolicy {
    static func append(
        name: String,
        snapshot: CanvasSettings,
        to presets: [CanvasPreset]
    ) -> Result<[CanvasPreset], PresetSaveError> {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return .failure(.emptyName) }
        guard !presets.contains(where: { $0.name.caseInsensitiveCompare(normalizedName) == .orderedSame }) else {
            return .failure(.duplicateName)
        }

        var snapshot = snapshot
        snapshot.presets = []
        return .success(presets + [CanvasPreset(name: normalizedName, settings: snapshot)])
    }
}

struct ScheduleRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "Evening frame"
    var weekdays: Set<Int> = Set(1...7)
    var startMinutes = 18 * 60
    var stopMinutes = 7 * 60
    var dimsAtNight = true
    var blackSleepScreen = false
}
