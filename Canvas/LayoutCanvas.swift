import SwiftUI
import UIKit

/// A consistent behind-media treatment for every frame layout. When the
/// setting is enabled and a current image is available, the image itself is
/// used as a quiet, darkened, desaturated backdrop. This keeps fit-mode gaps
/// contextual without reintroducing the old blue placeholder. Empty/error
/// states use the configured neutral fallback instead.
struct MediaBackdropView: View {
    /// Deliberately warm/neutral so a missing image never exposes the old
    /// navy placeholder. Kept in one place for photo, video, and Live Photo
    /// callers to share the exact same fallback.
    static let neutralFallback = Color(red: 0.055, green: 0.052, blue: 0.047)

    let images: [UIImage]
    let mode: MediaBackdropMode
    let fallback: Color

    private var backdropImages: [UIImage] { Array(images.prefix(3)) }

    var body: some View {
        content
            .saturation(mode == .mediaDerived ? 0.22 : 0)
            .brightness(mode == .mediaDerived ? -0.24 : -0.08)
            .blur(radius: mode == .mediaDerived ? 32 : 0)
            .clipped()
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .mediaDerived where !backdropImages.isEmpty:
            ZStack {
                if backdropImages.count == 1, let image = backdropImages.first {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                } else {
                    HStack(spacing: 0) {
                        ForEach(backdropImages.indices, id: \.self) { index in
                            Image(uiImage: backdropImages[index])
                                .resizable()
                                .scaledToFill()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .clipped()
                        }
                    }
                }
                // A restrained veil keeps overlay text readable while still
                // allowing the colors and shapes of the current media through.
                Color.black.opacity(0.40)
            }
        default:
            fallback
        }
    }
}

struct LayoutCanvas: View {
    let images: [UIImage]
    let style: LayoutStyle
    let fit: Bool
    let background: Color
    let blurredBackground: Bool
    let spacing: CGFloat
    let cornerRadius: CGFloat
    let captureDates: [Date?]
    let showCaptureDates: Bool
    let captureDateStyle: CaptureDateBadgeStyle
    let framingMode: MediaFramingMode
    let overlaySettings: OverlaySettings?

    init(
        images: [UIImage],
        style: LayoutStyle,
        fit: Bool,
        background: Color,
        blurredBackground: Bool,
        spacing: CGFloat,
        cornerRadius: CGFloat,
        captureDates: [Date?] = [],
        showCaptureDates: Bool = false,
        captureDateStyle: CaptureDateBadgeStyle = .darkBadgeLightText,
        framingMode: MediaFramingMode? = nil,
        overlaySettings: OverlaySettings? = nil
    ) {
        self.images = images
        self.style = style
        self.fit = fit
        self.background = background
        self.blurredBackground = blurredBackground
        self.spacing = spacing
        self.cornerRadius = cornerRadius
        self.captureDates = captureDates
        self.showCaptureDates = showCaptureDates
        self.captureDateStyle = captureDateStyle
        self.framingMode = framingMode ?? (fit ? .fitWithBorder : .fillZoom)
        self.overlaySettings = overlaySettings
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                MediaBackdropView(
                    images: images,
                    mode: MediaBackdropResolver.mode(imageCount: images.count, blurredBackground: blurredBackground),
                    // The legacy backgroundHex value is retained for
                    // migration compatibility, but the slideshow must not
                    // reveal a fixed blue/background treatment.
                    fallback: MediaBackdropView.neutralFallback
                )
                content(in: proxy.size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showCaptureDates {
                    CaptureDateOverlayLayer(
                        imageSizes: images.map(\.canvasDisplaySize),
                        captureDates: captureDates,
                        style: style,
                        canvasSize: proxy.size,
                        spacing: spacing,
                        badgeStyle: captureDateStyle,
                        overlaySettings: overlaySettings
                    )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipShape(RoundedRectangle(cornerRadius: max(0, cornerRadius), style: .continuous))
            .clipped()
        }
    }

    @ViewBuilder private func content(in size: CGSize) -> some View {
        let selection = resolvedSelection(in: size)
        let placements = CaptureDateOverlayGeometry.tileFrames(
            imageSizes: images.map(\.canvasDisplaySize),
            style: style,
            canvasSize: size,
            spacing: spacing
        )
        ZStack(alignment: .topLeading) {
            ForEach(Array(placements.enumerated()), id: \.element.index) { tilePosition, element in
                let placement = element
                let horizontalAlignment = MediaTileAlignmentPolicy.horizontalAlignment(
                    tilePosition: tilePosition,
                    layout: selection.style
                )
                imageView(
                    at: placement.index,
                    selectedLayout: selection.style,
                    viewportSize: placement.frame.size,
                    horizontalAlignment: horizontalAlignment
                )
                    .frame(width: placement.frame.width, height: placement.frame.height)
                    // The tile frame is already in canvas coordinates. Offset
                    // the complete tile from the top-leading origin instead
                    // of using position(), which creates a second center-based
                    // coordinate system for the nested media view.
                    .offset(x: placement.frame.minX, y: placement.frame.minY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func resolvedSelection(in size: CGSize) -> PairLayoutSelection {
        LayoutCanvasSelectionResolver.selection(style: style, imageSizes: images.map(\.canvasDisplaySize), canvasSize: size)
    }

    @ViewBuilder
    private func imageView(
        at index: Int,
        selectedLayout: LayoutStyle,
        viewportSize: CGSize,
        horizontalAlignment: MediaFramingGeometry.HorizontalAlignment
    ) -> some View {
        if images.indices.contains(index) {
            let image = images[index]
            let plan = MediaFramingGeometry.plan(
                imageSize: image.canvasDisplaySize,
                viewportSize: viewportSize,
                preferredMode: framingMode,
                requestedLayout: style,
                selectedLayout: selectedLayout,
                horizontalAlignment: horizontalAlignment
            )
            let alignment = horizontalAlignment.swiftUIAlignment
            Group {
                if plan.mode == .fillZoom {
                    Image(uiImage: images[index])
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(uiImage: images[index])
                        .resizable()
                        .scaledToFit()
                }
            }
            // Resolve the mode directly against the final tile proposal.
            // Passing an oversized rendered frame through a nested SwiftUI
            // frame can be clamped back to the tile's fit size, creating a
            // one-sided inset for only the taller source in a pair.
            .frame(width: viewportSize.width, height: viewportSize.height, alignment: alignment)
            .clipped()
        } else { Color.clear }
    }
}

private extension MediaFramingGeometry.HorizontalAlignment {
    var swiftUIAlignment: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

enum LayoutCanvasSelectionResolver {
    static func selection(style: LayoutStyle, imageSizes: [CGSize], canvasSize: CGSize) -> PairLayoutSelection {
        switch style {
        case .automatic, .portraitPair:
            return PairLayoutResolver.selection(imageSizes: imageSizes, canvasSize: canvasSize)
        default:
            return PairLayoutSelection(style: style, indices: Array(imageSizes.indices))
        }
    }
}

/// Places capture-date badges in final tile coordinates. This layer is kept
/// outside the zoomed foreground media in PlayerView, so a pinch or drag can
/// never carry a badge beyond the device's safe tile bounds.
struct CaptureDateOverlayLayer: View {
    let imageSizes: [CGSize]
    let captureDates: [Date?]
    let style: LayoutStyle
    let canvasSize: CGSize
    let spacing: CGFloat
    let badgeStyle: CaptureDateBadgeStyle
    let overlaySettings: OverlaySettings?

    var body: some View {
        let placements = CaptureDateOverlayGeometry.tileFrames(
            imageSizes: imageSizes,
            style: style,
            canvasSize: canvasSize,
            spacing: spacing
        )
        ZStack(alignment: .topLeading) {
            ForEach(placements, id: \.index) { placement in
                if captureDates.indices.contains(placement.index), let date = captureDates[placement.index] {
                    ZStack(alignment: .bottomLeading) {
                        Color.clear
                        CaptureDateBadge(date: date, style: badgeStyle, textStrokeSettings: overlaySettings)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: max(0, placement.frame.width - 20), alignment: .leading)
                            .padding(.leading, 10)
                            .padding(.bottom, 10)
                    }
                    .frame(width: placement.frame.width, height: placement.frame.height)
                    .clipped()
                    .position(x: placement.frame.midX, y: placement.frame.midY)
                }
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Capture dates")
    }
}

/// A quiet per-tile date treatment used by both slideshow frames and the
/// settings preview. It stays inside the tile's clipped bounds and remains
/// legible over both bright and dark media without competing with the clock.
enum CaptureDateContrast: Equatable {
    case lightContent
    case darkContent
}

enum CaptureDateContrastResolver {
    static func contrast(forLuminance luminance: CGFloat) -> CaptureDateContrast {
        luminance >= 0.58 ? .darkContent : .lightContent
    }

    /// Samples the whole image into one pixel. This is deliberately cheap
    /// because badges are rendered for at most two visible tiles at a time.
    static func luminance(of image: UIImage) -> CGFloat {
        guard let cgImage = image.cgImage else { return 0.35 }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0.35 }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let red = CGFloat(pixel[0]) / 255
        let green = CGFloat(pixel[1]) / 255
        let blue = CGFloat(pixel[2]) / 255
        return (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
    }

    static func contrast(for image: UIImage?) -> CaptureDateContrast {
        guard let image else { return .lightContent }
        return contrast(forLuminance: luminance(of: image))
    }
}

struct CaptureDateBadge: View {
    let date: Date
    let style: CaptureDateBadgeStyle
    let image: UIImage?
    let textStrokeSettings: OverlaySettings?

    init(
        date: Date,
        style: CaptureDateBadgeStyle = .darkBadgeLightText,
        image: UIImage? = nil,
        textStrokeSettings: OverlaySettings? = nil
    ) {
        self.date = date
        self.style = style
        self.image = image
        self.textStrokeSettings = textStrokeSettings
    }

    var body: some View {
        let lightContent = style == .darkBadgeLightText
        label(lightContent: lightContent)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                (lightContent ? Color.black : Color.white).opacity(lightContent ? 0.48 : 0.62),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            // A small shadow is a minimal legibility safeguard without
            // switching styles per image.
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            .accessibilityLabel("Capture date \(date.formatted(date: .abbreviated, time: .omitted))")
    }

    @ViewBuilder
    private func label(lightContent: Bool) -> some View {
        let text = Text(date.formatted(date: .abbreviated, time: .omitted))
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle((lightContent ? Color.white : Color.black).opacity(0.86))
        if let textStrokeSettings {
            text.overlayTextStroke(settings: textStrokeSettings, mediaImage: image, opacity: 0.86)
        } else {
            text
        }
    }
}

enum PairMediaOrientation: Equatable {
    case portrait
    case landscape
    case unknown
}

struct PairLayoutSelection: Equatable {
    let style: LayoutStyle
    let indices: [Int]
}

enum PairLayoutResolver {
    static func orientation(for size: CGSize) -> PairMediaOrientation {
        guard size.width > 0, size.height > 0 else { return .unknown }
        return size.height > size.width ? .portrait : .landscape
    }

    static func targetOrientation(canvasSize: CGSize) -> PairMediaOrientation {
        canvasSize.height > canvasSize.width ? .landscape : .portrait
    }

    /// Keeps the current item as the first tile. A companion is only chosen
    /// when it has the same orientation as the current item and that
    /// orientation is the one appropriate for the device. A lone
    /// incompatible item is rendered aspect-fit instead of being stretched or
    /// cropped into a misleading pair.
    static func selection(imageSizes: [CGSize], canvasSize: CGSize) -> PairLayoutSelection {
        guard let first = imageSizes.first else { return PairLayoutSelection(style: .single, indices: []) }
        let target = targetOrientation(canvasSize: canvasSize)
        let firstOrientation = orientation(for: first)
        guard firstOrientation == target else {
            return PairLayoutSelection(style: .fitBlurred, indices: [0])
        }

        // Pair only the next queue item. Searching past an incompatible item
        // would make that intervening single photo disappear when playback
        // advances by displayed groups.
        guard imageSizes.indices.contains(1), orientation(for: imageSizes[1]) == target else {
            return PairLayoutSelection(style: .single, indices: [0])
        }
        let style: LayoutStyle = canvasSize.height > canvasSize.width ? .pairVertical : .pairHorizontal
        return PairLayoutSelection(style: style, indices: [0, 1])
    }

    static func style(imageSizes: [CGSize], canvasSize: CGSize) -> LayoutStyle {
        selection(imageSizes: imageSizes, canvasSize: canvasSize).style
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
