import Combine
import CoreLocation
import Foundation
import Security
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
    let rainToday: String?
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
        rainToday: String? = nil,
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
        self.rainToday = rainToday
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
            rainToday: rainToday,
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
        rainToday: nil,
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
    case ambientConfigurationMissing
    case ambientUnavailable

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
        case .ambientConfigurationMissing: "Ambient station not configured"
        case .ambientUnavailable: "Ambient station unavailable"
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
        case .ambientConfigurationMissing:
            "Enter your personal Ambient API key in Canvas Settings. ClimateIQ supplies the shared application key through its secure proxy."
        case .ambientUnavailable:
            "Canvas could not reach the Ambient station through ClimateIQ. Check the station connection and retry."
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
        case .ambientConfigurationMissing: "sensor.slash"
        case .ambientUnavailable: "sensor.fill"
        }
    }
}

struct CanvasWeatherProviderResult: Sendable {
    let snapshot: CanvasWeatherSnapshot
    let attributionURL: URL
    let attributionMarkURL: URL?

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

/// Canvas cannot read another app's Keychain access group. Store only the
/// user's personal Ambient API key in Canvas's own Keychain and keep the
/// shared ClimateIQ application key on the existing ClimateIQ server proxy.
enum CanvasAmbientCredentialStore {
    private static let service = "com.johnhelmuth.canvas.ambient"
    private static let account = "ambient-api-key"

    static func loadAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func saveAPIKey(_ value: String) {
        clearAPIKey()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ] as CFDictionary, nil)
    }

    static func clearAPIKey() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
    }
}

struct CanvasWeatherConfiguration: Equatable, Sendable {
    static let discoveredAmbientDeviceKey = "canvas.weather.ambient-device-mac.v1"

    let source: CanvasWeatherSource
    let ambientDeviceMAC: String?
    let ambientAPIKey: String?

    static func load(defaults: UserDefaults = .standard) -> Self {
        let settings = defaults.data(forKey: "canvas.settings.v1")
            .flatMap { try? JSONDecoder().decode(CanvasSettings.self, from: $0) }
            ?? CanvasSettings()
        return Self(
            source: settings.effectiveWeatherSource,
            ambientDeviceMAC: settings.effectiveAmbientDeviceMAC ?? defaults.string(forKey: Self.discoveredAmbientDeviceKey),
            ambientAPIKey: CanvasAmbientCredentialStore.loadAPIKey()
        )
    }

    static func clearDiscoveredAmbientDevice(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: discoveredAmbientDeviceKey)
    }
}

enum CanvasAmbientWeatherProviderError: LocalizedError, Equatable {
    case apiKeyMissing
    case stationMissing
    case noReading
    case invalidResponse
    case serverUnavailable

    var errorDescription: String? {
        switch self {
        case .apiKeyMissing: "An Ambient API key is not configured."
        case .stationMissing: "An Ambient station could not be selected."
        case .noReading: "The Ambient station has no recent readings."
        case .invalidResponse: "Ambient returned an unexpected response."
        case .serverUnavailable: "ClimateIQ could not reach Ambient Weather."
        }
    }
}

struct CanvasAmbientDevice: Decodable, Sendable, Equatable {
    let macAddress: String
    let name: String
    let location: String

    /// A friendly label for Settings. The station identifier remains an
    /// internal routing value and is never shown to the user.
    var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (trimmedName.isEmpty, trimmedLocation.isEmpty) {
        case (false, false): return "\(trimmedName) · \(trimmedLocation)"
        case (false, true): return trimmedName
        case (true, false): return trimmedLocation
        case (true, true): return "Ambient station"
        }
    }
}

struct CanvasAmbientDeviceResponse: Decodable, Sendable, Equatable {
    let devices: [CanvasAmbientDevice]
}

struct CanvasAmbientReading: Decodable, Sendable, Equatable {
    let tempF: Double?
    let apparentTempF: Double?
    let humidityPercent: Double?
    let windMph: Double?
    let windGustMph: Double?
    let windDirectionDeg: Double?
    let pressureInHg: Double?
    let uvIndex: Double?
    let hourlyRainIn: Double?
    let rainTodayIn: Double?
    let highF: Double?
    let lowF: Double?
    let asOf: String?
}

struct CanvasAmbientCurrentResponse: Decodable, Sendable, Equatable {
    let reading: CanvasAmbientReading?
}

/// Ambient stations report measurements rather than a forecast condition. The
/// overlay uses those measurements to create a small, honest observation
/// glyph, while the existing WeatherKit path remains unchanged.
struct AmbientWeatherCanvasProvider: CanvasWeatherProviding {
    let apiKey: String
    let deviceMAC: String?
    let baseURL: URL
    let session: URLSession
    let defaults: UserDefaults

    init(
        apiKey: String,
        deviceMAC: String? = nil,
        baseURL: URL = URL(string: "https://myclimateiq.com")!,
        session: URLSession = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.apiKey = apiKey
        self.deviceMAC = deviceMAC
        self.baseURL = baseURL
        self.session = session
        self.defaults = defaults
    }

    func currentWeather(for _: CLLocation) async throws -> CanvasWeatherProviderResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw CanvasAmbientWeatherProviderError.apiKeyMissing }
        let mac = try await resolvedDeviceMAC(apiKey: key)
        guard let url = URL(string: "api/ambient-current", relativeTo: baseURL)?.absoluteURL else {
            throw CanvasAmbientWeatherProviderError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "apiKey": key,
            "deviceMac": mac,
            "timezone": TimeZone.current.identifier
        ])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            throw CanvasAmbientWeatherProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CanvasAmbientWeatherProviderError.serverUnavailable
        }
        guard let payload = try? JSONDecoder().decode(CanvasAmbientCurrentResponse.self, from: data),
              let reading = payload.reading,
              reading.tempF != nil else {
            throw CanvasAmbientWeatherProviderError.noReading
        }

        return Self.result(from: reading)
    }

    /// Returns the stations available to the current Ambient account. This is
    /// used by Settings so a user can choose by name/location without handling
    /// a raw station identifier.
    func availableDevices() async throws -> [CanvasAmbientDevice] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw CanvasAmbientWeatherProviderError.apiKeyMissing }
        return try await Self.fetchDevices(apiKey: key, baseURL: baseURL, session: session)
    }

    static func fetchDevices(
        apiKey: String,
        baseURL: URL = URL(string: "https://myclimateiq.com")!,
        session: URLSession = .shared
    ) async throws -> [CanvasAmbientDevice] {
        guard let url = URL(string: "api/mobile/ambient-devices", relativeTo: baseURL)?.absoluteURL else {
            throw CanvasAmbientWeatherProviderError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["apiKey": apiKey])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CanvasAmbientWeatherProviderError.serverUnavailable
        }
        guard let payload = try? JSONDecoder().decode(CanvasAmbientDeviceResponse.self, from: data) else {
            throw CanvasAmbientWeatherProviderError.invalidResponse
        }
        let devices = payload.devices.compactMap { device -> CanvasAmbientDevice? in
            guard let normalized = normalizeMAC(device.macAddress) else { return nil }
            return CanvasAmbientDevice(macAddress: normalized, name: device.name, location: device.location)
        }
        guard !devices.isEmpty else { throw CanvasAmbientWeatherProviderError.stationMissing }
        return devices
    }

    private func resolvedDeviceMAC(apiKey: String) async throws -> String {
        if let raw = deviceMAC?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            guard let normalized = Self.normalizeMAC(raw) else {
                throw CanvasAmbientWeatherProviderError.stationMissing
            }
            return normalized
        }

        guard let first = try await Self.fetchDevices(apiKey: apiKey, baseURL: baseURL, session: session).first else {
            throw CanvasAmbientWeatherProviderError.stationMissing
        }
        defaults.set(first.macAddress, forKey: CanvasWeatherConfiguration.discoveredAmbientDeviceKey)
        return first.macAddress
    }

    static func normalizeMAC(_ value: String) -> String? {
        let allowed = "0123456789abcdefABCDEF"
        let compact = value.filter { allowed.contains($0) }
        let characters = Array(compact.uppercased())
        guard characters.count == 12 else { return nil }
        return stride(from: 0, to: characters.count, by: 2)
            .map { String(characters[$0...($0 + 1)]) }
            .joined(separator: ":")
    }

    private static func result(from reading: CanvasAmbientReading) -> CanvasWeatherProviderResult {
        CanvasWeatherProviderResult(
            snapshot: snapshot(from: reading),
            attributionURL: URL(string: "https://ambientweather.com/faqs/question/view/id/1811/")!,
            attributionMarkURL: nil
        )
    }

    static func snapshot(from reading: CanvasAmbientReading) -> CanvasWeatherSnapshot {
        let raining = (reading.hourlyRainIn ?? 0) > 0.01
        let isNight = reading.uvIndex.map { $0 <= 0 } ?? false
        let symbolName = raining ? "cloud.rain.fill" : (isNight ? "moon.stars.fill" : "sun.max.fill")
        let condition = raining ? "Rain" : (isNight ? "Clear night" : "Clear")
        let updatedAt = parseDate(reading.asOf) ?? .now

        return CanvasWeatherSnapshot(
            symbolName: symbolName,
            condition: condition,
            temperature: temperature(reading.tempF) ?? "—",
            apparentTemperature: temperature(reading.apparentTempF),
            humidityPercent: reading.humidityPercent.map { Int($0.rounded()) },
            wind: wind(reading.windMph, direction: reading.windDirectionDeg),
            uvIndex: reading.uvIndex.map { Int($0.rounded()) },
            rainToday: rainfall(reading.rainTodayIn),
            highTemperature: temperature(reading.highF),
            lowTemperature: temperature(reading.lowF),
            updatedAt: updatedAt
        )
    }

    private static func temperature(_ value: Double?) -> String? {
        guard let value else { return nil }
        let formatter = MeasurementFormatter()
        formatter.locale = .current
        formatter.unitOptions = .naturalScale
        formatter.numberFormatter.maximumFractionDigits = 0
        return formatter.string(from: Measurement(value: value, unit: UnitTemperature.fahrenheit))
    }

    private static func wind(_ speed: Double?, direction: Double?) -> String? {
        guard let speed else { return nil }
        let formatter = MeasurementFormatter()
        formatter.locale = .current
        formatter.unitOptions = .naturalScale
        formatter.numberFormatter.maximumFractionDigits = 0
        let speedText = formatter.string(from: Measurement(value: speed, unit: UnitSpeed.milesPerHour))
        if let direction {
            return "\(compass(direction)) \(speedText)"
        }
        return speedText
    }

    private static func rainfall(_ value: Double?) -> String? {
        guard let value else { return nil }
        return String(format: "%.2f in", max(0, value))
    }

    private static func compass(_ degrees: Double) -> String {
        let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let normalized = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let index = Int((normalized / 45).rounded()) % directions.count
        return directions[index]
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }()
    }
}

struct ConfiguredCanvasWeatherProvider: CanvasWeatherProviding {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func currentWeather(for location: CLLocation) async throws -> CanvasWeatherProviderResult {
        let configuration = CanvasWeatherConfiguration.load(defaults: defaults)
        switch configuration.source {
        case .weatherKit:
            return try await WeatherKitCanvasWeatherProvider().currentWeather(for: location)
        case .ambientStation:
            guard let apiKey = configuration.ambientAPIKey else {
                throw CanvasAmbientWeatherProviderError.apiKeyMissing
            }
            return try await AmbientWeatherCanvasProvider(
                apiKey: apiKey,
                deviceMAC: configuration.ambientDeviceMAC,
                defaults: defaults
            ).currentWeather(for: location)
        }
    }
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
    private static let snapshotSourceCacheKey = "canvas.weather.snapshot-source.v1"
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
    private var activeWeatherSource: CanvasWeatherSource?

    init(
        weatherProvider: CanvasWeatherProviding = ConfiguredCanvasWeatherProvider(),
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
        activeWeatherSource = CanvasWeatherConfiguration.load().source
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

        let configuration = CanvasWeatherConfiguration.load()
        if activeWeatherSource != nil, activeWeatherSource != configuration.source {
            snapshot = nil
            attributionURL = nil
            attributionMarkURL = nil
            isUsingCachedSnapshot = false
        }
        activeWeatherSource = configuration.source
        weatherEnabled = true
        loadCachedSnapshot()
        if configuration.source == .ambientStation, configuration.ambientAPIKey == nil {
            finishWithoutRequest(status: .ambientConfigurationMissing, preserveSnapshot: false)
            return
        }
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

    private func finishWithoutRequest(status: WeatherOverlayStatus, preserveSnapshot: Bool = true) {
        refreshTask?.cancel()
        refreshTask = nil
        isLoading = false
        self.status = status
        errorMessage = status.message
        if preserveSnapshot, snapshot != nil {
            isUsingCachedSnapshot = true
        } else if !preserveSnapshot {
            snapshot = nil
            attributionURL = nil
            attributionMarkURL = nil
            isUsingCachedSnapshot = false
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
        if let ambientError = error as? CanvasAmbientWeatherProviderError {
            switch ambientError {
            case .apiKeyMissing, .stationMissing:
                return .ambientConfigurationMissing
            case .noReading, .invalidResponse, .serverUnavailable:
                return .ambientUnavailable
            }
        }
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
        let source = CanvasWeatherConfiguration.load().source
        let cachedSource = UserDefaults.standard.string(forKey: Self.snapshotSourceCacheKey)
        guard source == .weatherKit || cachedSource == source.rawValue else { return }
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
        UserDefaults.standard.set(CanvasWeatherConfiguration.load().source.rawValue, forKey: Self.snapshotSourceCacheKey)
        UserDefaults.standard.set(result.attributionURL.absoluteString, forKey: Self.attributionURLCacheKey)
        if let markURL = result.attributionMarkURL {
            UserDefaults.standard.set(markURL.absoluteString, forKey: Self.attributionMarkURLCacheKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.attributionMarkURLCacheKey)
        }
    }
}
