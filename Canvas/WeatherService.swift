import Combine
import CoreLocation
import CryptoKit
import Foundation
import Security
import WeatherKit

enum CanvasWeatherTemperatureFormatter {
    static func string(
        from value: Double,
        unit: UnitTemperature = .fahrenheit,
        locale: Locale = .current
    ) -> String {
        let formatter = MeasurementFormatter()
        formatter.locale = locale
        formatter.unitOptions = .naturalScale
        formatter.numberFormatter.minimumFractionDigits = 1
        formatter.numberFormatter.maximumFractionDigits = 1
        formatter.numberFormatter.usesGroupingSeparator = false
        return formatter.string(from: Measurement(value: value, unit: unit))
    }

    static func normalized(_ value: String?, locale: Locale = .current) -> String? {
        guard let value else { return nil }

        let expression = try? NSRegularExpression(
            pattern: #"^\s*([+-]?(?:\d+(?:[.,]\d*)?|[.,]\d+))\s*(?:°|º)?\s*([CFcf])\s*$"#
        )
        let range = NSRange(location: 0, length: (value as NSString).length)
        guard
            let match = expression?.firstMatch(in: value, options: [], range: range),
            let numberRange = Range(match.range(at: 1), in: value),
            let unitRange = Range(match.range(at: 2), in: value),
            let number = Double(value[numberRange].replacingOccurrences(of: ",", with: "."))
        else {
            return value
        }

        let unit: UnitTemperature = value[unitRange].uppercased() == "C" ? .celsius : .fahrenheit
        return string(from: number, unit: unit, locale: locale)
    }

    /// Returns a stable Fahrenheit value from one of Canvas's localized
    /// temperature strings. This is used only as a compatibility fallback
    /// for snapshots written before raw dew-point values were persisted.
    static func fahrenheitValue(from value: String?) -> Double? {
        guard let value else { return nil }

        let expression = try? NSRegularExpression(
            pattern: #"^\s*([+-]?(?:\d+(?:[.,]\d*)?|[.,]\d+))\s*(?:°|º)?\s*([CFcf])\s*$"#
        )
        let range = NSRange(location: 0, length: (value as NSString).length)
        guard
            let match = expression?.firstMatch(in: value, options: [], range: range),
            let numberRange = Range(match.range(at: 1), in: value),
            let unitRange = Range(match.range(at: 2), in: value),
            let number = Double(value[numberRange].replacingOccurrences(of: ",", with: "."))
        else {
            return nil
        }

        switch value[unitRange].uppercased() {
        case "F": return number
        case "C": return number * 9 / 5 + 32
        default: return nil
        }
    }
}

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
    let dewPoint: String?
    /// Raw Fahrenheit value used for positioning the scale. The display
    /// string remains localized and is still the value shown beside the
    /// marker.
    let dewPointF: Double?
    let pressure: String?
    let rainRate: String?
    let solarRadiation: String?
    let precipitationChancePercent: Int?
    let rainToday: String?
    let highTemperature: String?
    let lowTemperature: String?
    let sunrise: String?
    let sunset: String?
    let nextHourSymbolName: String?
    let nextHourTemperature: String?
    let nextHourCondition: String?
    var airQualityIndex: Int?
    var airQualityUpdatedAt: Date?
    var localForecast: CanvasWeatherLocalForecast?
    let updatedAt: Date

    init(
        symbolName: String,
        condition: String,
        temperature: String,
        apparentTemperature: String? = nil,
        humidityPercent: Int? = nil,
        wind: String? = nil,
        uvIndex: Int? = nil,
        dewPoint: String? = nil,
        dewPointF: Double? = nil,
        pressure: String? = nil,
        rainRate: String? = nil,
        solarRadiation: String? = nil,
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
        airQualityUpdatedAt: Date? = nil,
        localForecast: CanvasWeatherLocalForecast? = nil,
        updatedAt: Date = .now
    ) {
        self.symbolName = symbolName
        self.condition = condition
        self.temperature = CanvasWeatherTemperatureFormatter.normalized(temperature) ?? temperature
        self.apparentTemperature = CanvasWeatherTemperatureFormatter.normalized(apparentTemperature)
        self.humidityPercent = humidityPercent
        self.wind = wind
        self.uvIndex = uvIndex
        self.dewPoint = CanvasWeatherTemperatureFormatter.normalized(dewPoint)
        self.dewPointF = dewPointF ?? CanvasWeatherTemperatureFormatter.fahrenheitValue(from: dewPoint)
        self.pressure = pressure
        self.rainRate = rainRate
        self.solarRadiation = solarRadiation
        self.precipitationChancePercent = precipitationChancePercent
        self.rainToday = rainToday
        self.highTemperature = CanvasWeatherTemperatureFormatter.normalized(highTemperature)
        self.lowTemperature = CanvasWeatherTemperatureFormatter.normalized(lowTemperature)
        self.sunrise = sunrise
        self.sunset = sunset
        self.nextHourSymbolName = nextHourSymbolName
        self.nextHourTemperature = CanvasWeatherTemperatureFormatter.normalized(nextHourTemperature)
        self.nextHourCondition = nextHourCondition
        self.airQualityIndex = airQualityIndex
        self.airQualityUpdatedAt = airQualityIndex == nil ? nil : (airQualityUpdatedAt ?? updatedAt)
        self.localForecast = localForecast
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case symbolName
        case condition
        case temperature
        case apparentTemperature
        case humidityPercent
        case wind
        case uvIndex
        case dewPoint
        case dewPointF
        case pressure
        case rainRate
        case solarRadiation
        case precipitationChancePercent
        case rainToday
        case highTemperature
        case lowTemperature
        case sunrise
        case sunset
        case nextHourSymbolName
        case nextHourTemperature
        case nextHourCondition
        case airQualityIndex
        case airQualityUpdatedAt
        case localForecast
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            symbolName: try container.decode(String.self, forKey: .symbolName),
            condition: try container.decode(String.self, forKey: .condition),
            temperature: try container.decode(String.self, forKey: .temperature),
            apparentTemperature: try container.decodeIfPresent(String.self, forKey: .apparentTemperature),
            humidityPercent: try container.decodeIfPresent(Int.self, forKey: .humidityPercent),
            wind: try container.decodeIfPresent(String.self, forKey: .wind),
            uvIndex: try container.decodeIfPresent(Int.self, forKey: .uvIndex),
            dewPoint: try container.decodeIfPresent(String.self, forKey: .dewPoint),
            dewPointF: try container.decodeIfPresent(Double.self, forKey: .dewPointF),
            pressure: try container.decodeIfPresent(String.self, forKey: .pressure),
            rainRate: try container.decodeIfPresent(String.self, forKey: .rainRate),
            solarRadiation: try container.decodeIfPresent(String.self, forKey: .solarRadiation),
            precipitationChancePercent: try container.decodeIfPresent(Int.self, forKey: .precipitationChancePercent),
            rainToday: try container.decodeIfPresent(String.self, forKey: .rainToday),
            highTemperature: try container.decodeIfPresent(String.self, forKey: .highTemperature),
            lowTemperature: try container.decodeIfPresent(String.self, forKey: .lowTemperature),
            sunrise: try container.decodeIfPresent(String.self, forKey: .sunrise),
            sunset: try container.decodeIfPresent(String.self, forKey: .sunset),
            nextHourSymbolName: try container.decodeIfPresent(String.self, forKey: .nextHourSymbolName),
            nextHourTemperature: try container.decodeIfPresent(String.self, forKey: .nextHourTemperature),
            nextHourCondition: try container.decodeIfPresent(String.self, forKey: .nextHourCondition),
            airQualityIndex: try container.decodeIfPresent(Int.self, forKey: .airQualityIndex),
            airQualityUpdatedAt: try container.decodeIfPresent(Date.self, forKey: .airQualityUpdatedAt),
            localForecast: try container.decodeIfPresent(CanvasWeatherLocalForecast.self, forKey: .localForecast),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt)
        )
    }

    var conditionsText: String { "\(temperature) · \(condition)" }

    var displayText: String { conditionsText }

    func addingAirQualityIndex(_ value: Int?, observedAt: Date? = nil) -> Self {
        var copy = self
        copy.airQualityIndex = value
        copy.airQualityUpdatedAt = value == nil ? nil : (observedAt ?? .now)
        return copy
    }

    /// Station observations and device-local forecasts have independent clocks.
    func mergingIndependentUpdates(from incoming: Self) -> Self {
        var result = incoming.updatedAt > updatedAt ? incoming : self
        if let forecast = incoming.localForecast,
           forecast.updatedAt >= (localForecast?.updatedAt ?? .distantPast) {
            result.localForecast = forecast
        } else {
            result.localForecast = localForecast
        }
        if let date = incoming.airQualityUpdatedAt,
           date >= (airQualityUpdatedAt ?? .distantPast) {
            result.airQualityIndex = incoming.airQualityIndex
            result.airQualityUpdatedAt = date
        } else {
            result.airQualityIndex = airQualityIndex
            result.airQualityUpdatedAt = airQualityUpdatedAt
        }
        return result
    }

    func removingExpiredAirQuality(at now: Date) -> Self {
        guard airQualityIndex != nil,
              let date = airQualityUpdatedAt,
              now.timeIntervalSince(date) <= CanvasWeatherFreshnessPolicy.airQualityMaximumAge else {
            return addingAirQualityIndex(nil)
        }
        return self
    }

    static let preview = Self(
        symbolName: "sun.max.fill",
        condition: "Sunny",
        temperature: "74°F",
        apparentTemperature: "72°F",
        humidityPercent: 51,
        wind: "SW 4 mph",
        uvIndex: 7,
        dewPoint: "54°F",
        dewPointF: 54,
        pressure: "30.06 inHg",
        rainRate: "0.00 in/hr",
        solarRadiation: "684 W/m²",
        rainToday: "0.00 in",
        highTemperature: "79°F",
        lowTemperature: "61°F",
        airQualityIndex: 32
    )
}

/// Forecasts near the iPad are deliberately separate from selected station data.
/// The current ClimateIQ device endpoint does not return station coordinates.
struct CanvasWeatherLocalForecast: Codable, Equatable, Sendable {
    let symbolName: String
    let condition: String
    let temperature: String
    let apparentTemperature: String?
    let humidityPercent: Int?
    let wind: String?
    let uvIndex: Int?
    let dewPoint: String?
    let dewPointF: Double?
    let precipitationChancePercent: Int?
    let highTemperature: String?
    let lowTemperature: String?
    let sunrise: String?
    let sunset: String?
    let nextHourSymbolName: String?
    let nextHourTemperature: String?
    let nextHourCondition: String?
    let updatedAt: Date

    init(_ snapshot: CanvasWeatherSnapshot, station: CanvasWeatherSnapshot? = nil) {
        symbolName = snapshot.symbolName
        condition = snapshot.condition
        temperature = snapshot.temperature
        apparentTemperature = station?.apparentTemperature == nil ? snapshot.apparentTemperature : nil
        humidityPercent = station?.humidityPercent == nil ? snapshot.humidityPercent : nil
        wind = station?.wind == nil ? snapshot.wind : nil
        uvIndex = station?.uvIndex == nil ? snapshot.uvIndex : nil
        dewPoint = station?.dewPoint == nil ? snapshot.dewPoint : nil
        dewPointF = station?.dewPointF == nil ? snapshot.dewPointF : nil
        precipitationChancePercent = snapshot.precipitationChancePercent
        highTemperature = snapshot.highTemperature
        lowTemperature = snapshot.lowTemperature
        sunrise = snapshot.sunrise
        sunset = snapshot.sunset
        nextHourSymbolName = snapshot.nextHourSymbolName
        nextHourTemperature = snapshot.nextHourTemperature
        nextHourCondition = snapshot.nextHourCondition
        updatedAt = snapshot.updatedAt
    }

    var snapshot: CanvasWeatherSnapshot {
        CanvasWeatherSnapshot(symbolName: symbolName, condition: condition, temperature: temperature,
            apparentTemperature: apparentTemperature, humidityPercent: humidityPercent, wind: wind,
            uvIndex: uvIndex, dewPoint: dewPoint, dewPointF: dewPointF,
            precipitationChancePercent: precipitationChancePercent,
            highTemperature: highTemperature, lowTemperature: lowTemperature,
            sunrise: sunrise, sunset: sunset, nextHourSymbolName: nextHourSymbolName,
            nextHourTemperature: nextHourTemperature, nextHourCondition: nextHourCondition,
            updatedAt: updatedAt)
    }
}

enum CanvasWeatherFreshnessPolicy {
    static let locationMaximumAge: TimeInterval = 15 * 60
    static let airQualityMaximumAge: TimeInterval = 2 * 60 * 60

    static func needsLocation(_ location: CLLocation?, at now: Date) -> Bool {
        guard let location, location.horizontalAccuracy >= 0 else { return true }
        return abs(now.timeIntervalSince(location.timestamp)) > locationMaximumAge
    }

    static func label(snapshot: CanvasWeatherSnapshot, source: CanvasWeatherSource,
                      status: WeatherOverlayStatus, at now: Date) -> String? {
        guard snapshot.updatedAt != .distantPast else { return "Observation time unavailable" }
        let age = max(0, now.timeIntervalSince(snapshot.updatedAt))
        let stale = age > (source == .ambientStation ? 5 * 60 : 30 * 60)
        let unavailable = ![WeatherOverlayStatus.live, .fetching].contains(status)
        guard stale || unavailable else { return nil }
        return "Cached · Updated " + snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened)
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
            "Loading current weather."
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

    func addingAirQualityIndex(_ value: Int?, observedAt: Date? = nil) -> Self {
        Self(
            snapshot: snapshot.addingAirQualityIndex(value, observedAt: observedAt),
            attributionURL: attributionURL,
            attributionMarkURL: attributionMarkURL
        )
    }
}

protocol CanvasWeatherProviding {
    func currentWeather(for location: CLLocation) async throws -> CanvasWeatherProviderResult
}

enum CanvasAmbientRefreshPolicy {
    /// Most Ambient stations publish a new API reading about once per minute.
    /// Polling at that boundary avoids duplicate readings while remaining
    /// comfortably below the proxy and Ambient API request limits.
    static let upstreamUpdateFloor: TimeInterval = 60
    static let pollingInterval: TimeInterval = upstreamUpdateFloor

    static func shouldPublish(
        existing: CanvasWeatherSnapshot?,
        incoming: CanvasWeatherSnapshot,
        source: CanvasWeatherSource
    ) -> Bool {
        guard source == .ambientStation, let existing else { return true }
        return incoming.updatedAt > existing.updatedAt
    }
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

    /// Credentials participate in isolation without being written to UserDefaults.
    var cacheIdentity: String {
        let station = ambientDeviceMAC.flatMap(AmbientWeatherCanvasProvider.normalizeMAC) ?? "automatic"
        let value = source == .weatherKit ? source.rawValue : "\(source.rawValue)|\(station)|\(ambientAPIKey ?? "")"
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

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
    let dewPointF: Double?
    let solarRadiationWm2: Double?
    let rainTodayIn: Double?
    let highF: Double?
    let lowF: Double?
    let asOf: String?
}

struct CanvasAmbientCurrentResponse: Decodable, Sendable, Equatable {
    let reading: CanvasAmbientReading?
}

/// A connected station is the sole weather provider. Apple Weather is used
/// only by the unconnected configuration; station failures never mix sources.
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

    func currentWeather(for location: CLLocation) async throws -> CanvasWeatherProviderResult {
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
              let reading = payload.reading else {
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
        let symbolName = raining ? "cloud.rain.fill" : "cloud.fill"
        let condition = raining ? "Rain" : "Conditions unavailable"
        // An absent or malformed source timestamp must never look newer than
        // a valid cached reading.
        let updatedAt = parseDate(reading.asOf) ?? .distantPast

        return CanvasWeatherSnapshot(
            symbolName: symbolName,
            condition: condition,
            temperature: temperature(reading.tempF) ?? "—",
            apparentTemperature: temperature(reading.apparentTempF),
            humidityPercent: reading.humidityPercent.map { Int($0.rounded()) },
            wind: wind(reading.windMph, gust: reading.windGustMph, direction: reading.windDirectionDeg),
            uvIndex: reading.uvIndex.map { Int($0.rounded()) },
            dewPoint: temperature(reading.dewPointF),
            dewPointF: reading.dewPointF,
            pressure: pressure(reading.pressureInHg),
            rainRate: rainfallRate(reading.hourlyRainIn),
            solarRadiation: solarRadiation(reading.solarRadiationWm2),
            rainToday: rainfall(reading.rainTodayIn),
            highTemperature: temperature(reading.highF),
            lowTemperature: temperature(reading.lowF),
            updatedAt: updatedAt
        )
    }

    private static func temperature(_ value: Double?) -> String? {
        guard let value else { return nil }
        return CanvasWeatherTemperatureFormatter.string(
            from: value,
            unit: .fahrenheit
        )
    }

    private static func wind(_ speed: Double?, gust: Double?, direction: Double?) -> String? {
        guard speed != nil || gust != nil else { return nil }
        let formatter = MeasurementFormatter()
        formatter.locale = .current
        formatter.unitOptions = .naturalScale
        formatter.numberFormatter.maximumFractionDigits = 0
        let speedText = speed.map { formatter.string(from: Measurement(value: $0, unit: UnitSpeed.milesPerHour)) }
        let gustText = gust.map { formatter.string(from: Measurement(value: $0, unit: UnitSpeed.milesPerHour)) }
        let directionText = direction.map(compass)

        switch (speedText, gustText, directionText) {
        case let (speed?, gust?, direction?):
            return "\(direction) \(speed) · G \(gust)"
        case let (speed?, gust?, nil):
            return "\(speed) · G \(gust)"
        case let (speed?, nil, direction?):
            return "\(direction) \(speed)"
        case let (speed?, nil, nil):
            return speed
        case let (nil, gust?, _):
            return "G \(gust)"
        default:
            return nil
        }
    }

    private static func pressure(_ value: Double?) -> String? {
        guard let value else { return nil }
        return String(format: "%.2f inHg", value)
    }

    private static func rainfallRate(_ value: Double?) -> String? {
        guard let value else { return nil }
        return String(format: "%.2f in/hr", max(0, value))
    }

    private static func solarRadiation(_ value: Double?) -> String? {
        guard let value else { return nil }
        return String(format: "%.2f W/m²", max(0, value))
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
    let configuration: CanvasWeatherConfiguration?

    init(defaults: UserDefaults = .standard, configuration: CanvasWeatherConfiguration? = nil) {
        self.defaults = defaults
        self.configuration = configuration
    }

    func currentWeather(for location: CLLocation) async throws -> CanvasWeatherProviderResult {
        let configuration = configuration ?? CanvasWeatherConfiguration.load(defaults: defaults)
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

        let temperatureFormatter = MeasurementFormatter()
        temperatureFormatter.locale = .current
        temperatureFormatter.unitOptions = .naturalScale
        temperatureFormatter.numberFormatter.minimumFractionDigits = 1
        temperatureFormatter.numberFormatter.maximumFractionDigits = 1
        let measurementFormatter = MeasurementFormatter()
        measurementFormatter.locale = .current
        measurementFormatter.unitOptions = .naturalScale
        measurementFormatter.numberFormatter.maximumFractionDigits = 0
        let timeFormatter = DateFormatter()
        timeFormatter.locale = .current
        timeFormatter.timeStyle = .short
        timeFormatter.dateStyle = .none

        let currentHour = hourly.first { abs($0.date.timeIntervalSince(current.date)) < 60 * 60 }
        let nextHour = hourly.first { $0.date > current.date }
        let today = daily.first
        return CanvasWeatherProviderResult(
            snapshot: CanvasWeatherSnapshot(
                symbolName: current.symbolName,
                condition: current.condition.description,
                temperature: temperatureFormatter.string(from: current.temperature),
                apparentTemperature: temperatureFormatter.string(from: current.apparentTemperature),
                humidityPercent: Int((current.humidity * 100).rounded()),
                wind: "\(current.wind.compassDirection.abbreviation) \(measurementFormatter.string(from: current.wind.speed))",
                uvIndex: current.uvIndex.value,
                dewPoint: temperatureFormatter.string(from: current.dewPoint),
                dewPointF: current.dewPoint.converted(to: .fahrenheit).value,
                precipitationChancePercent: currentHour.map { Int(($0.precipitationChance * 100).rounded()) },
                highTemperature: today.map { temperatureFormatter.string(from: $0.highTemperature) },
                lowTemperature: today.map { temperatureFormatter.string(from: $0.lowTemperature) },
                sunrise: today?.sun.sunrise.map(timeFormatter.string(from:)),
                sunset: today?.sun.sunset.map(timeFormatter.string(from:)),
                nextHourSymbolName: nextHour?.symbolName,
                nextHourTemperature: nextHour.map { temperatureFormatter.string(from: $0.temperature) },
                nextHourCondition: nextHour?.condition.description,
                updatedAt: current.date
            ),
            attributionURL: attribution.legalPageURL,
            attributionMarkURL: attribution.squareMarkURL
        )
    }
}

/// Ambient polls station data each minute, while this shared cache requests
/// the device-local forecast at most every 15 minutes for the same location.
actor CanvasWeatherEnrichmentCache {
    static let shared = CanvasWeatherEnrichmentCache()
    private var weather: [String: (Date, CanvasWeatherProviderResult)] = [:]
    private var airQuality: [String: CanvasAirQualityObservation] = [:]
    private let lifetime: TimeInterval

    init(lifetime: TimeInterval = 15 * 60) { self.lifetime = lifetime }

    static func key(for location: CLLocation) -> String {
        "\(AirNowAirQualityProvider.coordinateString(location.coordinate.latitude)),\(AirNowAirQualityProvider.coordinateString(location.coordinate.longitude))|\(Locale.current.identifier)|\(TimeZone.current.identifier)"
    }

    func currentWeather(for location: CLLocation, provider: CanvasWeatherProviding) async throws -> CanvasWeatherProviderResult {
        let key = Self.key(for: location)
        if let cached = weather[key], Date().timeIntervalSince(cached.0) < lifetime { return cached.1 }
        let result = try await provider.currentWeather(for: location)
        // Bound retention when the iPad travels between locations.
        weather = weather.filter { Date().timeIntervalSince($0.value.0) < lifetime }
        weather[key] = (.now, result)
        return result
    }

    func currentAirQuality(for location: CLLocation, provider: CanvasAirQualityProviding) async throws -> CanvasAirQualityObservation? {
        let key = Self.key(for: location)
        if let cached = airQuality[key], Date().timeIntervalSince(cached.checkedAt) < lifetime { return cached }
        guard let observation = try await provider.currentObservation(for: location) else { return nil }
        airQuality = airQuality.filter { Date().timeIntervalSince($0.value.checkedAt) < lifetime }
        airQuality[key] = observation
        return observation
    }
}

struct CachedCanvasLocalWeatherProvider: CanvasWeatherProviding {
    func currentWeather(for location: CLLocation) async throws -> CanvasWeatherProviderResult {
        try await CanvasWeatherEnrichmentCache.shared.currentWeather(for: location, provider: WeatherKitCanvasWeatherProvider())
    }
}

struct CanvasAirQualityObservation: Equatable, Sendable {
    let value: Int
    /// Time of successful service retrieval. The API does not expose an observation timestamp.
    let checkedAt: Date
}

struct CachedCanvasAirQualityProvider: CanvasAirQualityProviding {
    func currentUSAirQualityIndex(for location: CLLocation) async throws -> Int? {
        try await currentObservation(for: location)?.value
    }

    func currentObservation(for location: CLLocation) async throws -> CanvasAirQualityObservation? {
        try await CanvasWeatherEnrichmentCache.shared.currentAirQuality(for: location, provider: AirNowAirQualityProvider())
    }
}

protocol CanvasAirQualityProviding: Sendable {
    func currentUSAirQualityIndex(for location: CLLocation) async throws -> Int?
    func currentObservation(for location: CLLocation) async throws -> CanvasAirQualityObservation?
}

extension CanvasAirQualityProviding {
    func currentObservation(for location: CLLocation) async throws -> CanvasAirQualityObservation? {
        guard let value = try await currentUSAirQualityIndex(for: location) else { return nil }
        return CanvasAirQualityObservation(value: value, checkedAt: .now)
    }
}

struct AirNowAirQualityResponse: Decodable, Sendable {
    let aqi: Int?
}

/// AirNow is accessed through ClimateIQ's public, read-only API. The AirNow
/// feed and any server-side caching stay off-device, so the public app carries
/// no provider credential and does not expose a third-party endpoint directly.
struct AirNowAirQualityProvider: CanvasAirQualityProviding {
    static let defaultBaseURL = URL(string: "https://myclimateiq.com")!

    let baseURL: URL
    let session: URLSession

    init(baseURL: URL = Self.defaultBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func currentUSAirQualityIndex(for location: CLLocation) async throws -> Int? {
        guard let url = Self.requestURL(
            baseURL: baseURL,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        ) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        guard let value = try JSONDecoder().decode(AirNowAirQualityResponse.self, from: data).aqi else {
            return nil
        }
        return min(max(value, 0), 500)
    }

    static func requestURL(
        baseURL: URL = defaultBaseURL,
        latitude: CLLocationDegrees,
        longitude: CLLocationDegrees
    ) -> URL? {
        guard let endpoint = URL(string: "api/air-quality", relativeTo: baseURL)?.absoluteURL,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        else {
            return nil
        }

        components.queryItems = [
            URLQueryItem(name: "latitude", value: coordinateString(latitude)),
            URLQueryItem(name: "longitude", value: coordinateString(longitude)),
        ]
        return components.url
    }

    static func coordinateString(_ value: CLLocationDegrees) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
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

/// Optional legacy provider retained for compatibility with older integrations
/// and tests. The public Canvas configuration uses AirNowAirQualityProvider.
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

    // v5 isolates configuration/location and preserves independent provider ages.
    private static let snapshotCacheKey = "canvas.weather.snapshot.v5"
    private static let snapshotSourceCacheKey = "canvas.weather.snapshot-source.v5"
    private static let attributionURLCacheKey = "canvas.weather.attribution-url.v5"
    private static let attributionMarkURLCacheKey = "canvas.weather.attribution-mark-url.v5"
    private static let snapshotIdentityCacheKey = "canvas.weather.snapshot-identity.v5"
    private static let snapshotLocationCacheKey = "canvas.weather.snapshot-location.v5"
    private static let requestTimeoutNanoseconds: UInt64 = 20_000_000_000
    private static let weatherKitPollingInterval: TimeInterval = 15 * 60

    private let weatherProvider: CanvasWeatherProviding?
    private let airQualityProvider: CanvasAirQualityProviding
    private let locationManager: CLLocationManager
    private let autoRequestLocation: Bool
    private let previewMode: Bool
    private let defaults: UserDefaults
    private let configurationProvider: () -> CanvasWeatherConfiguration
    private let ambientPollingInterval: TimeInterval
    private let locationOverride: CLLocation?
    private var refreshTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var activeRequestID = UUID()
    private var refreshInFlight = false
    private var refreshRequested = false
    private var locationRequestInFlight = false
    private var lastLocation: CLLocation?
    private var isForegrounded = true
    private var weatherEnabled = false
    private var activeConfiguration: CanvasWeatherConfiguration?
    private var activeWeatherSource: CanvasWeatherSource?
    private var snapshotLocation: CLLocation?
    private var lastAuthorizationStatus: CLAuthorizationStatus?

    init(
        weatherProvider: CanvasWeatherProviding? = nil,
        airQualityProvider: CanvasAirQualityProviding = CachedCanvasAirQualityProvider(),
        autoRequestLocation: Bool = true,
        initialLocation: CLLocation? = nil,
        ambientPollingInterval: TimeInterval = CanvasAmbientRefreshPolicy.pollingInterval,
        defaults: UserDefaults = .standard,
        configurationProvider: @escaping () -> CanvasWeatherConfiguration = { CanvasWeatherConfiguration.load() }
    ) {
        self.weatherProvider = weatherProvider
        self.airQualityProvider = airQualityProvider
        self.locationManager = CLLocationManager()
        self.autoRequestLocation = autoRequestLocation
        self.locationOverride = initialLocation
        self.lastLocation = initialLocation
        self.ambientPollingInterval = ambientPollingInterval
        self.defaults = defaults
        self.configurationProvider = configurationProvider
        self.previewMode = ProcessInfo.processInfo.arguments.contains("--canvas-ui-weather-preview")
            || ProcessInfo.processInfo.arguments.contains("--canvas-ui-weather-frame")
            || ProcessInfo.processInfo.arguments.contains("--canvas-ui-store-weather")
            || ProcessInfo.processInfo.arguments.contains("--canvas-ui-store-weather-station")
        super.init()
        lastAuthorizationStatus = locationManager.authorizationStatus
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        locationManager.distanceFilter = 1_000
        if previewMode {
            loadPreviewSnapshot()
        } else {
            loadCachedSnapshot()
        }
        activeConfiguration = configurationProvider()
        activeWeatherSource = activeConfiguration?.source
    }

    deinit {
        refreshTask?.cancel()
        pollingTask?.cancel()
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

        let configuration = configurationProvider()
        applyConfiguration(configuration)
        weatherEnabled = true
        loadCachedSnapshot()
        if configuration.source == .ambientStation, configuration.ambientAPIKey == nil {
            stopPolling()
            finishWithoutRequest(status: .ambientConfigurationMissing, preserveSnapshot: false)
            return
        }
        startPollingIfNeeded()
        refreshNow(requestPermission: autoRequestLocation)
    }

    /// Ties weather work to the live frame's lifecycle. Going inactive stops
    /// the timer and cancels the in-flight request; returning active starts a
    /// fresh request immediately and resumes the Ambient cadence.
    func setActive(_ active: Bool) {
        guard isForegrounded != active else { return }
        isForegrounded = active
        if active {
            lastLocation = locationOverride
            refreshNow(requestPermission: false)
            startPollingIfNeeded()
        } else {
            stopPolling()
            refreshRequested = false
            cancelActiveRefresh()
            if snapshot != nil {
                isUsingCachedSnapshot = true
            }
        }
    }

    /// Re-checks the OS permission when the app returns from Settings without
    /// prompting again automatically.
    func refreshAuthorization() {
        guard weatherEnabled, isForegrounded else { return }
        if previewMode {
            loadPreviewSnapshot()
            return
        }
        startPollingIfNeeded()
        refreshNow(requestPermission: false)
    }

    func clear() {
        stopPolling()
        refreshRequested = false
        cancelActiveRefresh()
        weatherEnabled = false
        snapshot = nil
        attributionURL = nil
        attributionMarkURL = nil
        errorMessage = nil
        isLoading = false
        status = .disabled
        isUsingCachedSnapshot = false
    }

    @discardableResult
    func refreshNow(requestPermission: Bool = false) -> Bool {
        guard weatherEnabled, isForegrounded, !previewMode else { return false }

        let configuration = configurationProvider()
        applyConfiguration(configuration)
        startPollingIfNeeded()
        if configuration.source == .ambientStation, configuration.ambientAPIKey == nil {
            stopPolling()
            finishWithoutRequest(status: .ambientConfigurationMissing, preserveSnapshot: false)
            return false
        }

        if refreshInFlight || locationRequestInFlight {
            refreshRequested = true
            return false
        }

        // Tests can supply a fixed location so the service's polling and
        // publication state can be exercised without depending on simulator
        // authorization. Production callers leave this nil.
        if let locationOverride {
            fetchWeather(for: locationOverride)
            return true
        }

        switch locationManager.authorizationStatus {
        case .notDetermined:
            isLoading = requestPermission
            status = requestPermission ? .requestingLocation : .needsLocationPermission
            errorMessage = status.message
            if requestPermission {
                locationManager.requestWhenInUseAuthorization()
            }
        case .authorizedWhenInUse, .authorizedAlways:
            if !CanvasWeatherFreshnessPolicy.needsLocation(lastLocation, at: .now), let lastLocation {
                fetchWeather(for: lastLocation)
            } else {
                locationRequestInFlight = true
                isLoading = true
                status = .locating
                errorMessage = nil
                locationManager.requestLocation()
            }
        case .denied:
            finishWithoutRequest(status: .locationDenied)
        case .restricted:
            finishWithoutRequest(status: .locationRestricted)
        @unknown default:
            finishWithoutRequest(status: .locationUnavailable)
        }
        return true
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // CLLocationManager delivers an initial delegate notification even when
        // authorization has not changed. It must not queue a second refresh.
        // A supplied fixed location deliberately bypasses the OS location path.
        let authorization = manager.authorizationStatus
        guard locationOverride == nil, authorization != lastAuthorizationStatus else { return }
        lastAuthorizationStatus = authorization
        guard weatherEnabled, isForegrounded else { return }
        locationRequestInFlight = false
        refreshNow(requestPermission: false)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard locationOverride == nil, weatherEnabled, isForegrounded, let location = locations.last else { return }
        locationRequestInFlight = false
        guard location.horizontalAccuracy >= 0 else {
            finishWithoutRequest(status: .locationUnavailable)
            return
        }
        lastLocation = location
        locationManager.stopUpdatingLocation()
        fetchWeather(for: location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard locationOverride == nil, weatherEnabled, isForegrounded else { return }
        locationRequestInFlight = false
        if manager.authorizationStatus == .denied {
            finishWithoutRequest(status: .locationDenied)
        } else {
            finishWithoutRequest(status: .locationUnavailable)
        }
    }

    private func applyConfiguration(_ configuration: CanvasWeatherConfiguration) {
        if activeConfiguration?.cacheIdentity != configuration.cacheIdentity {
            stopPolling()
            refreshRequested = false
            cancelActiveRefresh()
            snapshot = nil
            snapshotLocation = nil
            attributionURL = nil
            attributionMarkURL = nil
            isUsingCachedSnapshot = false
        }
        activeConfiguration = configuration
        activeWeatherSource = configuration.source
    }

    private func startPollingIfNeeded() {
        guard
            !previewMode,
            weatherEnabled,
            isForegrounded,
            let source = activeWeatherSource,
            source == .ambientStation || source == .weatherKit
        else {
            stopPolling()
            return
        }
        guard pollingTask == nil else { return }

        let interval = source == .ambientStation ? ambientPollingInterval : Self.weatherKitPollingInterval
        let nanoseconds = UInt64(max(0.01, interval) * 1_000_000_000)
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
                guard
                    let self,
                    self.weatherEnabled,
                    self.isForegrounded,
                    self.activeWeatherSource == source
                else {
                    return
                }
                self.refreshNow(requestPermission: false)
            }
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func cancelActiveRefresh() {
        activeRequestID = UUID()
        refreshTask?.cancel()
        locationManager.stopUpdatingLocation()
        locationRequestInFlight = false
        isLoading = false
    }

    private func fetchWeather(for location: CLLocation) {
        guard !refreshInFlight else {
            refreshRequested = true
            return
        }

        let requestID = UUID()
        activeRequestID = requestID
        let source = activeWeatherSource ?? configurationProvider().source
        let configuration = activeConfiguration ?? configurationProvider()
        let provider = weatherProvider ?? ConfiguredCanvasWeatherProvider(defaults: defaults, configuration: configuration)
        if let snapshotLocation, snapshotLocation.distance(from: location) > 1_000 {
            snapshot = nil
            attributionURL = nil
            attributionMarkURL = nil
        }
        snapshotLocation = location
        let airQualityProvider = airQualityProvider
        let previous = snapshot?.removingExpiredAirQuality(at: .now)
        isUsingCachedSnapshot = snapshot != nil
        refreshInFlight = true
        isLoading = true
        status = .fetching
        errorMessage = nil

        refreshTask = Task { @MainActor [weak self] in
            defer { self?.completeRefresh(requestID: requestID) }
            do {
                let result = try await Self.withTimeout {
                    async let airQuality = try? await airQualityProvider.currentObservation(for: location)
                    var result = try await provider.currentWeather(for: location)
                    if let airQuality = await airQuality {
                        result = result.addingAirQualityIndex(airQuality.value, observedAt: airQuality.checkedAt)
                    } else if let previousAirQualityIndex = previous?.airQualityIndex {
                        // Preserve the last known official value if the weather
                        // refresh succeeds while the AQI service is unavailable.
                        result = result.addingAirQualityIndex(previousAirQualityIndex, observedAt: previous?.airQualityUpdatedAt)
                    }
                    return result
                }
                guard !Task.isCancelled else { return }
                guard
                    let self,
                    self.weatherEnabled,
                    self.isForegrounded,
                    self.activeRequestID == requestID
                else { return }
                guard self.configurationProvider().cacheIdentity == configuration.cacheIdentity else {
                    self.update(showWeather: true)
                    return
                }
                self.publish(result, source: source)
            } catch is CancellationError {
                return
            } catch {
                guard
                    let self,
                    self.weatherEnabled,
                    self.isForegrounded,
                    self.activeRequestID == requestID
                else { return }
                self.isLoading = false
                self.status = Self.status(for: error)
                self.errorMessage = self.status.message
                if self.snapshot != nil {
                    self.isUsingCachedSnapshot = true
                }
            }
        }
    }

    private func completeRefresh(requestID _: UUID) {
        guard refreshInFlight else { return }
        refreshInFlight = false
        refreshTask = nil

        guard weatherEnabled, isForegrounded else {
            refreshRequested = false
            return
        }
        guard refreshRequested else { return }
        refreshRequested = false
        refreshNow(requestPermission: false)
    }

    private func publish(_ result: CanvasWeatherProviderResult, source: CanvasWeatherSource) {
        let stationAdvanced = snapshot == nil || result.snapshot.updatedAt > snapshot!.updatedAt
        let merged: CanvasWeatherSnapshot
        if source == .ambientStation, let existing = snapshot {
            merged = existing.mergingIndependentUpdates(from: result.snapshot)
        } else {
            merged = result.snapshot
        }
        snapshot = merged.removingExpiredAirQuality(at: .now)
        attributionURL = result.attributionURL
        attributionMarkURL = result.attributionMarkURL
        isUsingCachedSnapshot = source == .ambientStation && !stationAdvanced
        isLoading = false
        status = .live
        errorMessage = nil
        if let snapshot {
            persist(CanvasWeatherProviderResult(snapshot: snapshot, attributionURL: result.attributionURL, attributionMarkURL: result.attributionMarkURL), source: source)
        }
    }

    private func finishWithoutRequest(status: WeatherOverlayStatus, preserveSnapshot: Bool = true) {
        cancelActiveRefresh()
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
            guard let result = try await group.next() else { throw CancellationError() }
            return result
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
        let source = configurationProvider().source
        let cachedSource = defaults.string(forKey: Self.snapshotSourceCacheKey)
        guard cachedSource == source.rawValue,
              defaults.string(forKey: Self.snapshotIdentityCacheKey) == configurationProvider().cacheIdentity else { return }
        if snapshot == nil,
           let data = defaults.data(forKey: Self.snapshotCacheKey),
           let cached = try? JSONDecoder().decode(CanvasWeatherSnapshot.self, from: data) {
            snapshot = cached.removingExpiredAirQuality(at: .now)
            if let coordinates = defaults.array(forKey: Self.snapshotLocationCacheKey) as? [Double], coordinates.count == 2 {
                snapshotLocation = CLLocation(latitude: coordinates[0], longitude: coordinates[1])
            }
            isUsingCachedSnapshot = true
        }
        if attributionURL == nil,
           let rawURL = defaults.string(forKey: Self.attributionURLCacheKey),
           let url = URL(string: rawURL) {
            attributionURL = url
        }
        if attributionMarkURL == nil,
           let rawURL = defaults.string(forKey: Self.attributionMarkURLCacheKey),
           let url = URL(string: rawURL) {
            attributionMarkURL = url
        }
    }

    private func loadPreviewSnapshot() {
        stopPolling()
        refreshRequested = false
        cancelActiveRefresh()
        weatherEnabled = true
        snapshot = .preview
        if ProcessInfo.processInfo.arguments.contains("--canvas-ui-store-weather-station") {
            snapshot = CanvasWeatherSnapshot(
                symbolName: "cloud.fill", condition: "Conditions unavailable", temperature: "59.4°F",
                apparentTemperature: "59.4°F", humidityPercent: 98, dewPoint: "59.1°F", dewPointF: 59.1,
                rainToday: "0.00 in", airQualityIndex: 32, airQualityUpdatedAt: .now,
                localForecast: CanvasWeatherLocalForecast(.preview), updatedAt: .now
            )
        }
        attributionURL = URL(string: configurationProvider().source == .ambientStation
            ? "https://ambientweather.com/faqs/question/view/id/1811/"
            : "https://weatherkit.apple.com/legal-attribution.html")
        attributionMarkURL = nil
        errorMessage = nil
        isLoading = false
        status = .live
        isUsingCachedSnapshot = false
    }

    private func persist(_ result: CanvasWeatherProviderResult, source: CanvasWeatherSource) {
        if let data = try? JSONEncoder().encode(result.snapshot) {
            defaults.set(data, forKey: Self.snapshotCacheKey)
        }
        defaults.set(activeConfiguration?.cacheIdentity, forKey: Self.snapshotIdentityCacheKey)
        if let snapshotLocation {
            defaults.set([snapshotLocation.coordinate.latitude, snapshotLocation.coordinate.longitude], forKey: Self.snapshotLocationCacheKey)
        }
        defaults.set(source.rawValue, forKey: Self.snapshotSourceCacheKey)
        defaults.set(result.attributionURL.absoluteString, forKey: Self.attributionURLCacheKey)
        if let markURL = result.attributionMarkURL {
            defaults.set(markURL.absoluteString, forKey: Self.attributionMarkURLCacheKey)
        } else {
            defaults.removeObject(forKey: Self.attributionMarkURLCacheKey)
        }
    }
}
