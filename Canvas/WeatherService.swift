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
    let apparentTemperature: String?
    let humidityPercent: Int?
    let wind: String?
    let uvIndex: Int?
    let precipitationChancePercent: Int?
    let highTemperature: String?
    let lowTemperature: String?
    let sunrise: String?
    let sunset: String?
    let nextHourSymbolName: String?
    let nextHourTemperature: String?
    let nextHourCondition: String?
    let airQualityIndex: Int?
    let updatedAt: Date

    init(
        symbolName: String,
        condition: String,
        temperature: String,
        apparentTemperature: String? = nil,
        humidityPercent: Int? = nil,
        wind: String? = nil,
        uvIndex: Int? = nil,
        precipitationChancePercent: Int? = nil,
        highTemperature: String? = nil,
        lowTemperature: String? = nil,
        sunrise: String? = nil,
        sunset: String? = nil,
        nextHourSymbolName: String? = nil,
        nextHourTemperature: String? = nil,
        nextHourCondition: String? = nil,
        airQualityIndex: Int? = nil,
        updatedAt: Date = .now
    ) {
        self.symbolName = symbolName
        self.condition = condition
        self.temperature = temperature
        self.apparentTemperature = apparentTemperature
        self.humidityPercent = humidityPercent
        self.wind = wind
        self.uvIndex = uvIndex
        self.precipitationChancePercent = precipitationChancePercent
        self.highTemperature = highTemperature
        self.lowTemperature = lowTemperature
        self.sunrise = sunrise
        self.sunset = sunset
        self.nextHourSymbolName = nextHourSymbolName
        self.nextHourTemperature = nextHourTemperature
        self.nextHourCondition = nextHourCondition
        self.airQualityIndex = airQualityIndex
        self.updatedAt = updatedAt
    }

    var isStale: Bool { Date().timeIntervalSince(updatedAt) > 6 * 60 * 60 }

    var conditionsText: String { "\(temperature) · \(condition)" }

    /// A stale cache is explicitly labelled so it can never look live.
    var displayText: String {
        let suffix = isStale ? " · Last known" : ""
        return "\(conditionsText)\(suffix)"
    }

    func addingAirQualityIndex(_ value: Int?) -> Self {
        Self(
            symbolName: symbolName,
            condition: condition,
            temperature: temperature,
            apparentTemperature: apparentTemperature,
            humidityPercent: humidityPercent,
            wind: wind,
            uvIndex: uvIndex,
            precipitationChancePercent: precipitationChancePercent,
            highTemperature: highTemperature,
            lowTemperature: lowTemperature,
            sunrise: sunrise,
            sunset: sunset,
            nextHourSymbolName: nextHourSymbolName,
            nextHourTemperature: nextHourTemperature,
            nextHourCondition: nextHourCondition,
            airQualityIndex: value,
            updatedAt: updatedAt
        )
    }

    static let preview = Self(
        symbolName: "cloud.sun.fill",
        condition: "Partly Cloudy",
        temperature: "72°F",
        apparentTemperature: "70°F",
        humidityPercent: 48,
        wind: "NW 8 mph",
        uvIndex: 4,
        precipitationChancePercent: 12,
        highTemperature: "78°F",
        lowTemperature: "61°F",
        sunrise: "6:22 AM",
        sunset: "8:13 PM",
        nextHourSymbolName: "sun.max.fill",
        nextHourTemperature: "74°F",
        nextHourCondition: "Mostly Sunny",
        airQualityIndex: 36
    )
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
            "Apple's WeatherKit authorization service could not issue a token. In Apple Developer, confirm both the WeatherKit capability and the separate WeatherKit App Service are enabled for com.johnhelmuth.canvas, then install a newly signed build."
        case .entitlementMissing:
            "WeatherKit access is not enabled for this signed build. In Apple Developer, enable both the WeatherKit capability and WeatherKit App Service for com.johnhelmuth.canvas, then install a newly signed build."
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
    let attributionMarkURL: URL

    func addingAirQualityIndex(_ value: Int?) -> Self {
        Self(
            snapshot: snapshot.addingAirQualityIndex(value),
            attributionURL: attributionURL,
            attributionMarkURL: attributionMarkURL
        )
    }
}

protocol CanvasWeatherProviding {
    func currentWeather(for location: CLLocation) async throws -> CanvasWeatherProviderResult
}

struct WeatherKitCanvasWeatherProvider: CanvasWeatherProviding {
    func currentWeather(for location: CLLocation) async throws -> CanvasWeatherProviderResult {
        let service = WeatherKit.WeatherService.shared
        let (current, hourly, daily) = try await service.weather(
            for: location,
            including: .current,
            .hourly,
            .daily
        )
        let attribution = try await service.attribution

        let measurementFormatter = MeasurementFormatter()
        measurementFormatter.locale = .current
        measurementFormatter.unitOptions = .naturalScale
        measurementFormatter.numberFormatter.maximumFractionDigits = 0
        let timeFormatter = DateFormatter()
        timeFormatter.locale = .current
        timeFormatter.timeStyle = .short
        timeFormatter.dateStyle = .none

        let currentHour = hourly.first { abs($0.date.timeIntervalSince(current.date)) < 60 * 60 }
        let nextHour = hourly.first { $0.date > current.date.addingTimeInterval(30 * 60) }
        let today = daily.first
        return CanvasWeatherProviderResult(
            snapshot: CanvasWeatherSnapshot(
                symbolName: current.symbolName,
                condition: current.condition.description,
                temperature: measurementFormatter.string(from: current.temperature),
                apparentTemperature: measurementFormatter.string(from: current.apparentTemperature),
                humidityPercent: Int((current.humidity * 100).rounded()),
                wind: "\(current.wind.compassDirection.abbreviation) \(measurementFormatter.string(from: current.wind.speed))",
                uvIndex: current.uvIndex.value,
                precipitationChancePercent: currentHour.map { Int(($0.precipitationChance * 100).rounded()) },
                highTemperature: today.map { measurementFormatter.string(from: $0.highTemperature) },
                lowTemperature: today.map { measurementFormatter.string(from: $0.lowTemperature) },
                sunrise: today?.sun.sunrise.map(timeFormatter.string(from:)),
                sunset: today?.sun.sunset.map(timeFormatter.string(from:)),
                nextHourSymbolName: nextHour?.symbolName,
                nextHourTemperature: nextHour.map { measurementFormatter.string(from: $0.temperature) },
                nextHourCondition: nextHour?.condition.description,
                updatedAt: .now
            ),
            attributionURL: attribution.legalPageURL,
            attributionMarkURL: attribution.squareMarkURL
        )
    }
}

protocol CanvasAirQualityProviding: Sendable {
    func currentUSAirQualityIndex(for location: CLLocation) async throws -> Int?
}

struct OpenMeteoAirQualityResponse: Decodable, Sendable {
    struct Current: Decodable, Sendable {
        let usAQI: Double?

        private enum CodingKeys: String, CodingKey {
            case usAQI = "us_aqi"
        }
    }

    let current: Current?
}

/// AQI is not exposed by WeatherKit's native or REST datasets. Canvas requests
/// only Open-Meteo's consolidated current US AQI, using coordinates rounded to
/// roughly one-kilometer precision to match the app's low-accuracy location
/// request and the much coarser underlying CAMS forecast grid.
struct OpenMeteoAirQualityProvider: CanvasAirQualityProviding {
    func currentUSAirQualityIndex(for location: CLLocation) async throws -> Int? {
        var components = URLComponents(string: "https://air-quality-api.open-meteo.com/v1/air-quality")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: Self.coordinateString(location.coordinate.latitude)),
            URLQueryItem(name: "longitude", value: Self.coordinateString(location.coordinate.longitude)),
            URLQueryItem(name: "current", value: "us_aqi"),
            URLQueryItem(name: "forecast_days", value: "1")
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        guard let value = try JSONDecoder().decode(OpenMeteoAirQualityResponse.self, from: data).current?.usAQI else { return nil }
        return min(max(Int(value.rounded()), 0), 500)
    }

    static func coordinateString(_ value: CLLocationDegrees) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
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
    @Published private(set) var attributionMarkURL: URL?
    @Published private(set) var status: WeatherOverlayStatus = .disabled
    @Published private(set) var isUsingCachedSnapshot = false

    private static let snapshotCacheKey = "canvas.weather.snapshot.v1"
    private static let attributionURLCacheKey = "canvas.weather.attribution-url.v1"
    private static let attributionMarkURLCacheKey = "canvas.weather.attribution-mark-url.v1"
    private static let requestTimeoutNanoseconds: UInt64 = 20_000_000_000

    private let weatherProvider: CanvasWeatherProviding
    private let airQualityProvider: CanvasAirQualityProviding
    private let locationManager: CLLocationManager
    private let autoRequestLocation: Bool
    private let previewMode: Bool
    private var refreshTask: Task<Void, Never>?
    private var activeRequestID = UUID()
    private var weatherEnabled = false

    init(
        weatherProvider: CanvasWeatherProviding = WeatherKitCanvasWeatherProvider(),
        airQualityProvider: CanvasAirQualityProviding = OpenMeteoAirQualityProvider(),
        autoRequestLocation: Bool = true
    ) {
        self.weatherProvider = weatherProvider
        self.airQualityProvider = airQualityProvider
        self.locationManager = CLLocationManager()
        self.autoRequestLocation = autoRequestLocation
        self.previewMode = ProcessInfo.processInfo.arguments.contains("--canvas-ui-weather-preview") || ProcessInfo.processInfo.arguments.contains("--canvas-ui-weather-frame")
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        locationManager.distanceFilter = 1_000
        if previewMode {
            loadPreviewSnapshot()
        } else {
            loadCachedSnapshot()
        }
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

        if previewMode {
            loadPreviewSnapshot()
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
        if previewMode {
            loadPreviewSnapshot()
            return
        }
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
        attributionMarkURL = nil
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
        let airQualityProvider = airQualityProvider
        isLoading = true
        status = .fetching
        errorMessage = nil

        refreshTask = Task { [weak self] in
            do {
                async let airQualityIndex = try? await airQualityProvider.currentUSAirQualityIndex(for: location)
                var result = try await Self.withTimeout {
                    try await provider.currentWeather(for: location)
                }
                result = result.addingAirQualityIndex(await airQualityIndex)
                guard !Task.isCancelled else { return }
                guard let self, self.weatherEnabled, self.activeRequestID == requestID else { return }
                self.snapshot = result.snapshot
                self.attributionURL = result.attributionURL
                self.attributionMarkURL = result.attributionMarkURL
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
        if attributionMarkURL == nil,
           let rawURL = UserDefaults.standard.string(forKey: Self.attributionMarkURLCacheKey),
           let url = URL(string: rawURL) {
            attributionMarkURL = url
        }
    }

    private func loadPreviewSnapshot() {
        refreshTask?.cancel()
        refreshTask = nil
        activeRequestID = UUID()
        weatherEnabled = true
        snapshot = .preview
        attributionURL = URL(string: "https://weatherkit.apple.com/legal-attribution.html")
        attributionMarkURL = nil
        errorMessage = nil
        isLoading = false
        status = .live
        isUsingCachedSnapshot = false
    }

    private func persist(_ result: CanvasWeatherProviderResult) {
        if let data = try? JSONEncoder().encode(result.snapshot) {
            UserDefaults.standard.set(data, forKey: Self.snapshotCacheKey)
        }
        UserDefaults.standard.set(result.attributionURL.absoluteString, forKey: Self.attributionURLCacheKey)
        UserDefaults.standard.set(result.attributionMarkURL.absoluteString, forKey: Self.attributionMarkURLCacheKey)
    }
}
