import Combine
import CoreLocation
import Foundation
import WeatherKit

/// App-owned weather data. WeatherKit types stay behind this value type so the
/// player and settings surfaces do not depend on a provider-specific model.
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

/// User-facing states for the optional weather row. Every failure state is
/// actionable instead of silently leaving an empty overlay.
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
    case authorizationUnavailable
    case entitlementMissing
    case locationUnavailable

    var title: String {
        switch self {
        case .disabled: "Weather off"
        case .needsLocationPermission: "Allow location"
        case .locationDenied: "Location access off"
        case .locationRestricted: "Location restricted"
        case .requestingLocation: "Waiting for location"
        case .locating: "Finding location"
        case .fetching: "Loading weather"
        case .live: "Weather live"
        case .networkUnavailable: "Network unavailable"
        case .serviceUnavailable: "Weather service unavailable"
        case .authorizationUnavailable: "WeatherKit authorization unavailable"
        case .entitlementMissing: "WeatherKit not enabled"
        case .locationUnavailable: "Location unavailable"
        }
    }

    var message: String {
        switch self {
        case .disabled:
            "Turn on Current weather to show local conditions."
        case .needsLocationPermission:
            "Canvas uses your current location only to request local weather. Allow location to continue."
        case .locationDenied:
            "Canvas cannot request weather until Location Services is allowed in Settings."
        case .locationRestricted:
            "Location access is restricted on this iPad. Check Screen Time or device management settings."
        case .requestingLocation:
            "Waiting for the one-time location permission request."
        case .locating:
            "Finding the iPad's current location."
        case .fetching:
            "Loading current weather from WeatherKit."
        case .live:
            "Current weather is available."
        case .networkUnavailable:
            "WeatherKit could not reach the service. Check the network and retry."
        case .serviceUnavailable:
            "WeatherKit is temporarily unavailable. Retry in a moment."
        case .authorizationUnavailable:
            "Apple's WeatherKit authorization service could not issue a token. Confirm WeatherKit is enabled for com.johnhelmuth.canvas, then retry. If it is already enabled, this is an Apple-side service or account-sync issue."
        case .entitlementMissing:
            "WeatherKit access is not enabled for this signed build. Enable it for com.johnhelmuth.canvas in Apple Developer, then install a new build."
        case .locationUnavailable:
            "The iPad did not return a usable location. Move somewhere with a clear location signal and retry."
        }
    }

    var systemImage: String {
        switch self {
        case .disabled: "cloud.sun"
        case .live: "cloud.sun.fill"
        case .needsLocationPermission, .locationDenied, .locationRestricted: "location.slash"
        case .requestingLocation, .locating: "location"
        case .fetching: "arrow.triangle.2.circlepath"
        case .networkUnavailable: "wifi.exclamationmark"
        case .serviceUnavailable, .authorizationUnavailable, .entitlementMissing, .locationUnavailable: "cloud.slash"
        }
    }
}

struct CanvasWeatherProviderResult: Sendable {
    let snapshot: CanvasWeatherSnapshot
    let attributionURL: URL
}

protocol CanvasWeatherProviding {
    func currentWeather(for location: CLLocation) async throws -> CanvasWeatherProviderResult
}

struct WeatherKitCanvasWeatherProvider: CanvasWeatherProviding {
    func currentWeather(for location: CLLocation) async throws -> CanvasWeatherProviderResult {
        let service = WeatherKit.WeatherService.shared
        let current: WeatherKit.CurrentWeather = try await service.weather(for: location, including: .current)
        let attribution = try await service.attribution

        let formatter = MeasurementFormatter()
        formatter.locale = .current
        formatter.unitOptions = .naturalScale
        formatter.numberFormatter.maximumFractionDigits = 0
        let attributionText = attribution.legalAttributionText.isEmpty
            ? attribution.serviceName
            : attribution.legalAttributionText

        return CanvasWeatherProviderResult(
            snapshot: CanvasWeatherSnapshot(
                symbolName: current.symbolName,
                condition: current.condition.description,
                temperature: formatter.string(from: current.temperature),
                attributionText: attributionText,
                updatedAt: .now
            ),
            attributionURL: attribution.legalPageURL
        )
    }
}

private enum WeatherRequestError: Error {
    case timedOut
}

/// Location-backed WeatherKit service with a bounded request, a small local
/// last-known cache, and explicit permission/provider diagnostics.
@MainActor
final class CanvasWeatherService: NSObject, ObservableObject, @MainActor CLLocationManagerDelegate {
    @Published private(set) var snapshot: CanvasWeatherSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var attributionURL: URL?
    @Published private(set) var status: WeatherOverlayStatus = .disabled
    @Published private(set) var isUsingCachedSnapshot = false

    private static let snapshotCacheKey = "canvas.weather.snapshot.v1"
    private static let attributionURLCacheKey = "canvas.weather.attribution-url.v1"
    private static let requestTimeoutNanoseconds: UInt64 = 20_000_000_000

    private let weatherProvider: CanvasWeatherProviding
    private let locationManager: CLLocationManager
    private let autoRequestLocation: Bool
    private var refreshTask: Task<Void, Never>?
    private var activeRequestID = UUID()
    private var weatherEnabled = false

    init(
        weatherProvider: CanvasWeatherProviding = WeatherKitCanvasWeatherProvider(),
        autoRequestLocation: Bool = true
    ) {
        self.weatherProvider = weatherProvider
        self.locationManager = CLLocationManager()
        self.autoRequestLocation = autoRequestLocation
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        locationManager.distanceFilter = 1_000
        loadCachedSnapshot()
    }

    deinit {
        refreshTask?.cancel()
        locationManager.stopUpdatingLocation()
    }

    func update(showWeather: Bool) {
        guard showWeather else {
            clear()
            return
        }

        weatherEnabled = true
        loadCachedSnapshot()
        beginRefresh(requestPermission: autoRequestLocation)
    }

    /// Re-checks the OS permission when the app returns from Settings without
    /// prompting again automatically.
    func refreshAuthorization() {
        guard weatherEnabled else { return }
        beginRefresh(requestPermission: false)
    }

    func clear() {
        refreshTask?.cancel()
        refreshTask = nil
        activeRequestID = UUID()
        weatherEnabled = false
        locationManager.stopUpdatingLocation()
        snapshot = nil
        attributionURL = nil
        errorMessage = nil
        isLoading = false
        status = .disabled
        isUsingCachedSnapshot = false
    }

    private func beginRefresh(requestPermission: Bool) {
        refreshTask?.cancel()
        refreshTask = nil
        activeRequestID = UUID()
        locationManager.stopUpdatingLocation()

        switch locationManager.authorizationStatus {
        case .notDetermined:
            isLoading = requestPermission
            status = requestPermission ? .requestingLocation : .needsLocationPermission
            errorMessage = status.message
            if requestPermission {
                locationManager.requestWhenInUseAuthorization()
            }
        case .authorizedWhenInUse, .authorizedAlways:
            isLoading = true
            status = .locating
            errorMessage = nil
            locationManager.requestLocation()
        case .denied:
            finishWithoutRequest(status: .locationDenied)
        case .restricted:
            finishWithoutRequest(status: .locationRestricted)
        @unknown default:
            finishWithoutRequest(status: .locationUnavailable)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard weatherEnabled else { return }
        beginRefresh(requestPermission: false)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard weatherEnabled, let location = locations.last else { return }
        guard location.horizontalAccuracy >= 0 else {
            finishWithoutRequest(status: .locationUnavailable)
            return
        }
        locationManager.stopUpdatingLocation()
        fetchWeather(for: location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard weatherEnabled else { return }
        if manager.authorizationStatus == .denied {
            finishWithoutRequest(status: .locationDenied)
        } else {
            finishWithoutRequest(status: .locationUnavailable)
        }
    }

    private func fetchWeather(for location: CLLocation) {
        let requestID = activeRequestID
        let provider = weatherProvider
        isLoading = true
        status = .fetching
        errorMessage = nil

        refreshTask = Task { [weak self] in
            do {
                let result = try await Self.withTimeout {
                    try await provider.currentWeather(for: location)
                }
                guard !Task.isCancelled else { return }
                guard let self, self.weatherEnabled, self.activeRequestID == requestID else { return }
                self.snapshot = result.snapshot
                self.attributionURL = result.attributionURL
                self.isUsingCachedSnapshot = false
                self.isLoading = false
                self.status = .live
                self.errorMessage = nil
                self.persist(result)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.weatherEnabled, self.activeRequestID == requestID else { return }
                self.isLoading = false
                self.status = Self.status(for: error)
                self.errorMessage = self.status.message
                if self.snapshot != nil {
                    self.isUsingCachedSnapshot = true
                }
            }
        }
    }

    private func finishWithoutRequest(status: WeatherOverlayStatus) {
        refreshTask?.cancel()
        refreshTask = nil
        isLoading = false
        self.status = status
        errorMessage = status.message
        if snapshot != nil {
            isUsingCachedSnapshot = true
        }
    }

    private static func withTimeout<T>(operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: requestTimeoutNanoseconds)
                throw WeatherRequestError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func status(for error: Error) -> WeatherOverlayStatus {
        if error is WeatherRequestError {
            return .networkUnavailable
        }
        let nsError = error as NSError
        let diagnosticText = ([nsError.domain, nsError.localizedDescription] + nsError.userInfo.values.compactMap { $0 as? String }).joined(separator: " ").lowercased()
        if diagnosticText.contains("weatherdaemon") || diagnosticText.contains("wdsjwtauthenticator") || diagnosticText.contains("jwt") {
            return .authorizationUnavailable
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost:
                return .networkUnavailable
            default:
                break
            }
        }
        if let weatherError = error as? WeatherKit.WeatherError {
            switch weatherError {
            case .permissionDenied:
                return .entitlementMissing
            case .unknown:
                return .authorizationUnavailable
            @unknown default:
                return .authorizationUnavailable
            }
        }
        if nsError.domain == NSURLErrorDomain {
            return .networkUnavailable
        }
        return .serviceUnavailable
    }

    private func loadCachedSnapshot() {
        if snapshot == nil,
           let data = UserDefaults.standard.data(forKey: Self.snapshotCacheKey),
           let cached = try? JSONDecoder().decode(CanvasWeatherSnapshot.self, from: data) {
            snapshot = cached
            isUsingCachedSnapshot = true
        }
        if attributionURL == nil,
           let rawURL = UserDefaults.standard.string(forKey: Self.attributionURLCacheKey),
           let url = URL(string: rawURL) {
            attributionURL = url
        }
    }

    private func persist(_ result: CanvasWeatherProviderResult) {
        if let data = try? JSONEncoder().encode(result.snapshot) {
            UserDefaults.standard.set(data, forKey: Self.snapshotCacheKey)
        }
        UserDefaults.standard.set(result.attributionURL.absoluteString, forKey: Self.attributionURLCacheKey)
    }
}
