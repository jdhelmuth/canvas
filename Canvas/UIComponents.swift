import SwiftUI
import Foundation
import UIKit

/// SwiftUI has no built-in text outline modifier. Rendering a small ring of
/// colored copies behind the original glyph gives the same readable outline
/// treatment on iPadOS while keeping the control lightweight and animatable.
struct TextStrokeModifier: ViewModifier {
    let color: Color
    let width: CGFloat
    let enabled: Bool
    let opacity: Double

    private var offsets: [CGSize] {
        let radius = max(width, 0.5)
        return (0..<16).map { index in
            let angle = (Double(index) / 16.0) * Double.pi * 2
            return CGSize(
                width: CGFloat(cos(angle)) * radius,
                height: CGFloat(sin(angle)) * radius
            )
        }
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled && width > 0 {
            ZStack {
                ForEach(Array(offsets.enumerated()), id: \.offset) { _, offset in
                    content
                        .foregroundStyle(color.opacity(opacity))
                        .offset(offset)
                        .accessibilityHidden(true)
                }
                content
            }
        } else {
            content
        }
    }
}

extension View {
    func textStroke(color: Color, width: CGFloat, enabled: Bool, opacity: Double = 1) -> some View {
        modifier(TextStrokeModifier(color: color, width: width, enabled: enabled, opacity: opacity))
    }

    func overlayTextStroke(settings: OverlaySettings, mediaImage: UIImage?, opacity: Double = 1) -> some View {
        textStroke(
            color: OverlayTextStrokePolicy.color(settings.textStrokeColor, mediaImage: mediaImage).color,
            width: OverlayTextStrokePolicy.width(settings.textStrokeWidth),
            enabled: OverlayTextStrokePolicy.isEnabled(settings.textStrokeEnabled),
            opacity: opacity
        )
    }
}

/// Shared clock renderer used by both the proportional settings preview and
/// fullscreen playback. A single view keeps style, color, weight, and opacity
/// behavior identical in both places.
struct ClockOverlayView: View {
    let date: Date
    let settings: OverlaySettings
    let mediaImage: UIImage?

    init(date: Date, settings: OverlaySettings, mediaImage: UIImage? = nil) {
        self.date = date
        self.settings = settings
        self.mediaImage = mediaImage
    }

    private var clockSize: CGFloat { CGFloat(settings.clockSize ?? max(settings.fontSize, 64)) }
    private var textOpacity: Double {
        OverlayOpacityPolicy.values(backgroundOpacity: settings.opacity, clockOpacity: settings.clockOpacity).text
    }
    private var resolvedClockColor: ClockColor {
        let configured = settings.clockColor ?? .white
        return configured.isAdaptive ? AdaptiveClockColorResolver.color(for: mediaImage) : configured
    }
    private var color: Color { resolvedClockColor.color }
    private var strokeEnabled: Bool { OverlayTextStrokePolicy.isEnabled(settings.clockStrokeEnabled ?? settings.textStrokeEnabled) }
    private var strokeColor: Color { OverlayTextStrokePolicy.color(settings.clockStrokeColor ?? settings.textStrokeColor, mediaImage: mediaImage).color }
    private var strokeWidth: CGFloat { OverlayTextStrokePolicy.width(settings.clockStrokeWidth ?? settings.textStrokeWidth) }
    private var legibilityShadow: Color {
        resolvedClockColor == .black ? .white.opacity(0.34) : .black.opacity(0.34)
    }

    var body: some View {
        Group {
            if (settings.clockStyle ?? .digital) == .analog {
                AnalogClockView(
                    date: date,
                    face: settings.analogClockFace ?? .arabic,
                    color: color,
                    opacity: textOpacity,
                    font: settings.clockFont ?? .system,
                    weight: settings.clockWeight ?? .semibold,
                    strokeColor: strokeColor,
                    strokeWidth: strokeWidth,
                    strokeEnabled: strokeEnabled
                )
                .frame(width: clockSize, height: clockSize)
            } else {
                Text(date, style: .time)
                    .font(.system(size: clockSize, weight: (settings.clockWeight ?? .semibold).fontWeight, design: (settings.clockFont ?? .system).design))
                    .fontWidth((settings.clockWidth ?? .standard).fontWidth)
                    .foregroundStyle(color)
                    .textStroke(color: strokeColor, width: strokeWidth, enabled: strokeEnabled)
                    .opacity(textOpacity)
            }
        }
        .shadow(color: legibilityShadow, radius: 2, x: 0, y: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((settings.clockStyle ?? .digital) == .analog ? "Analog clock, \((settings.analogClockFace ?? .arabic).title)" : "Digital clock")
        .accessibilityValue(date.formatted(date: .omitted, time: .shortened))
    }
}

struct AnalogClockView: View {
    let date: Date
    let face: AnalogClockFace
    let color: Color
    let opacity: Double
    let font: ClockFont
    let weight: ClockWeight
    let strokeColor: Color
    let strokeWidth: CGFloat
    let strokeEnabled: Bool

    private var calendar: Calendar { Calendar.current }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let radius = max(0, side * 0.40)
            let hour = Double(calendar.component(.hour, from: date) % 12)
            let minute = Double(calendar.component(.minute, from: date))
            let second = Double(calendar.component(.second, from: date))
            let hourAngle = (hour + minute / 60) * 30
            let minuteAngle = (minute + second / 60) * 6
            let secondAngle = second * 6

            ZStack {
                Circle()
                    .fill(.black.opacity(0.12))
                    .overlay(Circle().stroke(color.opacity(opacity * 0.8), lineWidth: max(1, side * 0.014)))
                faceMarkers(side: side, center: center, radius: radius)
                AnalogClockHand(angle: hourAngle, length: side * 0.23)
                    .stroke(color.opacity(opacity), style: StrokeStyle(lineWidth: max(2, side * 0.035), lineCap: .round))
                AnalogClockHand(angle: minuteAngle, length: side * 0.32)
                    .stroke(color.opacity(opacity), style: StrokeStyle(lineWidth: max(1.5, side * 0.022), lineCap: .round))
                AnalogClockHand(angle: secondAngle, length: side * 0.35)
                    .stroke(color.opacity(opacity * 0.78), style: StrokeStyle(lineWidth: max(1, side * 0.01), lineCap: .round))
                Circle()
                    .fill(color.opacity(opacity))
                    .frame(width: max(4, side * 0.045), height: max(4, side * 0.045))
                    .position(center)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Analog clock, \(face.title)")
        .accessibilityValue(date.formatted(date: .omitted, time: .shortened))
    }

    @ViewBuilder
    private func faceMarkers(side: CGFloat, center: CGPoint, radius: CGFloat) -> some View {
        switch face {
        case .arabic, .roman:
            let labels = face == .arabic
                ? (1...12).map(String.init)
                : ["XII", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI"]
            let markerSize = max(7, side * 0.105)
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                let angle = Double(index) * 30 * Double.pi / 180
                markerLabel(label, size: markerSize, center: center, radius: radius, angle: angle)
            }
        case .dashes:
            let markerWidth = max(2, side * 0.018)
            let markerHeight = max(8, side * 0.095)
            ForEach(0..<12, id: \.self) { index in
                let angle = Double(index) * 30 * Double.pi / 180
                dashMarker(width: markerWidth, height: markerHeight, center: center, radius: radius, angle: angle, rotation: Double(index) * 30)
            }
        }
    }

    private func markerLabel(_ label: String, size: CGFloat, center: CGPoint, radius: CGFloat, angle: Double) -> some View {
        Text(label)
            .font(.system(size: size))
            .fontWeight(weight.fontWeight)
            .fontDesign(font.design)
            .foregroundStyle(color.opacity(opacity))
            .textStroke(color: strokeColor, width: strokeWidth, enabled: strokeEnabled, opacity: opacity)
            .position(
                x: center.x + CGFloat(sin(angle)) * radius,
                y: center.y - CGFloat(cos(angle)) * radius
            )
    }

    private func dashMarker(width: CGFloat, height: CGFloat, center: CGPoint, radius: CGFloat, angle: Double, rotation: Double) -> some View {
        Capsule()
            .fill(color.opacity(opacity))
            .frame(width: width, height: height)
            .rotationEffect(.degrees(rotation))
            .position(
                x: center.x + CGFloat(sin(angle)) * radius,
                y: center.y - CGFloat(cos(angle)) * radius
            )
    }
}

private struct AnalogClockHand: Shape {
    let angle: Double
    let length: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radians = angle * Double.pi / 180
        let end = CGPoint(
            x: center.x + CGFloat(sin(radians)) * length,
            y: center.y - CGFloat(cos(radians)) * length
        )
        var path = Path()
        path.move(to: center)
        path.addLine(to: end)
        return path
    }
}

struct CanvasBackground: View {
    var body: some View {
        LinearGradient(colors: [Color(uiColor: .systemBackground), Color(uiColor: .secondarySystemBackground)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }
}

/// A friendly condition mark shared by the live frame and Settings preview.
/// WeatherKit supplies the SF Symbol name and multicolor treatment, while the
/// layered native material keeps it legible over changing photos.
struct WeatherConditionGlyph: View {
    let symbolName: String
    var diameter: CGFloat = 24

    var body: some View {
        ZStack {
            Circle()
                .fill(.thinMaterial)
            Circle()
                .fill(Color.cyan.opacity(0.14))
            Image(systemName: symbolName)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: diameter * 0.54, weight: .semibold))
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        }
        .frame(width: diameter, height: diameter)
        .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 0.7))
        .accessibilityHidden(true)
    }
}

struct WeatherOverlayWidget: View {
    let snapshot: CanvasWeatherSnapshot?
    let status: WeatherOverlayStatus
    let isUsingCachedSnapshot: Bool
    let settings: OverlaySettings
    let mediaImage: UIImage?
    let textOpacity: Double
    let attributionURL: URL?
    let attributionMarkURL: URL?

    private struct Metric: Identifiable {
        let id: String
        let icon: String
        let text: String
        let accessibilityText: String
        var tint: Color = .white.opacity(0.82)
    }

    var body: some View {
        Group {
            if let snapshot {
                VStack(alignment: .leading, spacing: 8) {
                    if settings.effectiveWeatherShowConditions {
                        conditions(snapshot)
                    }

                    if !metrics(for: snapshot).isEmpty {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 92, maximum: 168), spacing: 6)],
                            alignment: .leading,
                            spacing: 6
                        ) {
                            ForEach(metrics(for: snapshot)) { metric in
                                metricChip(metric)
                            }
                        }
                    }

                    if settings.effectiveWeatherShowNextHour,
                       let temperature = snapshot.nextHourTemperature,
                       let condition = snapshot.nextHourCondition {
                        HStack(spacing: 7) {
                            Image(systemName: snapshot.nextHourSymbolName ?? "clock")
                                .symbolRenderingMode(.multicolor)
                                .frame(width: 20)
                            Text("Next hour")
                                .fontWeight(.semibold)
                            Text("\(temperature) · \(condition)")
                                .foregroundStyle(.white.opacity(textOpacity * 0.78))
                                .lineLimit(1)
                        }
                        .font(.system(size: max(12, settings.fontSize * 0.48), weight: settings.effectiveTextWeight.fontWeight, design: .rounded))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Next hour, \(temperature), \(condition)")
                    }

                    HStack(spacing: 2) {
                        if isUsingCachedSnapshot || snapshot.isStale {
                            Label("Last known", systemImage: "clock.arrow.circlepath")
                                .font(.system(size: max(10, settings.fontSize * 0.42), weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(textOpacity * 0.7))
                                .accessibilityLabel("Last known weather")
                        }
                        Spacer(minLength: 0)
                        WeatherLegalLink(destination: attributionURL, markURL: attributionMarkURL)
                        if settings.effectiveWeatherShowAirQuality, snapshot.airQualityIndex != nil {
                            AirQualityLegalLink()
                        }
                    }
                    .frame(height: 18)
                }
                .frame(width: widgetWidth(for: snapshot), alignment: .leading)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.075))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(0.16), lineWidth: 0.7)
                        }
                }
                .accessibilityElement(children: .contain)
            } else {
                Label(status.title, systemImage: status.systemImage)
                    .font(.system(size: max(12, settings.fontSize * 0.54), weight: settings.effectiveTextWeight.fontWeight, design: .rounded))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityLabel("Weather, \(status.title)")
            }
        }
        .foregroundStyle(.white.opacity(textOpacity))
        .accessibilityIdentifier("canvas.weather.overlay")
    }

    private func conditions(_ snapshot: CanvasWeatherSnapshot) -> some View {
        HStack(spacing: 10) {
            WeatherConditionGlyph(
                symbolName: snapshot.symbolName,
                diameter: min(max(38, settings.fontSize * 1.85), 62)
            )
            VStack(alignment: .leading, spacing: 0) {
                Text(snapshot.temperature)
                    .font(.system(size: min(max(24, settings.fontSize * 1.28), 58), weight: .medium, design: .rounded))
                    .fontWidth(.condensed)
                    .overlayTextStroke(settings: settings, mediaImage: mediaImage, opacity: textOpacity)
                Text(snapshot.condition)
                    .font(.system(size: max(12, settings.fontSize * 0.54), weight: settings.effectiveTextWeight.fontWeight, design: .rounded))
                    .foregroundStyle(.white.opacity(textOpacity * 0.78))
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(snapshot.temperature), \(snapshot.condition)")
    }

    private func metrics(for snapshot: CanvasWeatherSnapshot) -> [Metric] {
        var result: [Metric] = []
        if settings.effectiveWeatherShowAirQuality, let value = snapshot.airQualityIndex {
            let category = CanvasAirQualityCategory.category(for: value)
            result.append(Metric(
                id: "air-quality",
                icon: "aqi.medium",
                text: "AQI \(value)",
                accessibilityText: "Air quality index \(value), \(category.title)",
                tint: category.tint
            ))
        }
        if settings.effectiveWeatherShowFeelsLike, let value = snapshot.apparentTemperature {
            result.append(Metric(id: "feels-like", icon: "thermometer.medium", text: "Feels \(value)", accessibilityText: "Feels like \(value)"))
        }
        if settings.effectiveWeatherShowHumidity, let value = snapshot.humidityPercent {
            result.append(Metric(id: "humidity", icon: "humidity.fill", text: "\(value)%", accessibilityText: "Humidity \(value) percent", tint: .cyan))
        }
        if settings.effectiveWeatherShowWind, let value = snapshot.wind {
            result.append(Metric(id: "wind", icon: "wind", text: value, accessibilityText: "Wind \(value)"))
        }
        if settings.effectiveWeatherShowUVIndex, let value = snapshot.uvIndex {
            result.append(Metric(id: "uv", icon: "sun.max.fill", text: "UV \(value)", accessibilityText: "UV index \(value)", tint: .yellow))
        }
        if settings.effectiveWeatherShowPrecipitationChance, let value = snapshot.precipitationChancePercent {
            result.append(Metric(id: "precipitation", icon: "umbrella.fill", text: "\(value)%", accessibilityText: "Precipitation chance \(value) percent", tint: .blue))
        }
        if settings.effectiveWeatherShowDailyHighLow,
           let high = snapshot.highTemperature,
           let low = snapshot.lowTemperature {
            result.append(Metric(id: "high-low", icon: "arrow.up.arrow.down", text: "H \(high)  L \(low)", accessibilityText: "High \(high), low \(low)"))
        }
        if settings.effectiveWeatherShowSunriseSunset,
           let sunrise = snapshot.sunrise,
           let sunset = snapshot.sunset {
            result.append(Metric(
                id: "sun",
                icon: "sunrise.fill",
                text: "\(compactTime(sunrise)) · \(compactTime(sunset))",
                accessibilityText: "Sunrise \(sunrise), sunset \(sunset)",
                tint: .orange
            ))
        }
        return result
    }

    private func compactTime(_ value: String) -> String {
        value
            .replacingOccurrences(of: " AM", with: "")
            .replacingOccurrences(of: " PM", with: "")
    }

    private func metricChip(_ metric: Metric) -> some View {
        HStack(spacing: 5) {
            Image(systemName: metric.icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(metric.tint)
            Text(metric.text)
                .lineLimit(1)
                .minimumScaleFactor(0.74)
        }
        .font(.system(size: max(11, settings.fontSize * 0.47), weight: .semibold, design: .rounded))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.09), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric.accessibilityText)
    }

    private func widgetWidth(for snapshot: CanvasWeatherSnapshot) -> CGFloat {
        let hasExpandedDetails = metrics(for: snapshot).count > 1 || settings.effectiveWeatherShowNextHour
        let base = hasExpandedDetails ? 350.0 : 258.0
        let scale = min(max(settings.fontSize / 22, 0.9), 1.25)
        return base * scale
    }
}

private extension CanvasAirQualityCategory {
    var tint: Color {
        switch self {
        case .good: .green
        case .moderate: .yellow
        case .unhealthySensitive: .orange
        case .unhealthy: .red
        case .veryUnhealthy: .purple
        case .hazardous: .pink
        }
    }
}

/// WeatherKit's own square mark provides a discrete route to its legal sources
/// page without placing provider names or source text in the normal weather UI.
struct WeatherLegalLink: View {
    let destination: URL?
    let markURL: URL?

    @ViewBuilder
    var body: some View {
        if let destination {
            Link(destination: destination) {
                AsyncImage(url: markURL) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "info.circle")
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                .frame(width: 15, height: 15)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Weather attribution and data sources")
        }
    }
}

struct AirQualityLegalLink: View {
    static let destination = URL(string: "https://open-meteo.com/en/docs/air-quality-api")!

    var body: some View {
        Link(destination: Self.destination) {
            Image(systemName: "aqi.medium")
                .symbolRenderingMode(.hierarchical)
                .frame(width: 15, height: 15)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Air quality attribution and data sources")
    }
}

struct WeatherDataAttributionView: View {
    let weatherDestination: URL?
    let weatherMarkURL: URL?

    var body: some View {
        HStack(spacing: 6) {
            WeatherLegalLink(destination: weatherDestination, markURL: weatherMarkURL)
            Link(destination: AirQualityLegalLink.destination) {
                Label("AQI: Open-Meteo · CAMS", systemImage: "aqi.medium")
                    .font(.caption)
            }
            .accessibilityLabel("Air quality data from Open-Meteo and the Copernicus Atmosphere Monitoring Service")
        }
    }
}

struct AppMark: View {
    let size: CGFloat
    var body: some View {
        Group {
            if let icon = Self.bundledAppIcon {
                Image(uiImage: icon).resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(Color(red: 0.04, green: 0.08, blue: 0.17))
                    .overlay(Image(systemName: "photo.artframe").foregroundStyle(.orange))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: size * 0.12, y: size * 0.06)
        .accessibilityHidden(true)
    }

    private static let bundledAppIcon: UIImage? = {
        let info = Bundle.main.infoDictionary
        let iconDictionaries = [info?["CFBundleIcons~ipad"], info?["CFBundleIcons"]]
        for value in iconDictionaries {
            guard let icons = value as? [String: Any],
                  let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
                  let files = primary["CFBundleIconFiles"] as? [String] else { continue }
            for filename in files.reversed() {
                if let image = UIImage(named: filename) { return image }
            }
        }
        return UIImage(named: "AppIcon")
    }()
}

struct ArcShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(); path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.18))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY + rect.height * 0.12), control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.08))
        return path
    }
}

struct PrimaryCanvasButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).foregroundStyle(.white).padding(.horizontal, 20).padding(.vertical, 13).background(LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing), in: Capsule()).opacity(configuration.isPressed ? 0.78 : 1)
    }
}
struct SecondaryCanvasButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).foregroundStyle(.primary).padding(.horizontal, 18).padding(.vertical, 12).background(.thinMaterial, in: Capsule()).overlay(Capsule().stroke(.secondary.opacity(0.18))).opacity(configuration.isPressed ? 0.7 : 1)
    }
}
extension ButtonStyle where Self == PrimaryCanvasButtonStyle { static var primaryCanvas: Self { .init() } }
extension ButtonStyle where Self == SecondaryCanvasButtonStyle { static var secondaryCanvas: Self { .init() } }

extension Double {
    var cleanSeconds: String {
        if self.truncatingRemainder(dividingBy: 60) == 0 && self >= 60 { return "\(Int(self / 60)) min" }
        return self == floor(self) ? "\(Int(self)) sec" : "\(String(format: "%.1f", self)) sec"
    }
}

extension Color {
    init(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var number: UInt64 = 0; Scanner(string: value).scanHexInt64(&number)
        self.init(.sRGB, red: Double((number >> 16) & 0xff) / 255, green: Double((number >> 8) & 0xff) / 255, blue: Double(number & 0xff), opacity: 1)
    }
}
