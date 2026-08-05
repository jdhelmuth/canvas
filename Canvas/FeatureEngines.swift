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
/// thumbnail task or on the Google connection state. Both providers feed the
/// same queue, so this check intentionally uses the deduplicated media list.
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
    /// Automatic layouts should feel edge-to-edge for ordinary camera photos,
    /// but not at the cost of throwing away a large part of a square, panorama,
    /// or unusually tall image. This limit is the fraction of the rendered
    /// image that may sit outside its tile before Automatic switches to fit.
    static let automaticMaximumCropFraction: CGFloat = 0.18

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

    /// Resolves framing once, in the tile's final coordinate space. Automatic
    /// layouts retain a true minimum-cover fill for ordinary aspect ratios and
    /// switch to fit only when that fill would become an excessive zoom. A
    /// `.fitBlurred` selection always means fit, matching the layout's name and
    /// the resolver's documented fallback behavior.
    static func plan(
        imageSize: CGSize,
        viewportSize: CGSize,
        preferredMode: MediaFramingMode,
        requestedLayout: LayoutStyle,
        selectedLayout: LayoutStyle
    ) -> Plan {
        let fillCrop = cropFraction(imageSize: imageSize, viewportSize: viewportSize)
        let isAutomatic = requestedLayout == .automatic || requestedLayout == .portraitPair
        let mode: MediaFramingMode
        if preferredMode == .fitWithBorder || selectedLayout == .fitBlurred {
            mode = .fitWithBorder
        } else if isAutomatic && fillCrop > automaticMaximumCropFraction {
            mode = .fitWithBorder
        } else {
            mode = .fillZoom
        }

        let size = renderedSize(imageSize: imageSize, viewportSize: viewportSize, mode: mode)
        let frame = CGRect(
            x: (viewportSize.width - size.width) / 2,
            y: (viewportSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        return Plan(mode: mode, renderedFrame: frame, cropFraction: fillCrop)
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

    /// A swipe supplies an explicit displayed-group target. It must not be
    /// treated as the automatic end-of-loop transition that may reshuffle.
    static func shouldShuffleAfterAdvance(
        direction: Int,
        targetIndex: Int?,
        currentIndex: Int,
        shuffleEachLoop: Bool
    ) -> Bool {
        shuffleEachLoop && targetIndex == nil && direction > 0 && currentIndex == 0
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
        case .pairHorizontal, .pairVertical:
            let partner = currentIndex + 1 < imageSizes.count && !singleMediaIndices.contains(currentIndex + 1) ? [currentIndex + 1] : []
            return PlaybackGroupSelection(indices: [currentIndex] + partner)
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
        case .automatic, .portraitPair:
            let boundary = imageSizes.indices.first(where: { $0 > currentIndex && singleMediaIndices.contains($0) }) ?? imageSizes.count
            let suffix = Array(imageSizes[currentIndex..<boundary])
            let local = PairLayoutResolver.selection(imageSizes: suffix, canvasSize: canvasSize)
            let mapped = local.indices.compactMap { offset -> Int? in
                let index = currentIndex + offset
                return imageSizes.indices.contains(index) ? index : nil
            }
            return PlaybackGroupSelection(indices: mapped.isEmpty ? [currentIndex] : mapped)
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
        let choices = TransitionStyle.allCases.filter { !excluded.contains($0) }
        guard !choices.isEmpty else { return .crossfade }
        var generator = SeededGenerator(seed: seed)
        return choices.randomElement(using: &generator) ?? .crossfade
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

@MainActor
final class PowerService: ObservableObject {
    @Published private(set) var batteryLevel: Float = -1
    @Published private(set) var isCharging = false
    private var priorBrightness: CGFloat?
    init() { UIDevice.current.isBatteryMonitoringEnabled = true; refresh() }
    func refresh() { batteryLevel = UIDevice.current.batteryLevel; isCharging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full }
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
