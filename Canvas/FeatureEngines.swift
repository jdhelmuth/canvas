import Foundation
import Photos
import UIKit

struct QueueAlgorithm {
    static func orderedIDs(_ ids: [String], mode: QueueMode, favorites: Set<String> = [], dates: [String: Date] = [:], filenames: [String: String] = [:], seed: UInt64 = 1) -> [String] {
        var result = ids
        switch mode {
        case .shuffle:
            var generator = SeededGenerator(seed: seed)
            result.shuffle(using: &generator)
        case .albumOrder: break
        case .oldestFirst: result.sort { (dates[$0] ?? .distantPast) < (dates[$1] ?? .distantPast) }
        case .newestFirst: result.sort { (dates[$0] ?? .distantPast) > (dates[$1] ?? .distantPast) }
        case .filename: result.sort { (filenames[$0] ?? "").localizedCaseInsensitiveCompare(filenames[$1] ?? "") == .orderedAscending }
        case .favoritesFirst: result.sort { favorites.contains($0) && !favorites.contains($1) }
        }
        return result
    }

    static func applyingRecentAvoidance(_ ids: [String], previous: [String], count: Int) -> [String] {
        guard count > 0 else { return ids }
        let recent = Set(previous.suffix(count))
        return ids.filter { !recent.contains($0) } + ids.filter { recent.contains($0) }
    }
}

/// Decides whether the home action can enter playback without relying on a
/// thumbnail task or on the Google connection state. Apple Photos, Google
/// Photos, and the included themed albums feed the same queue, so this
/// check uses the deduplicated media list.
enum FrameLaunchPolicy {
    enum Decision: Equatable {
        case ready
        case needsSelection

        var hasPlayableMedia: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    static func decision(for items: [CanvasMediaItem]) -> Decision {
        hasPlayableMedia(items) ? .ready : .needsSelection
    }

    static func hasPlayableMedia(_ items: [CanvasMediaItem]) -> Bool {
        !MediaIdentityMatcher.deduplicated(items).isEmpty
    }

    static func canStart(isPresented: Bool, isStarting: Bool) -> Bool {
        !isPresented && !isStarting
    }
}

/// Describes the source used for the frame's behind-media treatment. Keeping
/// this decision independent from SwiftUI makes it testable and ensures every
/// media type follows the same neutral fallback when there is no usable frame.
enum MediaBackdropMode: Equatable {
    case mediaDerived
    case neutral
}

enum MediaBackdropResolver {
    static func mode(imageCount: Int, blurredBackground: Bool) -> MediaBackdropMode {
        imageCount > 0 && blurredBackground ? .mediaDerived : .neutral
    }
}

/// Converts one completed horizontal drag into one, and only one, navigation
/// command. Keeping this decision pure makes it easy to test and prevents
/// translation updates from being interpreted as multiple swipes.
enum SwipeNavigation {
    static func direction(for translation: CGSize, minimumDistance: CGFloat = 40) -> Int? {
        guard abs(translation.width) >= minimumDistance,
              abs(translation.width) > abs(translation.height) else { return nil }
        return translation.width < 0 ? 1 : -1
    }
}

/// The transition state produced by one completed horizontal gesture. Keeping
/// this separate from the queue index makes the directional animation
/// deterministic and lets grouped navigation move a whole displayed pair.
enum SwipeTransitionState: Equatable {
    case automatic
    case forward
    case backward

    static func from(direction: Int) -> SwipeTransitionState {
        if direction > 0 { return .forward }
        if direction < 0 { return .backward }
        return .automatic
    }
}

/// Pinch zoom is an interaction layered on top of the selected framing mode.
/// Its resting value must stay exactly at one so Fill / zoom remains the
/// minimum-cover transform calculated by `MediaFramingGeometry`, rather than
/// retaining an extra multiplier when a gesture is cancelled by a slide
/// transition.
enum InteractivePhotoZoomPolicy {
    static let restingScale: CGFloat = 1
    static let maximumScale: CGFloat = 4

    static func scale(for magnification: CGFloat) -> CGFloat {
        min(max(magnification, restingScale), maximumScale)
    }
}

/// Pure timing rules for slideshow controls. Keeping the gate and expiration
/// decision outside SwiftUI makes the inactivity behavior deterministic and
/// prevents a blocked/paused frame from hiding its recovery controls.
enum ControlsAutoHidePolicy {
    static func shouldSchedule(alwaysVisible: Bool, playbackAllowed: Bool, delay: Double) -> Bool {
        !alwaysVisible && playbackAllowed && delay > 0
    }

    static func isExpired(now: Date, startedAt: Date, delay: Double) -> Bool {
        delay > 0 && now.timeIntervalSince(startedAt) >= delay
    }
}

/// Keeps persisted timing values from turning a frame into a zero-duration
/// loop. Photo and Live Photo durations are always positive; video keeps its
/// existing zero-value "unlimited" meaning. The timer uses these same rules
/// at runtime so a legacy or externally edited settings record cannot make
/// the slideshow advance continuously.
enum PlaybackTimingPolicy {
    static let defaultPhotoDuration: Double = 10
    static let defaultLivePhotoDuration: Double = 10
    static let defaultVideoDuration: Double = 60
    static let defaultTransitionDuration: Double = 1
    static let minimumDuration: Double = 1

    static func normalizedPhotoDuration(_ value: Double) -> Double {
        normalizedPositive(value, fallback: defaultPhotoDuration)
    }

    static func normalizedLivePhotoDuration(_ value: Double) -> Double {
        normalizedPositive(value, fallback: defaultLivePhotoDuration)
    }

    static func normalizedVideoDuration(_ value: Double) -> Double {
        guard value.isFinite else { return defaultVideoDuration }
        guard value > 0 else { return 0 }
        return max(value, minimumDuration)
    }

    static func normalizedTransitionDuration(_ value: Double) -> Double {
        guard value.isFinite else { return defaultTransitionDuration }
        return max(0, value)
    }

    static func duration(
        for kind: MediaKind,
        settings: CanvasSettings,
        mediaDuration: Double
    ) -> Double {
        switch kind {
        case .video:
            let validMediaDuration = mediaDuration.isFinite && mediaDuration > 0 ? mediaDuration : 0
            if (settings.playFullVideo || settings.videoDuration <= 0), validMediaDuration > 0 {
                return validMediaDuration
            }
            return max(normalizedVideoDuration(settings.videoDuration), minimumDuration)
        case .livePhoto:
            return normalizedLivePhotoDuration(settings.livePhotoDuration)
        case .photo:
            return normalizedPhotoDuration(settings.photoDuration)
        }
    }

    private static func normalizedPositive(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite, value > 0 else { return fallback }
        return max(value, minimumDuration)
    }
}

enum CaptureDateOverlayPolicy {
    static func visibleDates(_ dates: [Date?], enabled: Bool) -> [Date?] {
        enabled ? dates : dates.map { _ in nil }
    }

    /// Video and Live Photo surfaces own their single capture-date layer. The
    /// outer player overlay is reserved for still-image/loading surfaces so a
    /// UIKit-backed media view cannot receive the same badge twice.
    static func mediaSurfaceOwnsDate(for kind: MediaKind?) -> Bool {
        kind == .video || kind == .livePhoto
    }

    static func showsStandaloneDate(enabled: Bool, kind: MediaKind?, layoutImagesEmpty: Bool) -> Bool {
        enabled && !mediaSurfaceOwnsDate(for: kind) && layoutImagesEmpty
    }
}

/// Keeps the two overlay opacity controls independent: the general value is
/// applied only to the material backing, while Clock Opacity is the text
/// opacity used by the clock and supporting overlay labels.
struct OverlayOpacityValues: Equatable {
    let background: Double
    let text: Double
}

/// Keeps text outlines predictable across the live overlay and its settings
/// preview. The optional fields are intentional: older persisted settings do
/// not contain stroke keys and therefore continue with the outline disabled.
enum OverlayTextStrokePolicy {
    static let defaultWidth = 1.5
    static let minimumWidth = 0.5
    static let maximumWidth = 6.0

    static func isEnabled(_ enabled: Bool?) -> Bool { enabled ?? false }

    static func width(_ value: Double?) -> CGFloat {
        CGFloat(min(max(value ?? defaultWidth, minimumWidth), maximumWidth))
    }

    static func color(_ configured: ClockColor?, mediaImage: UIImage?) -> ClockColor {
        let selected = configured ?? .black
        return selected.isAdaptive ? AdaptiveClockColorResolver.color(for: mediaImage) : selected
    }
}

enum OverlayOpacityPolicy {
    static func values(backgroundOpacity: Double, clockOpacity: Double?) -> OverlayOpacityValues {
        OverlayOpacityValues(
            background: min(max(backgroundOpacity, 0), 1),
            text: min(max(clockOpacity ?? 0.95, 0), 1)
        )
    }
}

/// Converts the two user-facing backing controls into the effective material
/// opacity used by the renderer. Overlay opacity is the backing's maximum
/// alpha; transparency independently removes that backing to create the
/// continuous glass effect. Clock/text opacity is deliberately not involved.
enum OverlayBackgroundPolicy {
    static let defaultTransparency = 0.0

    static func effectiveOpacity(opacity: Double, transparency: Double?) -> Double {
        let clampedOpacity = min(max(opacity, 0), 1)
        let clampedTransparency = min(max(transparency ?? defaultTransparency, 0), 1)
        return clampedOpacity * (1 - clampedTransparency)
    }
}

/// Keeps the Apple album source section understandable without relying on
/// localized titles or private Photos metadata. Smart collections and shared
/// collections are explicit; regular user albums remain separate from other
/// system/special collections that Photos may expose on a particular device.
enum AppleAlbumCategory: String, CaseIterable, Identifiable {
    case smart, user, shared, other

    var id: String { rawValue }
    var title: String {
        switch self {
        case .smart: "Smart Albums"
        case .user: "My Albums"
        case .shared: "Shared"
        case .other: "Other & System"
        }
    }

    static func category(for album: AlbumReference) -> AppleAlbumCategory {
        guard album.source == .applePhotos else { return .other }
        if album.isSmart { return .smart }
        if album.isShared || album.subtype == Int(PHAssetCollectionSubtype.albumCloudShared.rawValue) { return .shared }
        if album.subtype == Int(PHAssetCollectionSubtype.albumRegular.rawValue) { return .user }
        return .other
    }

    static func albums(from albums: [AlbumReference], in category: AppleAlbumCategory) -> [AlbumReference] {
        albums.filter { self.category(for: $0) == category }
    }
}

/// Controls whether the album picker includes collections that currently have
/// no PhotoKit or downloaded Google media items.
enum AlbumVisibilityPolicy {
    static func visible(_ albums: [AlbumReference], showEmptyAlbums: Bool) -> [AlbumReference] {
        showEmptyAlbums ? albums : albums.filter { $0.estimatedCount > 0 }
    }
}

/// Persists category identifiers rather than enum positions so adding a new
/// category in a later build does not discard an existing user's order. Unknown
/// identifiers are retained in the stored array and known categories missing
/// from older settings are appended in the default order.
enum AppleAlbumCategoryOrdering {
    static let defaultCategories: [AppleAlbumCategory] = [.smart, .user, .shared, .other]
    static var defaultIdentifiers: [String] { defaultCategories.map(\.rawValue) }

    static func normalizedIdentifiers(from stored: [String]?) -> [String] {
        let values = stored ?? []
        var seenKnown = Set<AppleAlbumCategory>()
        var result: [String] = []
        for identifier in values {
            if let category = AppleAlbumCategory(rawValue: identifier) {
                guard seenKnown.insert(category).inserted else { continue }
            }
            result.append(identifier)
        }
        for category in defaultCategories where !seenKnown.contains(category) {
            result.append(category.rawValue)
        }
        return result
    }

    static func categories(from stored: [String]?) -> [AppleAlbumCategory] {
        normalizedIdentifiers(from: stored).compactMap(AppleAlbumCategory.init(rawValue:))
    }

    static func moving(fromOffsets offsets: IndexSet, toOffset destination: Int, in stored: [String]?) -> [String] {
        var normalized = normalizedIdentifiers(from: stored)
        let knownSlots = normalized.indices.filter { AppleAlbumCategory(rawValue: normalized[$0]) != nil }
        var categories = knownSlots.map { AppleAlbumCategory(rawValue: normalized[$0])! }
        categories.move(fromOffsets: offsets, toOffset: destination)
        for (slot, category) in zip(knownSlots, categories) {
            normalized[slot] = category.rawValue
        }
        return normalized
    }
}

/// Adaptive clock color is intentionally a two-choice contrast decision. It
/// uses a tiny local luminance sample, never image upload or cloud metadata,
/// and is applied only to the single shared clock layer.
enum AdaptiveClockColorResolver {
    static func color(forLuminance luminance: CGFloat) -> ClockColor {
        luminance >= 0.58 ? .black : .white
    }

    static func colors(forLuminances luminances: [CGFloat]) -> [ClockColor] {
        luminances.map(color(forLuminance:))
    }

    static func color(for image: UIImage?) -> ClockColor {
        guard let image else { return .white }
        return color(forLuminance: CaptureDateContrastResolver.luminance(of: image))
    }
}

/// The slideshow owns one clock layer for the whole displayed frame. Adaptive
/// color samples a representative image for that layer; it never creates a
/// clock per tile. Keeping the render plan pure makes the single-layer rule
/// regression-testable without requiring a device UI run.
struct ClockOverlayRenderPlan: Equatable {
    let sharedClockCount: Int
    let perTileClockCounts: [Int]
    let adaptiveColorUsesRepresentativeImage: Bool

    var totalClockCount: Int {
        sharedClockCount + perTileClockCounts.reduce(0, +)
    }
}

enum ClockOverlayPlacementPolicy {
    static func plan(showTime: Bool, color: ClockColor?, visibleTileCount: Int) -> ClockOverlayRenderPlan {
        ClockOverlayRenderPlan(
            sharedClockCount: showTime ? 1 : 0,
            perTileClockCounts: Array(repeating: 0, count: max(0, visibleTileCount)),
            adaptiveColorUsesRepresentativeImage: showTime && color == .adaptive
        )
    }
}

enum ClockOverlayStackPolicy {
    static func placesClockAtBottom(for position: OverlayPosition) -> Bool {
        position == .bottomLeading || position == .bottomTrailing
    }
}

enum OverlayStackItem: String, CaseIterable, Hashable, Identifiable {
    case clock
    case date
    case album
    case weekday
    case location
    case caption
    case itemCount
    case battery
    case weather

    var id: String { rawValue }
}

/// Keeps the live player and settings preview in the same order. In a bottom
/// stack, the date and battery form a deliberate chain directly above the
/// clock; optional supporting labels sit above that chain.
enum OverlayStackOrder {
    static func items(
        position: OverlayPosition,
        showTime: Bool,
        showDate: Bool,
        showAlbum: Bool,
        showWeekday: Bool,
        showLocation: Bool,
        showCaption: Bool,
        showItemCount: Bool,
        showBattery: Bool,
        showWeather: Bool
    ) -> [OverlayStackItem] {
        var enabled = Set<OverlayStackItem>()
        if showTime { enabled.insert(.clock) }
        if showDate { enabled.insert(.date) }
        if showAlbum { enabled.insert(.album) }
        if showWeekday { enabled.insert(.weekday) }
        if showLocation { enabled.insert(.location) }
        if showCaption { enabled.insert(.caption) }
        if showItemCount { enabled.insert(.itemCount) }
        if showBattery { enabled.insert(.battery) }
        if showWeather { enabled.insert(.weather) }

        let order: [OverlayStackItem]
        if ClockOverlayStackPolicy.placesClockAtBottom(for: position) {
            order = [.weather, .itemCount, .caption, .location, .weekday, .album, .battery, .date, .clock]
        } else {
            order = [.clock, .date, .album, .weekday, .location, .caption, .itemCount, .battery, .weather]
        }
        return order.filter { enabled.contains($0) }
    }
}

/// The clock remains the anchor of the overlay stack. When both clock and
/// weather are enabled, the surfaces share one composition. Landscape keeps
/// them side by side, while portrait places weather below the clock.
enum WeatherClockLayoutPolicy {
    static let horizontalSpacing: CGFloat = 14
    static let dividerWidth: CGFloat = 1

    static func pairsClockAndWeather(showTime: Bool, showWeather: Bool) -> Bool {
        showTime && showWeather
    }

    static func shouldRenderStandalone(_ item: OverlayStackItem, paired: Bool) -> Bool {
        !(paired && item == .weather)
    }

    static func stacksClockAndWeather(for canvasSize: CGSize) -> Bool {
        canvasSize.height > canvasSize.width
    }
}

/// The visual scale uses Fahrenheit as its stable source unit because both
/// Canvas weather providers expose their raw dew point in Fahrenheit. Labels
/// are converted for the user's locale by the view; the thresholds stay
/// consistent across providers and device settings.
enum DewPointComfortBand: String, CaseIterable, Identifiable {
    case dry
    case comfortable
    case sticky
    case muggy
    case oppressive

    var id: String { rawValue }

    var lowerFahrenheit: Double {
        switch self {
        case .dry: 30
        case .comfortable: 50
        case .sticky: 60
        case .muggy: 65
        case .oppressive: 70
        }
    }

    var upperFahrenheit: Double {
        switch self {
        case .dry: 50
        case .comfortable: 60
        case .sticky: 65
        case .muggy: 70
        case .oppressive: 80
        }
    }

    var spanFahrenheit: Double { upperFahrenheit - lowerFahrenheit }

    var accessibilityLabel: String {
        switch self {
        case .dry: "dry"
        case .comfortable: "comfortable"
        case .sticky: "noticeably sticky"
        case .muggy: "muggy"
        case .oppressive: "oppressive"
        }
    }
}

enum DewPointScalePolicy {
    static let minimumFahrenheit = DewPointComfortBand.allCases.map(\.lowerFahrenheit).min() ?? 30
    static let maximumFahrenheit = DewPointComfortBand.allCases.map(\.upperFahrenheit).max() ?? 80
    static let tickValuesFahrenheit: [Double] = [30, 40, 50, 60, 65, 70, 80]
    static let spanFahrenheit = maximumFahrenheit - minimumFahrenheit

    /// Keeps the reference visible without letting it compete with the photo.
    /// The clamps keep the same proportion feeling across iPad sizes and in
    /// the scaled Settings preview.
    static func displayHeight(forCanvasHeight height: CGFloat) -> CGFloat {
        guard height.isFinite, height > 0 else { return 320 }
        return min(max(height * 0.47, 280), 440)
    }

    /// Returns a 0...1 position where zero is the bottom of the scale and
    /// one is the top. Values outside the reference range pin to an edge.
    static func normalizedPosition(forFahrenheit value: Double) -> CGFloat {
        guard value.isFinite, spanFahrenheit > 0 else { return 0.5 }
        let normalized = (value - minimumFahrenheit) / spanFahrenheit
        return CGFloat(min(max(normalized, 0), 1))
    }

    static func yPosition(forFahrenheit value: Double, height: CGFloat) -> CGFloat {
        height * (1 - normalizedPosition(forFahrenheit: value))
    }

    static func comfortBand(forFahrenheit value: Double) -> DewPointComfortBand {
        guard value.isFinite else { return .comfortable }
        switch value {
        case ..<50: return .dry
        case ..<60: return .comfortable
        case ..<65: return .sticky
        case ..<70: return .muggy
        default: return .oppressive
        }
    }
}

/// The compact live weather card has no stale-data footer. Current weather
/// content remains in the card, while attribution and actionable status stay
/// on their dedicated non-stale surfaces.
enum WeatherOverlayFooterPolicy {
    static let rendersCompactVisualFooter = false
}

enum CanvasAirQualityCategory: String, CaseIterable, Sendable {
    case good
    case moderate
    case unhealthySensitive
    case unhealthy
    case veryUnhealthy
    case hazardous

    static func category(for index: Int) -> Self {
        switch index {
        case ...50: .good
        case ...100: .moderate
        case ...150: .unhealthySensitive
        case ...200: .unhealthy
        case ...300: .veryUnhealthy
        default: .hazardous
        }
    }

    var title: String {
        switch self {
        case .good: "Good"
        case .moderate: "Moderate"
        case .unhealthySensitive: "Sensitive groups"
        case .unhealthy: "Unhealthy"
        case .veryUnhealthy: "Very unhealthy"
        case .hazardous: "Hazardous"
        }
    }
}

/// Guards the UIKit-backed Live Photo bridge against restarting playback on
/// every SwiftUI update and against late results from a previous asset.
enum LivePhotoPlaybackPolicy {
    static func shouldStartPlayback(isPlaying: Bool, playbackActive: Bool) -> Bool {
        isPlaying && !playbackActive
    }

    static func shouldRestartAfterPlayback(loop: Bool, isPlaying: Bool) -> Bool {
        loop && isPlaying
    }

    static func acceptsLoadedPhoto(
        assetID: String,
        currentAssetID: String?,
        requestGeneration: Int,
        currentGeneration: Int
    ) -> Bool {
        assetID == currentAssetID && requestGeneration == currentGeneration
    }
}

/// Maps the full-size slideshow canvas into the compact settings preview
/// without changing the relative size or safe-area placement of overlays.
/// Keeping this calculation pure also makes orientation and scaling regressions
/// inexpensive to test without a device UI run.
enum OverlayPreviewGeometry {
    static func normalizedCanvasSize(screenSize: CGSize, isLandscape: Bool? = nil) -> CGSize {
        let long = max(screenSize.width, screenSize.height)
        let short = min(screenSize.width, screenSize.height)
        let landscape = isLandscape ?? (screenSize.width > screenSize.height)
        return landscape ? CGSize(width: long, height: short) : CGSize(width: short, height: long)
    }

    static func scale(containerSize: CGSize, canvasSize: CGSize) -> CGFloat {
        guard containerSize.width > 0, containerSize.height > 0,
              canvasSize.width > 0, canvasSize.height > 0 else { return 1 }
        return min(containerSize.width / canvasSize.width, containerSize.height / canvasSize.height)
    }
}

/// Computes the exact per-tile media size for the two user-facing framing
/// modes. Fill uses the smallest scale that covers the entire viewport; fit
/// uses the largest scale that remains inside it. Keeping this independent of
/// SwiftUI's size proposal prevents different portrait sources from receiving
/// different implicit zoom factors.
enum MediaFramingGeometry {
    enum HorizontalAlignment: Equatable {
        case leading
        case center
        case trailing
    }

    struct Plan: Equatable {
        let mode: MediaFramingMode
        let renderedFrame: CGRect
        let cropFraction: CGFloat
    }

    static func scale(imageSize: CGSize, viewportSize: CGSize, mode: MediaFramingMode) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0,
              viewportSize.width > 0, viewportSize.height > 0 else { return 1 }
        let widthScale = viewportSize.width / imageSize.width
        let heightScale = viewportSize.height / imageSize.height
        switch mode {
        case .fitWithBorder:
            return min(widthScale, heightScale)
        case .fillZoom:
            return max(widthScale, heightScale)
        }
    }

    static func renderedSize(imageSize: CGSize, viewportSize: CGSize, mode: MediaFramingMode) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
              viewportSize.width > 0, viewportSize.height > 0 else { return imageSize }
        let scale = scale(imageSize: imageSize, viewportSize: viewportSize, mode: mode)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    static func cropFraction(imageSize: CGSize, viewportSize: CGSize) -> CGFloat {
        let rendered = renderedSize(imageSize: imageSize, viewportSize: viewportSize, mode: .fillZoom)
        guard rendered.width > 0, rendered.height > 0 else { return 0 }
        let visibleWidth = min(rendered.width, viewportSize.width)
        let visibleHeight = min(rendered.height, viewportSize.height)
        let visibleFraction = (visibleWidth * visibleHeight) / (rendered.width * rendered.height)
        return max(0, min(1, 1 - visibleFraction))
    }

    /// Resolves framing once, in the tile's final coordinate space. The
    /// Automatic describes how media is grouped into tiles, not a second
    /// per-image framing preference. Horizontal portrait pairs have an
    /// explicit full-bleed invariant: even if the saved global preference is
    /// Fit with border, each half-screen tile must be covered. Otherwise a
    /// narrow portrait beside a wider portrait creates the exact false gutter
    /// this renderer is meant to prevent. `.fitBlurred` is a grouping/backdrop
    /// fallback for an incompatible solo image; it must not silently override
    /// the user's foreground framing preference.
    static func plan(
        imageSize: CGSize,
        viewportSize: CGSize,
        preferredMode: MediaFramingMode,
        requestedLayout: LayoutStyle,
        selectedLayout: LayoutStyle,
        horizontalAlignment: HorizontalAlignment = .center
    ) -> Plan {
        let fillCrop = cropFraction(imageSize: imageSize, viewportSize: viewportSize)
        let mode: MediaFramingMode
        let isFullBleedPortraitPair = selectedLayout == .pairHorizontal || selectedLayout == .portraitPair
        if !isFullBleedPortraitPair && preferredMode == .fitWithBorder {
            mode = .fitWithBorder
        } else {
            mode = .fillZoom
        }

        let size = renderedSize(imageSize: imageSize, viewportSize: viewportSize, mode: mode)
        let x: CGFloat
        switch horizontalAlignment {
        case .leading:
            x = 0
        case .center:
            x = (viewportSize.width - size.width) / 2
        case .trailing:
            x = viewportSize.width - size.width
        }
        let frame = CGRect(
            x: x,
            y: (viewportSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        return Plan(mode: mode, renderedFrame: frame, cropFraction: fillCrop)
    }
}

/// A horizontal portrait pair is a pair of fixed tile viewports, not a
/// centered stack of two independently-sized images. The first tile owns the
/// leading edge of the pair. Keeping this decision separate from source
/// dimensions makes the rule apply equally to 3:4, 2:3, 9:16, and unusual
/// portrait sources.
enum MediaTileAlignmentPolicy {
    static func horizontalAlignment(
        tilePosition: Int,
        layout: LayoutStyle
    ) -> MediaFramingGeometry.HorizontalAlignment {
        guard layout == .pairHorizontal || layout == .portraitPair else {
            return .center
        }
        return tilePosition == 0 ? .leading : .center
    }
}

extension UIImage {
    /// UIKit's `size` is already expressed in the displayed orientation (and
    /// in points rather than backing pixels). Keep geometry on that value so a
    /// rotated local Google Photos file and an upright PhotoKit result follow
    /// the same path without applying the EXIF transform twice.
    var canvasDisplaySize: CGSize {
        size
    }
}

/// The Home card is one action regardless of which visible subregion receives
/// the pointer/touch. This model is intentionally small and testable; the
/// view enforces the same contract with one Button and a contentShape.
enum HomeStartCardSurface: CaseIterable {
    case title, summary, thumbnail, emptySpace, arrow
}

enum HomeStartCardInteraction {
    enum Action: Hashable { case startOrRecover }

    static func action(for _: HomeStartCardSurface) -> Action { .startOrRecover }
}

/// The Home card has one semantic hit region. Keeping this pure makes it
/// possible to assert that title, summary, thumbnail, empty space, and the
/// trailing caret all resolve to the same action without a UI run.
enum HomeStartCardHitRegion {
    static func action(at point: CGPoint, in bounds: CGRect) -> HomeStartCardInteraction.Action? {
        bounds.contains(point) ? .startOrRecover : nil
    }
}

struct HomeToolbarButtonFrames: Equatable {
    let manageAlbums: CGRect
    let settings: CGRect
}

/// The fixed Home toolbar is deliberately laid out from the trailing edge so
/// its hit regions remain inside the safe-area-aware header in both portrait
/// and landscape. The view uses the same inset/size constants.
enum HomeToolbarHitRegion {
    static func frames(in size: CGSize, horizontalInset: CGFloat = 28, buttonSize: CGFloat = 46, spacing: CGFloat = 12) -> HomeToolbarButtonFrames {
        let right = max(horizontalInset + buttonSize, size.width - horizontalInset)
        let settings = CGRect(x: right - buttonSize, y: 0, width: buttonSize, height: buttonSize)
        let manage = CGRect(x: settings.minX - spacing - buttonSize, y: 0, width: buttonSize, height: buttonSize)
        return HomeToolbarButtonFrames(manageAlbums: manage, settings: settings)
    }
}

/// Keeps the selected-album preview responsible for the remaining Home
/// viewport instead of ending early and leaving a fixed bottom spacer.
enum HomeContentGeometry {
    /// GeometryReader is already inside SwiftUI's safe-area-adjusted region
    /// on some iPadOS versions, so its reported bottom inset can be zero even
    /// while the window still reserves the home-indicator area. Keep a small
    /// edge extension in that case so the album card owns the remaining
    /// display instead of ending above a black strip.
    static func bottomEdgeExtension(reportedSafeAreaBottom: CGFloat) -> CGFloat {
        max(36, reportedSafeAreaBottom)
    }

    static func albumAreaHeight(
        viewportHeight: CGFloat,
        fixedContentHeight: CGFloat,
        minimumHeight: CGFloat,
        bottomExtension: CGFloat = 0
    ) -> CGFloat {
        max(minimumHeight, viewportHeight - max(0, fixedContentHeight) + max(0, bottomExtension))
    }
}

/// Keeps the Home playback card's compact summary tied to the same persisted
/// settings that drive the slideshow. The view can render this value without
/// duplicating transition names or falling back to a stale default.
enum HomePlaybackSummary {
    static func label(queueMode: QueueMode, transition: TransitionStyle) -> String {
        "\(queueMode.title) · \(transition.title)"
    }
}

/// Resolves a single playback step without mutating queue state. A nil result
/// means that forward playback reached the end with repeat disabled.
enum PlaybackIndexResolver {
    static func nextIndex(current: Int, count: Int, direction: Int, repeatEnabled: Bool) -> Int? {
        guard count > 0 else { return nil }
        if direction > 0 {
            if current + 1 < count { return current + 1 }
            return repeatEnabled ? 0 : nil
        }
        return current > 0 ? current - 1 : count - 1
    }
}

enum PlaybackAdvancePolicy {
    /// A displayed pair/collage is one playback unit. Automatic transitions
    /// and gestures must land on the next group start instead of exposing the
    /// second tile of the current group as a standalone frame.
    static func destinationIndex(
        imageSizes: [CGSize],
        currentIndex: Int,
        direction: Int,
        layout: LayoutStyle,
        canvasSize: CGSize,
        repeatEnabled: Bool,
        usesDisplayedGroup: Bool,
        singleMediaIndices: Set<Int> = []
    ) -> Int? {
        guard usesDisplayedGroup else {
            return PlaybackIndexResolver.nextIndex(
                current: currentIndex,
                count: imageSizes.count,
                direction: direction,
                repeatEnabled: repeatEnabled
            )
        }
        return PlaybackGroupResolver.nextGroupIndex(
            imageSizes: imageSizes,
            currentIndex: currentIndex,
            direction: direction,
            layout: layout,
            canvasSize: canvasSize,
            repeatEnabled: repeatEnabled,
            singleMediaIndices: singleMediaIndices
        )
    }

    /// A forward transition to index zero is the start of a new complete
    /// playback cycle, whether the target came from the raw queue resolver or
    /// the displayed-group resolver. The latter used to be excluded because
    /// it supplies an explicit target, which meant still-photo loops never
    /// actually reshuffled.
    static func shouldShuffleAfterAdvance(
        direction: Int,
        targetIndex: Int?,
        currentIndex: Int,
        shuffleEachLoop: Bool
    ) -> Bool {
        shuffleEachLoop && direction > 0 && currentIndex == 0 && (targetIndex == nil || targetIndex == 0)
    }
}

/// Keeps a provider refresh from turning a stable frame into a new session.
/// Queue positions are disposable; media identifiers and the currently
/// displayed group are the durable playback identity.
enum PlaybackQueueIdentity {
    static func index(
        for assetID: String?,
        in queue: [CanvasMediaItem],
        fallbackIndex: Int
    ) -> Int {
        guard !queue.isEmpty else { return 0 }
        if let assetID, let index = queue.firstIndex(where: { $0.id == assetID }) {
            return index
        }
        return min(max(fallbackIndex, 0), queue.count - 1)
    }

    static func canPreserveDisplayedFrame(
        currentAssetID: String?,
        queueCurrentAssetID: String?,
        displayedGroupIDs: [String],
        candidateQueue: [CanvasMediaItem],
        forceReload: Bool
    ) -> Bool {
        guard !forceReload,
              let currentAssetID,
              currentAssetID == queueCurrentAssetID,
              !displayedGroupIDs.isEmpty else { return false }
        let candidateIDs = Set(candidateQueue.map(\.id))
        return displayedGroupIDs.allSatisfy(candidateIDs.contains)
    }
}

/// Keeps the actual displayed route independent from the current shuffle
/// order. A new shuffle can legitimately change the queue for future forward
/// playback, but it must not change what Back means for frames that already
/// appeared on screen.
struct PlaybackHistoryPosition: Equatable {
    let queue: [CanvasMediaItem]
    let currentIndex: Int
}

struct PlaybackNavigationHistory {
    static let defaultMaximumEntries = 64

    private(set) var positions: [PlaybackHistoryPosition] = []
    private(set) var cursor = -1
    private let maximumEntries: Int

    init(maximumEntries: Int = Self.defaultMaximumEntries) {
        self.maximumEntries = max(1, maximumEntries)
    }

    func canMove(direction: Int) -> Bool {
        guard direction != 0 else { return false }
        let nextCursor = cursor + (direction > 0 ? 1 : -1)
        return positions.indices.contains(nextCursor)
    }

    mutating func reset(to position: PlaybackHistoryPosition) {
        positions = [position]
        cursor = 0
    }

    mutating func append(_ position: PlaybackHistoryPosition) {
        if cursor + 1 < positions.count {
            positions.removeSubrange((cursor + 1)..<positions.count)
        }
        positions.append(position)
        cursor = positions.count - 1

        let overflow = positions.count - maximumEntries
        if overflow > 0 {
            positions.removeFirst(overflow)
            cursor -= overflow
        }
    }

    mutating func move(direction: Int) -> PlaybackHistoryPosition? {
        guard direction != 0 else { return nil }
        let nextCursor = cursor + (direction > 0 ? 1 : -1)
        guard positions.indices.contains(nextCursor) else { return nil }
        cursor = nextCursor
        return positions[cursor]
    }
}

enum PlaybackMediaSurfacePolicy {
    static func usesSingleTile(for kind: MediaKind) -> Bool {
        kind != .photo
    }

    static func allowsCompanions(for kind: MediaKind) -> Bool {
        kind == .photo
    }
}

struct PlaybackGroupSelection: Equatable {
    let indices: [Int]

    var isPaired: Bool { indices.count > 1 }
}

/// Resolves the indices that are visible together in the slideshow. A swipe
/// uses the next/previous group start, so a paired frame is replaced as a
/// complete unit instead of carrying one old tile into the next frame.
enum PlaybackGroupResolver {
    static func selection(
        imageSizes: [CGSize],
        currentIndex: Int,
        layout: LayoutStyle,
        canvasSize: CGSize,
        singleMediaIndices: Set<Int> = []
    ) -> PlaybackGroupSelection {
        guard imageSizes.indices.contains(currentIndex) else { return PlaybackGroupSelection(indices: []) }
        if singleMediaIndices.contains(currentIndex) {
            return PlaybackGroupSelection(indices: [currentIndex])
        }
        switch layout {
        case .single, .fitBlurred, .intelligentFill, .solidBackground:
            return PlaybackGroupSelection(indices: [currentIndex])
        case .pairHorizontal, .pairVertical, .automatic, .portraitPair:
            // Pairing is orientation-aware at the playback boundary too.
            // The renderer cannot repair a mixed group after the queue has
            // already loaded both assets, and Back/Next would otherwise skip
            // or replay the landscape that was incorrectly used as a tile.
            let boundary = imageSizes.indices.first(where: { $0 > currentIndex && singleMediaIndices.contains($0) }) ?? imageSizes.count
            let suffix = Array(imageSizes[currentIndex..<boundary])
            let requestedLayout: LayoutStyle? = layout == .pairHorizontal || layout == .pairVertical ? layout : nil
            let local = PairLayoutResolver.selection(
                imageSizes: suffix,
                canvasSize: canvasSize,
                requestedLayout: requestedLayout
            )
            let mapped = local.indices.compactMap { offset -> Int? in
                let index = currentIndex + offset
                return imageSizes.indices.contains(index) ? index : nil
            }
            return PlaybackGroupSelection(indices: mapped.isEmpty ? [currentIndex] : mapped)
        case .collageThree:
            var indices: [Int] = []
            for index in currentIndex..<min(imageSizes.count, currentIndex + 3) {
                guard !singleMediaIndices.contains(index) else { break }
                indices.append(index)
            }
            return PlaybackGroupSelection(indices: indices.isEmpty ? [currentIndex] : indices)
        case .gridFour:
            var indices: [Int] = []
            for index in currentIndex..<min(imageSizes.count, currentIndex + 4) {
                guard !singleMediaIndices.contains(index) else { break }
                indices.append(index)
            }
            return PlaybackGroupSelection(indices: indices.isEmpty ? [currentIndex] : indices)
        }
    }

    static func groupStarts(
        imageSizes: [CGSize],
        layout: LayoutStyle,
        canvasSize: CGSize,
        singleMediaIndices: Set<Int> = []
    ) -> [Int] {
        guard !imageSizes.isEmpty else { return [] }
        var starts: [Int] = []
        var cursor = 0
        while cursor < imageSizes.count {
            starts.append(cursor)
            let group = selection(
                imageSizes: imageSizes,
                currentIndex: cursor,
                layout: layout,
                canvasSize: canvasSize,
                singleMediaIndices: singleMediaIndices
            )
            let last = group.indices.max() ?? cursor
            cursor = max(cursor + 1, last + 1)
        }
        return starts
    }

    static func nextGroupIndex(
        imageSizes: [CGSize],
        currentIndex: Int,
        direction: Int,
        layout: LayoutStyle,
        canvasSize: CGSize,
        repeatEnabled: Bool,
        singleMediaIndices: Set<Int> = []
    ) -> Int? {
        let starts = groupStarts(
            imageSizes: imageSizes,
            layout: layout,
            canvasSize: canvasSize,
            singleMediaIndices: singleMediaIndices
        )
        guard !starts.isEmpty else { return nil }
        let currentStart = starts.last(where: { start in
            let group = selection(
                imageSizes: imageSizes,
                currentIndex: start,
                layout: layout,
                canvasSize: canvasSize,
                singleMediaIndices: singleMediaIndices
            )
            return group.indices.contains(currentIndex)
        }) ?? starts.last(where: { $0 <= currentIndex }) ?? starts[0]
        guard let position = starts.firstIndex(of: currentStart) else { return starts[0] }

        if direction > 0 {
            if position + 1 < starts.count { return starts[position + 1] }
            return repeatEnabled ? starts[0] : nil
        }
        if position > 0 { return starts[position - 1] }
        // Previous navigation historically wraps even when Repeat is off.
        // Keep that behavior while ensuring the destination is a group start.
        return starts.last
    }
}

/// Pure geometry for the per-tile capture-date badge. The SwiftUI view uses
/// the same bottom-leading inset; this helper guards against a badge being
/// laid out outside a single tile's clipped bounds.
enum CaptureDateOverlayGeometry {
    struct TileFrame: Equatable {
        let index: Int
        let frame: CGRect
    }

    static func bottomLeadingFrame(tileSize: CGSize, badgeSize: CGSize, inset: CGFloat = 10) -> CGRect {
        let safeInset = max(0, inset)
        let width = min(max(0, badgeSize.width), max(0, tileSize.width - safeInset * 2))
        let height = min(max(0, badgeSize.height), max(0, tileSize.height - safeInset * 2))
        return CGRect(
            x: safeInset,
            y: max(safeInset, tileSize.height - safeInset - height),
            width: width,
            height: height
        )
    }

    enum HorizontalAnchor: Equatable {
        case leading
        case trailing
    }

    /// Moves landscape badges away from a bottom-leading clock and keeps the
    /// two portrait dates visually balanced around the centerline. Other
    /// layouts retain the normal bottom-leading badge placement.
    static func horizontalAnchor(
        tilePosition: Int,
        tileIndex: Int,
        tileCount: Int,
        resolvedStyle: LayoutStyle,
        imageSizes: [CGSize],
        position: OverlayPosition?
    ) -> HorizontalAnchor {
        if position == .bottomLeading,
           imageSizes.indices.contains(tileIndex),
           imageSizes[tileIndex].width > imageSizes[tileIndex].height {
            return .trailing
        }

        guard tileCount == 2,
              resolvedStyle == .portraitPair ||
                (resolvedStyle == .pairHorizontal && imageSizes.count >= 2 && imageSizes.prefix(2).allSatisfy { $0.height > $0.width })
        else { return .leading }

        switch position {
        case .bottomLeading where tilePosition == 0:
            return .trailing
        case .bottomTrailing where tilePosition == 1:
            return .leading
        default:
            return .leading
        }
    }

    /// Returns the final on-screen tile frames used by LayoutCanvas. Keeping
    /// this pure geometry in one place lets date overlays and media layout
    /// agree for single, paired, and grid presentations.
    static func tileFrames(
        imageSizes: [CGSize],
        style: LayoutStyle,
        canvasSize: CGSize,
        spacing: CGFloat
    ) -> [TileFrame] {
        guard canvasSize.width > 0, canvasSize.height > 0, !imageSizes.isEmpty else { return [] }
        let selection = LayoutCanvasSelectionResolver.selection(style: style, imageSizes: imageSizes, canvasSize: canvasSize)
        let gap = max(0, spacing)
        switch selection.style {
        case .pairHorizontal, .portraitPair:
            let width = max(0, (canvasSize.width - gap) / 2)
            return selection.indices.prefix(2).enumerated().map { offset, index in
                TileFrame(index: index, frame: CGRect(x: CGFloat(offset) * (width + gap), y: 0, width: width, height: canvasSize.height))
            }
        case .pairVertical:
            let height = max(0, (canvasSize.height - gap) / 2)
            return selection.indices.prefix(2).enumerated().map { offset, index in
                TileFrame(index: index, frame: CGRect(x: 0, y: CGFloat(offset) * (height + gap), width: canvasSize.width, height: height))
            }
        case .collageThree:
            let leftWidth = max(0, (canvasSize.width - gap) * 0.5)
            let rightWidth = max(0, canvasSize.width - leftWidth - gap)
            let halfHeight = max(0, (canvasSize.height - gap) / 2)
            let frames = [
                CGRect(x: 0, y: 0, width: leftWidth, height: canvasSize.height),
                CGRect(x: leftWidth + gap, y: 0, width: rightWidth, height: halfHeight),
                CGRect(x: leftWidth + gap, y: halfHeight + gap, width: rightWidth, height: halfHeight)
            ]
            return selection.indices.prefix(3).enumerated().map { offset, index in TileFrame(index: index, frame: frames[offset]) }
        case .gridFour:
            let width = max(0, (canvasSize.width - gap) / 2)
            let height = max(0, (canvasSize.height - gap) / 2)
            let frames = [
                CGRect(x: 0, y: 0, width: width, height: height),
                CGRect(x: width + gap, y: 0, width: width, height: height),
                CGRect(x: 0, y: height + gap, width: width, height: height),
                CGRect(x: width + gap, y: height + gap, width: width, height: height)
            ]
            return selection.indices.prefix(4).enumerated().map { offset, index in TileFrame(index: index, frame: frames[offset]) }
        default:
            guard let index = selection.indices.first else { return [] }
            return [TileFrame(index: index, frame: CGRect(origin: .zero, size: canvasSize))]
        }
    }
}

struct TransitionEngine {
    static func choose(preferred: TransitionStyle, random: Bool, excluded: Set<TransitionStyle>, reduceMotion: Bool, seed: UInt64 = 1) -> TransitionStyle {
        if reduceMotion { return preferred.isReduceMotionSafe ? preferred : .crossfade }
        guard random else { return preferred }
        // Cut is intentionally available as an explicit selection, but a
        // random slideshow should always visibly transition between frames.
        let choices = Self.choices(excluding: excluded.union([.cut]))
        guard !choices.isEmpty else { return .crossfade }
        var generator = SeededGenerator(seed: seed)
        return choices.randomElement(using: &generator) ?? .crossfade
    }

    static func choices(excluding excluded: Set<TransitionStyle>) -> [TransitionStyle] {
        TransitionStyle.allCases.filter { !excluded.contains($0) }
    }

    /// Gesture navigation has a physical direction that takes precedence over
    /// the timed-playback style. Resolve that direction once, when the new
    /// frame is published, so a later view update cannot change a transition
    /// that is already in flight.
    static func resolvedStyle(
        preferred: TransitionStyle,
        random: Bool,
        excluded: Set<TransitionStyle>,
        reduceMotion: Bool,
        seed: UInt64,
        gestureDirection: Int
    ) -> TransitionStyle {
        guard gestureDirection == 0 else {
            if reduceMotion { return .crossfade }
            return gestureDirection > 0 ? .slideLeft : .slideRight
        }
        return choose(
            preferred: preferred,
            random: random,
            excluded: excluded,
            reduceMotion: reduceMotion,
            seed: seed
        )
    }
}

enum CanvasFrameTransitionRole {
    case incoming
    case outgoing
}

enum CanvasFrameTransitionAnchor: Equatable {
    case center
    case leading
    case trailing
}

/// A complete, explicit visual state for one frame layer. The incoming layer
/// is guaranteed to resolve to identity at progress 1 for every style. This is
/// deliberately independent of SwiftUI's insertion/removal lifecycle: if an
/// animation is interrupted, PlayerView can synchronously set progress to 1
/// and remove the outgoing layer instead of leaving a paired frame translated.
struct CanvasFrameTransitionState: Equatable {
    var scale: CGFloat = 1
    var opacity: Double = 1
    var blur: CGFloat = 0
    var offset: CGSize = .zero
    var rotationDegrees: Double = 0
    var anchor: CanvasFrameTransitionAnchor = .center
    var perspective: CGFloat = 0
}

enum CanvasFrameTransitionGeometry {
    static func state(
        style: TransitionStyle,
        role: CanvasFrameTransitionRole,
        progress rawProgress: CGFloat,
        canvasSize: CGSize
    ) -> CanvasFrameTransitionState {
        let progress = min(max(rawProgress, 0), 1)
        let remaining = 1 - progress
        let incoming = role == .incoming

        switch style {
        case .cut:
            return .init(opacity: incoming ? 1 : 0)
        case .crossfade:
            return .init(opacity: incoming ? Double(progress) : Double(remaining))
        case .slideLeft:
            return .init(offset: CGSize(width: incoming ? canvasSize.width * remaining : -canvasSize.width * progress, height: 0))
        case .slideRight:
            return .init(offset: CGSize(width: incoming ? -canvasSize.width * remaining : canvasSize.width * progress, height: 0))
        case .slideUp:
            return .init(offset: CGSize(width: 0, height: incoming ? canvasSize.height * remaining : -canvasSize.height * progress))
        case .slideDown:
            return .init(offset: CGSize(width: 0, height: incoming ? -canvasSize.height * remaining : canvasSize.height * progress))
        case .push:
            return .init(
                opacity: incoming ? Double(progress) : 1,
                offset: CGSize(width: incoming ? canvasSize.width * remaining : -canvasSize.width * progress, height: 0)
            )
        case .zoomIn:
            return .init(
                scale: incoming ? interpolate(from: 0.72, to: 1, progress: progress) : 1,
                opacity: incoming ? Double(progress) : Double(remaining)
            )
        case .zoomOut:
            return .init(
                scale: incoming
                    ? interpolate(from: 1.28, to: 1, progress: progress)
                    : interpolate(from: 1, to: 0.82, progress: progress),
                opacity: incoming ? Double(progress) : Double(remaining)
            )
        case .kenBurns:
            return .init(
                scale: incoming
                    ? interpolate(from: 1.1, to: 1, progress: progress)
                    : interpolate(from: 1, to: 1.06, progress: progress),
                opacity: incoming ? Double(progress) : Double(remaining),
                offset: incoming
                    ? CGSize(width: -18 * remaining, height: 10 * remaining)
                    : CGSize(width: 18 * progress, height: -10 * progress)
            )
        case .blurDissolve:
            return .init(
                opacity: incoming ? Double(progress) : Double(remaining),
                blur: incoming ? 18 * remaining : 10 * progress
            )
        case .scaleFade:
            return .init(
                scale: incoming
                    ? interpolate(from: 0.84, to: 1, progress: progress)
                    : interpolate(from: 1, to: 1.12, progress: progress),
                opacity: incoming ? Double(progress) : Double(remaining)
            )
        case .pageSwipe:
            return .init(
                opacity: incoming ? Double(progress) : Double(remaining),
                rotationDegrees: incoming ? -76 * Double(remaining) : 76 * Double(progress),
                anchor: incoming ? .leading : .trailing,
                perspective: 0.72
            )
        }
    }

    private static func interpolate(from: CGFloat, to: CGFloat, progress: CGFloat) -> CGFloat {
        from + (to - from) * progress
    }
}

struct PortraitPairing {
    static func groups(for assets: [MediaDescriptor], policy: LayoutStyle) -> [[MediaDescriptor]] {
        guard policy == .portraitPair || policy == .pairHorizontal || policy == .pairVertical else { return assets.map { [$0] } }
        var portraits = assets.filter { $0.pixelHeight > $0.pixelWidth }
        var landscapes = assets.filter { $0.pixelWidth >= $0.pixelHeight }
        var groups: [[MediaDescriptor]] = []
        while !portraits.isEmpty || !landscapes.isEmpty {
            if let portrait = portraits.first { portraits.removeFirst(); if let partnerIndex = landscapes.indices.min(by: { abs(landscapes[$0].pixelWidth - portrait.pixelWidth) < abs(landscapes[$1].pixelWidth - portrait.pixelWidth) }) { groups.append([portrait, landscapes.remove(at: partnerIndex)]) } else { groups.append([portrait]) } }
            else if let landscape = landscapes.first { landscapes.removeFirst(); groups.append([landscape]) }
        }
        return groups
    }
}

/// Rotates representative home-preview media without touching the selected
/// albums or the slideshow queue. The seed is supplied by the Home session so
/// a refresh can show a different subset while remaining deterministic for a
/// given album/seed pair.
enum HomePreviewSelection {
    static func rotatedIndices(count: Int, limit: Int, seed: Int, albumID: String) -> [Int] {
        guard count > 0, limit > 0 else { return [] }
        var hash = UInt64(bitPattern: Int64(seed))
        for scalar in albumID.unicodeScalars {
            hash = hash &* 31 &+ UInt64(scalar.value)
        }
        let start = Int(hash % UInt64(count))
        return (0..<min(count, limit)).map { (start + $0) % count }
    }

    static func representativeItems<T>(from items: [T], limit: Int, seed: Int, albumID: String) -> [T] {
        rotatedIndices(count: items.count, limit: limit, seed: seed, albumID: albumID).map { items[$0] }
    }
}

/// Chooses a small, readable composition for a selected-album thumbnail. The
/// Home preview is intentionally less dense than slideshow playback: a
/// landscape canvas gets two larger landscape tiles side-by-side, while a
/// portrait canvas stacks two portrait tiles so the representative photos do
/// not become a row of tiny strips. The resolver only pairs compatible media
/// orientations and falls back to a single aspect-safe tile when a pair is
/// unavailable.
enum HomePreviewLayoutStyle: Equatable {
    case single
    case pairHorizontal
    case pairVertical
}

struct HomePreviewLayoutSelection: Equatable {
    let style: HomePreviewLayoutStyle
    let indices: [Int]
}

enum HomePreviewLayoutResolver {
    static func selection(imageSizes: [CGSize], canvasSize: CGSize, isLandscapeDevice: Bool? = nil) -> HomePreviewLayoutSelection {
        guard !imageSizes.isEmpty else { return HomePreviewLayoutSelection(style: .single, indices: []) }

        // Album cards can be close to square on iPad, so their local geometry
        // is not a reliable proxy for device orientation. Prefer the actual
        // device orientation and only fall back to geometry for previews/tests
        // that do not have an orientation signal.
        let isLandscapeCanvas = isLandscapeDevice ?? (canvasSize.width >= canvasSize.height)
        let target: PairMediaOrientation = isLandscapeCanvas ? .landscape : .portrait
        let compatible = imageSizes.indices.filter { PairLayoutResolver.orientation(for: imageSizes[$0]) == target }
        let chosen: [Int]
        if compatible.count >= 2 {
            chosen = Array(compatible.prefix(2))
        } else if compatible.count == 1 {
            chosen = compatible
        } else {
            // If the source has no media matching the device, keep the first
            // available orientation together rather than mixing a portrait
            // and landscape tile into a visually awkward mini-grid.
            let fallbackOrientation = PairLayoutResolver.orientation(for: imageSizes[0])
            chosen = Array(imageSizes.indices.filter {
                PairLayoutResolver.orientation(for: imageSizes[$0]) == fallbackOrientation
            }.prefix(2))
        }

        guard chosen.count >= 2 else {
            return HomePreviewLayoutSelection(style: .single, indices: chosen.isEmpty ? [0] : chosen)
        }
        return HomePreviewLayoutSelection(
            style: isLandscapeCanvas ? .pairHorizontal : .pairVertical,
            indices: chosen
        )
    }
}

enum ClockPreviewMediaResolver {
    static func representative(from items: [CanvasMediaItem]) -> CanvasMediaItem? {
        items.first(where: { $0.appleAsset != nil || $0.localURL != nil }) ?? items.first
    }
}

struct ScheduleEngine {
    static func isActive(_ rule: ScheduleRule, date: Date, calendar: Calendar = .current) -> Bool {
        let components = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = components.weekday, let hour = components.hour, let minute = components.minute else { return false }
        let now = hour * 60 + minute
        if rule.startMinutes <= rule.stopMinutes {
            guard rule.weekdays.contains(weekday) else { return false }
            return now >= rule.startMinutes && now < rule.stopMinutes
        }
        // For an overnight rule, the post-midnight portion belongs to the
        // previous day's start. A Monday 22:00–Tuesday 06:00 rule must still
        // be active at 02:00 Tuesday even though Tuesday is not selected.
        if now >= rule.startMinutes { return rule.weekdays.contains(weekday) }
        if now < rule.stopMinutes {
            let previousWeekday = weekday == 1 ? 7 : weekday - 1
            return rule.weekdays.contains(previousWeekday)
        }
        return false
    }

    static func activeRule(_ rules: [ScheduleRule], date: Date, calendar: Calendar = .current) -> ScheduleRule? { rules.first { isActive($0, date: date, calendar: calendar) } }
}

/// Canvas-only overnight dimming. This never writes UIScreen brightness; it
/// only tells the live frame when to apply its low-light visual treatment.
enum NightDimmingPolicy {
    static let overlayOpacity = 0.62

    static func isActive(
        enabled: Bool,
        startMinutes: Int,
        stopMinutes: Int,
        date: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard enabled else { return false }
        let start = min(max(startMinutes, 0), 24 * 60 - 1)
        let stop = min(max(stopMinutes, 0), 24 * 60 - 1)
        guard start != stop else { return false }
        let components = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour, let minute = components.minute else { return false }
        let now = hour * 60 + minute
        if start < stop {
            return now >= start && now < stop
        }
        return now >= start || now < stop
    }
}

/// Keeps the battery label and symbol aligned with the same normalized device
/// reading. In particular, a fully charged device must not fall through to the
/// older fixed `battery.75percent` symbol.
enum BatteryOverlayPolicy {
    static func percentage(for level: Float) -> Int? {
        guard level.isFinite, level >= 0 else { return nil }
        return min(max(Int((level * 100).rounded()), 0), 100)
    }

    static func label(for level: Float) -> String {
        guard let percentage = percentage(for: level) else { return "—" }
        return "\(percentage)%"
    }

    static func symbol(for level: Float, isCharging: Bool) -> String {
        guard let percentage = percentage(for: level) else {
            return isCharging ? "bolt.fill" : "battery.0percent"
        }
        if percentage >= 100 { return "battery.100percent" }
        if isCharging { return "bolt.fill" }
        switch percentage {
        case 75...: return "battery.75percent"
        case 50...: return "battery.50percent"
        case 25...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

@MainActor
final class PowerService: ObservableObject {
    @Published private(set) var batteryLevel: Float = -1
    @Published private(set) var isCharging = false
    private var priorBrightness: CGFloat?
    init() { UIDevice.current.isBatteryMonitoringEnabled = true; refresh() }
    func refresh() {
        let state = UIDevice.current.batteryState
        let level = UIDevice.current.batteryLevel
        // iPadOS can report a full state while the floating level is just below
        // one. Promote that state so the display and power gate agree that the
        // device is at 100%.
        batteryLevel = state == .full ? 1 : level
        isCharging = state == .charging || state == .full
    }
    func beginPlayback(keepAwake: Bool) {
        if priorBrightness == nil { priorBrightness = UIScreen.main.brightness }
        // Re-apply the setting on every update. Calling this with false must
        // undo a previously enabled keep-awake session when the person edits
        // Power & Display while a frame is already open.
        UIApplication.shared.isIdleTimerDisabled = keepAwake
    }
    func endPlayback() { UIApplication.shared.isIdleTimerDisabled = false; if let priorBrightness { UIScreen.main.brightness = priorBrightness; self.priorBrightness = nil } }
}

@MainActor
final class ScheduleMonitor: ObservableObject {
    @Published private(set) var isPlaybackAllowed = true
    @Published private(set) var activeRule: ScheduleRule?
    private var task: Task<Void, Never>?
    func start(rules: [ScheduleRule]) {
        task?.cancel()
        guard !rules.isEmpty else { isPlaybackAllowed = true; activeRule = nil; return }
        evaluate(rules)
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.evaluate(rules)
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
    private func evaluate(_ rules: [ScheduleRule]) {
        activeRule = ScheduleEngine.activeRule(rules, date: Date())
        isPlaybackAllowed = activeRule != nil
    }
    deinit { task?.cancel() }
}

@MainActor
final class NightDimmingMonitor: ObservableObject {
    @Published private(set) var isActive = false
    private var task: Task<Void, Never>?

    func start(enabled: Bool, startMinutes: Int, stopMinutes: Int) {
        task?.cancel()
        evaluate(enabled: enabled, startMinutes: startMinutes, stopMinutes: stopMinutes)
        guard enabled, startMinutes != stopMinutes else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.evaluate(enabled: enabled, startMinutes: startMinutes, stopMinutes: stopMinutes)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isActive = false
    }

    private func evaluate(enabled: Bool, startMinutes: Int, stopMinutes: Int) {
        isActive = NightDimmingPolicy.isActive(
            enabled: enabled,
            startMinutes: startMinutes,
            stopMinutes: stopMinutes,
            date: Date()
        )
    }

    deinit { task?.cancel() }
}
