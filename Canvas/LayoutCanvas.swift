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
        framingMode: MediaFramingMode? = nil
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
                        badgeStyle: captureDateStyle
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
        switch selection.style {
        case .pairHorizontal, .portraitPair:
            HStack(spacing: spacing) {
                imageView(at: selection.indices[safe: 0] ?? 0, selectedLayout: selection.style)
                imageView(at: selection.indices[safe: 1] ?? 1, selectedLayout: selection.style)
            }
        case .pairVertical:
            VStack(spacing: spacing) {
                imageView(at: selection.indices[safe: 0] ?? 0, selectedLayout: selection.style)
                imageView(at: selection.indices[safe: 1] ?? 1, selectedLayout: selection.style)
            }
        case .collageThree:
            HStack(spacing: spacing) {
                imageView(at: selection.indices[safe: 0] ?? 0, selectedLayout: selection.style)
                VStack(spacing: spacing) {
                    if selection.indices.count > 1 { imageView(at: selection.indices[1], selectedLayout: selection.style) }
                    if selection.indices.count > 2 { imageView(at: selection.indices[2], selectedLayout: selection.style) }
                }
            }
        case .gridFour:
            LazyVGrid(columns: [GridItem(.flexible(), spacing: spacing), GridItem(.flexible(), spacing: spacing)], spacing: spacing) {
                ForEach(selection.indices.prefix(4), id: \.self) { index in imageView(at: index, selectedLayout: selection.style) }
            }
        case .fitBlurred:
            imageView(at: selection.indices.first ?? 0, selectedLayout: selection.style)
        default:
            imageView(at: selection.indices.first ?? 0, selectedLayout: selection.style)
        }
    }

    private func resolvedSelection(in size: CGSize) -> PairLayoutSelection {
        LayoutCanvasSelectionResolver.selection(style: style, imageSizes: images.map(\.canvasDisplaySize), canvasSize: size)
    }

    @ViewBuilder private func imageView(at index: Int, selectedLayout: LayoutStyle) -> some View {
        if images.indices.contains(index) {
            GeometryReader { proxy in
                let image = images[index]
                let plan = MediaFramingGeometry.plan(
                    imageSize: image.canvasDisplaySize,
                    viewportSize: proxy.size,
                    preferredMode: framingMode,
                    requestedLayout: style,
                    selectedLayout: selectedLayout
                )
                Image(uiImage: images[index])
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: plan.renderedFrame.width, height: plan.renderedFrame.height)
                    .position(x: plan.renderedFrame.midX, y: plan.renderedFrame.midY)
                    .clipped()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        } else { Color.clear }
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
                        CaptureDateBadge(date: date, style: badgeStyle)
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

    init(date: Date, style: CaptureDateBadgeStyle = .darkBadgeLightText, image: UIImage? = nil) {
        self.date = date
        self.style = style
    }

    var body: some View {
        let lightContent = style == .darkBadgeLightText
        Text(date.formatted(date: .abbreviated, time: .omitted))
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle((lightContent ? Color.white : Color.black).opacity(0.86))
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

        // ArraySlice keeps the original indices. Search the original index
        // space so a compatible companion after an incompatible candidate is
        // selected without an extra offset.
        guard let partner = imageSizes.indices.dropFirst().first(where: { orientation(for: imageSizes[$0]) == target }) else {
            return PairLayoutSelection(style: .single, indices: [0])
        }
        let style: LayoutStyle = canvasSize.height > canvasSize.width ? .pairVertical : .pairHorizontal
        return PairLayoutSelection(style: style, indices: [0, partner])
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
