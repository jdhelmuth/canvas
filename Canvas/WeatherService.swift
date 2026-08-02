import Combine
import Foundation

/// App-owned weather data. The public build keeps this value type so future
/// provider data cannot leak provider-specific models into the UI.
struct CanvasWeatherSnapshot: Codable, Equatable, Sendable {
    let symbolName: String
    let condition: String
    let temperature: String
    let attributionText: String
    let updatedAt: Date

    init(symbolName: String, condition: String, temperature: String, attributionText: String, updatedAt: Date = .now) {
        self.symbolName = symbolName
        self.condition = condition
        self.temperature = temperature
        self.attributionText = attributionText
        self.updatedAt = updatedAt
    }

    var isStale: Bool { Date().timeIntervalSince(updatedAt) > 6 * 60 * 60 }

    /// A stale cache is explicitly labelled so it can never look live.
    var displayText: String {
        let suffix = isStale ? " · Last known" : ""
        return "\(temperature) · \(condition)\(suffix)"
    }
}

/// User-facing states for the optional weather row. The public build reports
/// the provider as unavailable instead of requesting location or fabricating
/// conditions.
enum WeatherOverlayStatus: Equatable, Sendable {
    case disabled
    case needsLocationPermission
    case locationDenied
    case locationRestricted
    case requestingLocation
    case locating
    case fetching
    case live
    case networkUnavailable
    case serviceUnavailable
    case entitlementMissing
    case locationUnavailable

    var title: String {
        switch self {
        case .disabled: "Weather off"
        case .needsLocationPermission: "Weather unavailable"
        case .locationDenied: "Weather unavailable"
        case .locationRestricted: "Weather unavailable"
        case .requestingLocation: "Weather unavailable"
        case .locating: "Weather unavailable"
        case .fetching: "Weather unavailable"
        case .live: "Weather unavailable"
        case .networkUnavailable: "Weather unavailable"
        case .serviceUnavailable: "Weather unavailable"
        case .entitlementMissing: "Weather unavailable"
        case .locationUnavailable: "Weather unavailable"
        }
    }

    var message: String {
        switch self {
        case .disabled:
            "Turn on Current weather to see whether this release includes a provider."
        default:
            "Weather overlays are not included in this public release."
        }
    }

    var systemImage: String {
        switch self {
        case .disabled: "cloud.sun"
        default: "cloud.slash"
        }
    }
}

/// Keeps the settings and player surfaces stable while the public build has
/// no weather provider. A future reviewed provider can replace this service
/// without changing the rest of Canvas.
@MainActor
final class CanvasWeatherService: ObservableObject {
    @Published private(set) var snapshot: CanvasWeatherSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var attributionURL: URL?
    @Published private(set) var status: WeatherOverlayStatus = .disabled
    @Published private(set) var isUsingCachedSnapshot = false

    init() {}

    func update(showWeather: Bool) {
        guard showWeather else {
            clear()
            return
        }

        snapshot = nil
        attributionURL = nil
        isLoading = false
        isUsingCachedSnapshot = false
        status = .entitlementMissing
        errorMessage = status.message
    }

    /// Retained as a no-op so existing settings lifecycle calls remain safe.
    func refreshAuthorization() {}

    func clear() {
        snapshot = nil
        attributionURL = nil
        errorMessage = nil
        isLoading = false
        status = .disabled
        isUsingCachedSnapshot = false
    }
}
