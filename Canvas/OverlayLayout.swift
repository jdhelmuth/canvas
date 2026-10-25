import SwiftUI

/// Positions describe a fraction of the available travel, not screen pixels.
/// This keeps edge-anchored blocks visible when content or window size changes.
struct OverlayPlacement: Codable, Equatable {
    var x: Double
    var y: Double
    var alignment: OverlayTextAlignment = .automatic
}

enum OverlayTextAlignment: String, Codable, CaseIterable, Identifiable {
    case automatic, left, right
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    func isTrailing(at x: Double) -> Bool { self == .right || (self == .automatic && x > 0.5) }
}

enum OverlayBlock: String, Codable, CaseIterable, Identifiable {
    case clock, weather, scale, captureDate
    var id: String { rawValue }
    var title: String {
        switch self {
        case .clock: "Clock & details"
        case .weather: "Weather"
        case .scale: "Weather scale"
        case .captureDate: "Photo date"
        }
    }
}

struct OverlayOrientationLayout: Codable, Equatable {
    var placements: [String: OverlayPlacement] = [:]
    subscript(_ block: OverlayBlock) -> OverlayPlacement? {
        get { placements[block.rawValue] }
        set { placements[block.rawValue] = newValue }
    }
}

struct OverlayLayouts: Codable, Equatable {
    var portrait: OverlayOrientationLayout?
    var landscape: OverlayOrientationLayout?
    var snapping = true
    func layout(portrait isPortrait: Bool) -> OverlayOrientationLayout? { isPortrait ? portrait : landscape }
    mutating func set(_ layout: OverlayOrientationLayout?, portrait isPortrait: Bool) {
        if isPortrait { portrait = layout } else { landscape = layout }
    }
}

enum OverlayLayoutGeometry {
    static func unit(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
    static func bounds(size: CGSize, insets: EdgeInsets) -> CGRect {
        let left = max(24, insets.leading + 12)
        let right = max(24, insets.trailing + 12)
        let top = max(80, insets.top + 12)
        let bottom = max(24, insets.bottom + 12)
        return CGRect(x: left, y: top, width: max(1, size.width - left - right), height: max(1, size.height - top - bottom))
    }
    static func fittedSize(_ natural: CGSize, in bounds: CGRect, maxWidth: CGFloat? = nil) -> CGSize {
        let width = max(1, natural.width), height = max(1, natural.height)
        let scale = min(1, min((maxWidth ?? bounds.width) / width, bounds.height / height))
        return CGSize(width: width * scale, height: height * scale)
    }
    static func frame(size: CGSize, placement: OverlayPlacement, bounds: CGRect) -> CGRect {
        CGRect(x: bounds.minX + (bounds.width - size.width) * unit(placement.x),
               y: bounds.minY + (bounds.height - size.height) * unit(placement.y), width: size.width, height: size.height)
    }
    static func placement(origin: CGPoint, size: CGSize, bounds: CGRect, snapping: Bool, alignment: OverlayTextAlignment) -> OverlayPlacement {
        func coordinate(_ value: CGFloat, start: CGFloat, travel: CGFloat) -> Double {
            guard travel > 0 else { return 0 }
            let result = unit(Double((value - start) / travel))
            if snapping {
                for target in [0.0, 0.5, 1.0] where abs(result - target) * travel <= 14 { return target }
            }
            return result
        }
        return OverlayPlacement(x: coordinate(origin.x, start: bounds.minX, travel: bounds.width - size.width),
                                y: coordinate(origin.y, start: bounds.minY, travel: bounds.height - size.height), alignment: alignment)
    }
    static func defaults(block: OverlayBlock, size: CGSize, clock: CGSize, weather: CGSize, bounds: CGRect, portrait: Bool, position: OverlayPosition) -> OverlayPlacement {
        if block == .scale { return OverlayPlacement(x: 1, y: 0.5) }
        if block == .captureDate { return OverlayPlacement(x: 0, y: 1) }
        let gap: CGFloat = clock.width > 0 && weather.width > 0 ? 15 : 0
        let groupWidth = clock.width + weather.width + gap
        let groupHeight = max(clock.height, weather.height)
        let trailing = !portrait && (position == .topTrailing || position == .bottomTrailing)
        let top = !portrait && (position == .topLeading || position == .topTrailing)
        let centered = !portrait && position == .center
        let groupX = centered ? bounds.midX - groupWidth / 2 : trailing ? bounds.maxX - groupWidth : bounds.minX
        let groupY = centered ? bounds.midY - groupHeight / 2 : top ? bounds.minY : bounds.maxY - groupHeight
        let origin = CGPoint(x: groupX + (block == .weather && clock.width > 0 ? clock.width + gap : 0),
                             y: portrait ? bounds.maxY - size.height : groupY + (groupHeight - size.height) / 2)
        // Automatic alignment follows the block position; explicit overrides
        // remain part of the saved placement.
        return placement(origin: origin, size: size, bounds: bounds, snapping: false, alignment: .automatic)
    }
}

private struct OverlayBlockSizes: PreferenceKey {
    static var defaultValue: [OverlayBlock: CGSize] = [:]
    static func reduce(value: inout [OverlayBlock: CGSize], nextValue: () -> [OverlayBlock: CGSize]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

struct MovableOverlayCanvas<Content: View>: View {
    let size: CGSize
    let insets: EdgeInsets
    let blocks: [OverlayBlock]
    let layouts: OverlayLayouts
    let legacyPosition: OverlayPosition
    let editing: Bool
    @Binding var selected: OverlayBlock
    let onPlace: (OverlayBlock, OverlayPlacement) -> Void
    let onResolve: ([OverlayBlock: OverlayPlacement]) -> Void
    @ViewBuilder let content: (OverlayBlock, Bool) -> Content
    @State private var measured: [OverlayBlock: CGSize] = [:]

    var body: some View {
        let bounds = OverlayLayoutGeometry.bounds(size: size, insets: insets)
        let portrait = size.height > size.width
        let layout = layouts.layout(portrait: portrait)
        let clockNatural = blocks.contains(.clock) ? measured[.clock, default: CGSize(width: 240, height: 150)] : .zero
        let weatherNatural = blocks.contains(.weather) ? measured[.weather, default: CGSize(width: 280, height: 200)] : .zero
        let scaleWidth = blocks.contains(.scale) ? measured[.scale, default: CGSize(width: 146, height: 300)].width + 12 : 0
        let available = max(1, bounds.width - scaleWidth - (clockNatural.width > 0 && weatherNatural.width > 0 ? 15 : 0))
        let ratio = min(1, available / max(1, clockNatural.width + weatherNatural.width))
        let pairBounds = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width - scaleWidth, height: max(1, bounds.height - (blocks.contains(.captureDate) ? measured[.captureDate, default: CGSize(width: 100, height: 40)].height : 0)))
        let clock = clockNatural == .zero ? .zero : OverlayLayoutGeometry.fittedSize(clockNatural, in: pairBounds, maxWidth: clockNatural.width * ratio)
        let weather = weatherNatural == .zero ? .zero : OverlayLayoutGeometry.fittedSize(weatherNatural, in: pairBounds, maxWidth: weatherNatural.width * ratio)
        let defaults = Dictionary(uniqueKeysWithValues: blocks.map { block in
            let fitted = block == .clock ? clock : block == .weather ? weather : OverlayLayoutGeometry.fittedSize(measured[block, default: CGSize(width: 240, height: 150)], in: bounds)
            let targetBounds = block == .clock || block == .weather ? pairBounds : bounds
            let local = OverlayLayoutGeometry.defaults(block: block, size: fitted, clock: clock, weather: weather, bounds: targetBounds, portrait: portrait, position: legacyPosition)
            let frame = OverlayLayoutGeometry.frame(size: fitted, placement: local, bounds: targetBounds)
            return (block, OverlayLayoutGeometry.placement(origin: frame.origin, size: fitted, bounds: bounds, snapping: false, alignment: local.alignment))
        })
        ZStack(alignment: .topLeading) {
            ForEach(blocks) { block in
                let natural = measured[block, default: CGSize(width: 240, height: 150)]
                let fitted = block == .clock ? clock : block == .weather ? weather : OverlayLayoutGeometry.fittedSize(natural, in: bounds)
                let placement = layout?[block] ?? defaults[block]!
                let frame = OverlayLayoutGeometry.frame(size: fitted, placement: placement, bounds: bounds)
                MovableOverlayUnit(block: block, natural: natural, frame: frame, bounds: bounds,
                                   placement: placement, editing: editing, selected: selected == block,
                                   snapping: layouts.snapping, select: { selected = block }, place: { onPlace(block, $0) }) {
                    content(block, placement.alignment.isTrailing(at: placement.x))
                        .fixedSize()
                        .background(GeometryReader { proxy in Color.clear.preference(key: OverlayBlockSizes.self, value: [block: proxy.size]) })
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .onPreferenceChange(OverlayBlockSizes.self) { measured = $0 }
        .onChange(of: defaults, initial: true) { _, value in onResolve(value) }
    }
}

private struct MovableOverlayUnit<Content: View>: View {
    let block: OverlayBlock
    let natural: CGSize
    let frame: CGRect
    let bounds: CGRect
    let placement: OverlayPlacement
    let editing: Bool
    let selected: Bool
    let snapping: Bool
    let select: () -> Void
    let place: (OverlayPlacement) -> Void
    @ViewBuilder let content: () -> Content
    @GestureState private var translation: CGSize = .zero

    var body: some View {
        let moved = OverlayLayoutGeometry.placement(origin: CGPoint(x: frame.minX + translation.width, y: frame.minY + translation.height), size: frame.size, bounds: bounds, snapping: false, alignment: placement.alignment)
        let visibleFrame = OverlayLayoutGeometry.frame(size: frame.size, placement: moved, bounds: bounds)
        content()
            .scaleEffect(frame.width / max(1, natural.width), anchor: .topLeading)
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
            .overlay {
                if editing {
                    RoundedRectangle(cornerRadius: 14).stroke(selected ? Color.orange : .white.opacity(0.6), style: StrokeStyle(lineWidth: selected ? 3 : 1, dash: selected ? [] : [6, 4]))
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if editing {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { select() }
                        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                            .updating($translation) { value, state, _ in state = value.translation }
                            .onChanged { _ in select() }
                            .onEnded { value in
                                place(OverlayLayoutGeometry.placement(origin: CGPoint(x: frame.minX + value.translation.width, y: frame.minY + value.translation.height), size: frame.size, bounds: bounds, snapping: snapping, alignment: placement.alignment))
                            })
                        .accessibilityLabel("Move \(block.title)")
                        .accessibilityIdentifier("layout-move-\(block.rawValue)")
                        .accessibilityAddTraits(.isButton)
                }
            }
            .position(x: visibleFrame.midX, y: visibleFrame.midY)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(block == .weather ? "canvas.weather.overlay" : "layout-block-\(block.rawValue)")
    }
}
