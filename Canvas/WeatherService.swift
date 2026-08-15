import Combine
import CoreLocation
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
        self.temperature = CanvasWeatherTemperatureFormatter.normalized(temperature) ?? temperature
        self.apparentTemperature = CanvasWeatherTemperatureFormatter.normalized(apparentTemperature)
        self.humidityPercent = humidityPercent
        self.wind = wind
        self.uvIndex = uvIndex
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
            updatedAt: try container.decode(Date.self, forKey: .updatedAt)
        )
    }

    var conditionsText: String { "\(temperature) · \(condition)" }

    var displayText: String { conditionsText }

    func applying(condition: CanvasWeatherCondition) -> Self {
        Self(
            symbolName: condition.symbolName,
            condition: condition.text,
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
            airQualityIndex: airQualityIndex,
            updatedAt: updatedAt
        )
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

struct CanvasWeatherCondition: Equatable, Sendable {
    let symbolName: String
    let text: String
}

protocol CanvasCurrentConditionProviding {
    func currentCondition(for location: CLLocation) async throws -> CanvasWeatherCondition
}

/// WeatherKit owns the condition description and symbol used by both weather
/// sources. Ambient still supplies the station measurements below.
struct WeatherKitCurrentConditionProvider: CanvasCurrentConditionProviding {
    func currentCondition(for location: CLLocation) async throws -> CanvasWeatherCondition {
        let current = try await WeatherKit.WeatherService.shared.weather(
            for: location,
            including: .current
        )
        return CanvasWeatherCondition(
            symbolName: current.symbolName,
            text: current.condition.description
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

/// Ambient stations report measurements rather than a condition. WeatherKit
/// supplies the current condition glyph and description for both sources.
struct AmbientWeatherCanvasProvider: CanvasWeatherProviding {
    let apiKey: String
    let deviceMAC: String?
    let baseURL: URL
    let session: URLSession
    let defaults: UserDefaults
    let conditionProvider: CanvasCurrentConditionProviding

    init(
        apiKey: String,
        deviceMAC: String? = nil,
        baseURL: URL = URL(string: "https://myclimateiq.com")!,
        session: URLSession = .shared,
        defaults: UserDefaults = .standard,
        conditionProvider: CanvasCurrentConditionProviding = WeatherKitCurrentConditionProvider()
    ) {
        self.apiKey = apiKey
        self.deviceMAC = deviceMAC
        self.baseURL = baseURL
        self.session = session
        self.defaults = defaults
        self.conditionProvider = conditionProvider
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
              let reading = payload.reading,
              reading.tempF != nil else {
            throw CanvasAmbientWeatherProviderError.noReading
        }

        var result = Self.result(from: reading)
        // Ambient provides station measurements but no sky condition. Keep
        // the station's temperature/rain readings and enrich only the glyph
        // and condition text from WeatherKit. If that lookup is unavailable,
        // the station fallback stays honest instead of inventing Clear.
        if let condition = try? await conditionProvider.currentCondition(for: location) {
            result = CanvasWeatherProviderResult(
                snapshot: result.snapshot.applying(condition: condition),
                attributionURL: result.attributionURL,
                attributionMarkURL: result.attributionMarkURL
            )
        }
        return result
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
        return CanvasWeatherTemperatureFormatter.string(
            from: value,
            unit: .fahrenheit
        )
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
        let nextHour = hourly.first { $0.date > current.date.addingTimeInterval(30 * 60) }
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
                precipitationChancePercent: currentHour.map { Int(($0.precipitationChance * 100).rounded()) },
                highTemperature: today.map { temperatureFormatter.string(from: $0.highTemperature) },
                lowTemperature: today.map { temperatureFormatter.string(from: $0.lowTemperature) },
                sunrise: today?.sun.sunrise.map(timeFormatter.string(from:)),
                sunset: today?.sun.sunset.map(timeFormatter.string(from:)),
                nextHourSymbolName: nextHour?.symbolName,
                nextHourTemperature: nextHour.map { temperatureFormatter.string(from: $0.temperature) },
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
    private static let weatherKitPollingInterval: TimeInterval = 15 * 60

    private let weatherProvider: CanvasWeatherProviding
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
    private var activeWeatherSource: CanvasWeatherSource?

    init(
        weatherProvider: CanvasWeatherProviding = ConfiguredCanvasWeatherProvider(),
        airQualityProvider: CanvasAirQualityProviding = OpenMeteoAirQualityProvider(),
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
        activeWeatherSource = configurationProvider().source
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
        if activeWeatherSource != nil, activeWeatherSource != configuration.source {
            stopPolling()
            cancelActiveRefresh()
            snapshot = nil
            attributionURL = nil
            attributionMarkURL = nil
            isUsingCachedSnapshot = false
        }
        activeWeatherSource = configuration.source
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
            startPollingIfNeeded()
            refreshNow(requestPermission: false)
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
        activeWeatherSource = configuration.source
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
            if let lastLocation {
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
        guard weatherEnabled, isForegrounded else { return }
        locationRequestInFlight = false
        refreshNow(requestPermission: false)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard weatherEnabled, isForegrounded, let location = locations.last else { return }
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
        guard weatherEnabled, isForegrounded else { return }
        locationRequestInFlight = false
        if manager.authorizationStatus == .denied {
            finishWithoutRequest(status: .locationDenied)
        } else {
            finishWithoutRequest(status: .locationUnavailable)
        }
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
        let provider = weatherProvider
        let airQualityProvider = airQualityProvider
        isUsingCachedSnapshot = snapshot != nil
        refreshInFlight = true
        isLoading = true
        status = .fetching
        errorMessage = nil

        refreshTask = Task { @MainActor [weak self] in
            defer { self?.completeRefresh(requestID: requestID) }
            do {
                let result = try await Self.withTimeout {
                    async let airQualityIndex = try? await airQualityProvider.currentUSAirQualityIndex(for: location)
                    var result = try await provider.currentWeather(for: location)
                    result = result.addingAirQualityIndex(await airQualityIndex)
                    return result
                }
                guard !Task.isCancelled else { return }
                guard
                    let self,
                    self.weatherEnabled,
                    self.isForegrounded,
                    self.activeRequestID == requestID
                else { return }
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
        guard CanvasAmbientRefreshPolicy.shouldPublish(existing: snapshot, incoming: result.snapshot, source: source) else {
            isLoading = false
            status = .live
            errorMessage = nil
            if snapshot != nil {
                isUsingCachedSnapshot = true
            }
            return
        }

        snapshot = result.snapshot
        attributionURL = result.attributionURL
        attributionMarkURL = result.attributionMarkURL
        isUsingCachedSnapshot = false
        isLoading = false
        status = .live
        errorMessage = nil
        persist(result, source: source)
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
        let source = configurationProvider().source
        let cachedSource = defaults.string(forKey: Self.snapshotSourceCacheKey)
        guard source == .weatherKit || cachedSource == source.rawValue else { return }
        if snapshot == nil,
           let data = defaults.data(forKey: Self.snapshotCacheKey),
           let cached = try? JSONDecoder().decode(CanvasWeatherSnapshot.self, from: data) {
            snapshot = cached
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
        attributionURL = URL(string: "https://weatherkit.apple.com/legal-attribution.html")
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
        defaults.set(source.rawValue, forKey: Self.snapshotSourceCacheKey)
        defaults.set(result.attributionURL.absoluteString, forKey: Self.attributionURLCacheKey)
        if let markURL = result.attributionMarkURL {
            defaults.set(markURL.absoluteString, forKey: Self.attributionMarkURLCacheKey)
        } else {
            defaults.removeObject(forKey: Self.attributionMarkURLCacheKey)
        }
    }
}
