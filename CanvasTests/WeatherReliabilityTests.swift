import XCTest
import CoreLocation
@testable import Canvas

@MainActor
final class WeatherReliabilityTests: XCTestCase {
    private let location = CLLocation(latitude: 40.44, longitude: -79.98)

    private func configuration(_ station: String = "00:10:FA:AA:BB:CC", key: String = "test-key", source: CanvasWeatherSource = .ambientStation) -> CanvasWeatherConfiguration {
        CanvasWeatherConfiguration(source: source, ambientDeviceMAC: station, ambientAPIKey: key)
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "WeatherReliabilityTests.\(UUID().uuidString)")!
    }

    private func result(_ temperature: String, time: Date, forecastTime: Date? = nil) -> CanvasWeatherProviderResult {
        var snapshot = CanvasWeatherSnapshot(symbolName: "cloud.fill", condition: "Station", temperature: temperature, updatedAt: time)
        if let forecastTime {
            snapshot.localForecast = CanvasWeatherLocalForecast(CanvasWeatherSnapshot(symbolName: "sun.max.fill", condition: "Sunny", temperature: "90°F", updatedAt: forecastTime))
        }
        return CanvasWeatherProviderResult(snapshot: snapshot, attributionURL: URL(string: "https://ambientweather.com")!, attributionMarkURL: nil)
    }

    private func waitFor(_ condition: @escaping () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Weather operation did not reach the expected state")
        throw NSError(domain: "WeatherReliabilityTests", code: 1)
    }

    func testConnectedStationOverridesSavedAppleWeatherPreferenceAndDisconnectRestoresFallback() throws {
        var settings = CanvasSettings()
        XCTAssertEqual(settings.effectiveWeatherSource, .weatherKit)
        settings.ambientDeviceMAC = "00:10:FA:AA:BB:CC"
        XCTAssertEqual(settings.effectiveWeatherSource, .ambientStation)
        let restored = try JSONDecoder().decode(CanvasSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.effectiveWeatherSource, .ambientStation)
        settings.ambientDeviceMAC = nil
        XCTAssertEqual(settings.effectiveWeatherSource, .weatherKit)
    }

    func testStationSwitchCancelsOldPublicationAndAcceptsOlderNewStation() async throws {
        let provider = ControlledWeatherProvider()
        var current = configuration()
        let service = CanvasWeatherService(weatherProvider: provider, airQualityProvider: ReliabilityAQIProvider(), initialLocation: location, ambientPollingInterval: 1000, defaults: defaults(), configurationProvider: { current })
        defer { service.clear() }
        service.update(showWeather: true)
        try await waitFor { await provider.count == 1 }
        current = configuration("00:10:FA:DD:EE:FF")
        service.update(showWeather: true)
        await provider.resolve(0, with: result("72°F", time: Date(timeIntervalSince1970: 2000)))
        try await waitFor { await provider.count == 2 }
        XCTAssertNil(service.snapshot, "A cancelled old-station request must never publish")
        await provider.resolve(1, with: result("50°F", time: Date(timeIntervalSince1970: 1000)))
        try await waitFor { service.snapshot != nil }
        XCTAssertEqual(service.snapshot?.temperature, "50.0°F")
    }

    func testFixedLocationIgnoresInitialAuthorizationAndOSLocationCallbacks() async throws {
        let provider = SequenceWeatherProvider([result("72°F", time: .now)])
        let config = configuration()
        let service = CanvasWeatherService(weatherProvider: provider, airQualityProvider: ReliabilityAQIProvider(), initialLocation: location, ambientPollingInterval: 1000, defaults: defaults(), configurationProvider: { config })
        defer { service.clear() }
        service.update(showWeather: true)
        try await waitFor { service.snapshot != nil && !service.isLoading }
        let manager = CLLocationManager()
        service.locationManagerDidChangeAuthorization(manager)
        service.locationManager(manager, didUpdateLocations: [CLLocation(latitude: 0, longitude: 0)])
        service.locationManager(manager, didFailWithError: NSError(domain: kCLErrorDomain, code: 0))
        try await Task.sleep(nanoseconds: 50_000_000)
        let calls = await provider.count
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(service.status, .live)
    }

    func testCacheNeverCrossesStationAccountOrProvider() async throws {
        let storage = defaults()
        let saved = configuration()
        let provider = SequenceWeatherProvider([result("72°F", time: .now)])
        let service = CanvasWeatherService(weatherProvider: provider, airQualityProvider: ReliabilityAQIProvider(), initialLocation: location, defaults: storage, configurationProvider: { saved })
        service.update(showWeather: true)
        try await waitFor { service.snapshot != nil }
        service.clear()
        let same = CanvasWeatherService(defaults: storage, configurationProvider: { saved })
        XCTAssertEqual(same.snapshot?.temperature, "72.0°F")
        for other in [configuration("00:10:FA:DD:EE:FF"), configuration(key: "other-key"), configuration(source: .weatherKit)] {
            let isolated = CanvasWeatherService(defaults: storage, configurationProvider: { other })
            XCTAssertNil(isolated.snapshot)
        }
        let encodedDefaults = String(describing: storage.dictionaryRepresentation())
        XCTAssertFalse(encodedDefaults.contains("test-key"))
    }

    func testRepeatedStationReadingPublishesNewForecastAndAQI() async throws {
        let time = Date()
        let provider = SequenceWeatherProvider([
            result("72°F", time: time, forecastTime: time),
            result("20°F", time: time, forecastTime: time.addingTimeInterval(60))
        ])
        let air = ReliabilityAQIProvider(values: [25, 80])
        let config = configuration()
        let service = CanvasWeatherService(weatherProvider: provider, airQualityProvider: air, initialLocation: location, ambientPollingInterval: 1000, defaults: defaults(), configurationProvider: { config })
        defer { service.clear() }
        service.update(showWeather: true)
        try await waitFor { service.snapshot?.airQualityIndex == 25 }
        service.refreshNow()
        try await waitFor { service.snapshot?.airQualityIndex == 80 }
        XCTAssertEqual(service.snapshot?.temperature, "72.0°F")
        XCTAssertEqual(service.snapshot?.localForecast?.updatedAt, time.addingTimeInterval(60))
        XCTAssertEqual(service.snapshot?.updatedAt, time)
    }

    func testAQIFailureKeepsOriginalAgeThenExpires() async throws {
        let observationTime = Date().addingTimeInterval(-3600)
        let air = ReliabilityAQIProvider(values: [35, nil], checkedAt: observationTime)
        let provider = SequenceWeatherProvider([result("72°F", time: .now), result("73°F", time: .now)])
        let config = configuration()
        let service = CanvasWeatherService(weatherProvider: provider, airQualityProvider: air, initialLocation: location, ambientPollingInterval: 1000, defaults: defaults(), configurationProvider: { config })
        defer { service.clear() }
        service.update(showWeather: true)
        try await waitFor { service.snapshot?.airQualityIndex == 35 }
        service.refreshNow()
        try await waitFor { await provider.count == 2 && !service.isLoading }
        XCTAssertEqual(service.snapshot?.airQualityUpdatedAt, observationTime)
        XCTAssertNil(service.snapshot?.removingExpiredAirQuality(at: observationTime.addingTimeInterval(7201)).airQualityIndex)
    }

    func testStationAndLocalForecastRemainDistinctAfterCoding() throws {
        let stationTime = Date(timeIntervalSince1970: 1000)
        let forecastTime = Date(timeIntervalSince1970: 2000)
        let input = result("50°F", time: stationTime, forecastTime: forecastTime).snapshot
        let decoded = try JSONDecoder().decode(CanvasWeatherSnapshot.self, from: JSONEncoder().encode(input))
        XCTAssertEqual(decoded.temperature, "50.0°F")
        XCTAssertEqual(decoded.condition, "Station")
        XCTAssertEqual(decoded.localForecast?.temperature, "90.0°F")
        XCTAssertEqual(decoded.localForecast?.condition, "Sunny")
        XCTAssertEqual(decoded.updatedAt, stationTime)
        XCTAssertEqual(decoded.localForecast?.updatedAt, forecastTime)
    }

    func testLocationPolicyRequestsFreshFixAfterAgeThreshold() {
        let now = Date()
        let old = CLLocation(coordinate: location.coordinate, altitude: 0, horizontalAccuracy: 100, verticalAccuracy: 100, timestamp: now.addingTimeInterval(-901))
        XCTAssertTrue(CanvasWeatherFreshnessPolicy.needsLocation(old, at: now))
        XCTAssertFalse(CanvasWeatherFreshnessPolicy.needsLocation(location, at: now))
        XCTAssertTrue(CanvasWeatherFreshnessPolicy.needsLocation(nil, at: now))
    }

    func testFreshnessLabelsSurviveStationSuccessAndNetworkFailure() {
        let now = Date()
        let old = result("50°F", time: now.addingTimeInterval(-3600)).snapshot
        XCTAssertNotNil(CanvasWeatherFreshnessPolicy.label(snapshot: old, source: .ambientStation, status: .live, at: now))
        let recent = result("50°F", time: now).snapshot
        XCTAssertNotNil(CanvasWeatherFreshnessPolicy.label(snapshot: recent, source: .weatherKit, status: .networkUnavailable, at: now))
        XCTAssertNil(CanvasWeatherFreshnessPolicy.label(snapshot: recent, source: .weatherKit, status: .live, at: now))
    }

    func testAmbientProviderReturnsOnlyStationWeather() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [WeatherReliabilityURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let provider = AmbientWeatherCanvasProvider(apiKey: "test-key", deviceMAC: "00:10:FA:AA:BB:CC", baseURL: URL(string: "https://weather.test")!, session: session, defaults: defaults())
        let response = try await provider.currentWeather(for: location)
        XCTAssertEqual(response.snapshot.temperature, "50.0°F")
        XCTAssertEqual(response.snapshot.condition, "Conditions unavailable")
        XCTAssertNil(response.snapshot.localForecast)
        XCTAssertEqual(response.snapshot.updatedAt, .distantPast, "A missing station time must remain unknown without Apple Weather enrichment")
    }

    func testExpiredEnrichmentCacheActuallyRefreshes() async throws {
        let cache = CanvasWeatherEnrichmentCache(lifetime: 0)
        let provider = SequenceWeatherProvider([result("72°F", time: .now)])
        _ = try await cache.currentWeather(for: location, provider: provider)
        _ = try await cache.currentWeather(for: location, provider: provider)
        let count = await provider.count
        XCTAssertEqual(count, 2)
    }

    func testEnrichmentCacheReusesForecastButSeparatesLocationsAndKeepsAQIAge() async throws {
        let cache = CanvasWeatherEnrichmentCache()
        let provider = SequenceWeatherProvider([result("72°F", time: .now)])
        _ = try await cache.currentWeather(for: location, provider: provider)
        _ = try await cache.currentWeather(for: location, provider: provider)
        let firstCount = await provider.count
        XCTAssertEqual(firstCount, 1)
        _ = try await cache.currentWeather(for: CLLocation(latitude: 33.6, longitude: -117.7), provider: provider)
        let secondCount = await provider.count
        XCTAssertEqual(secondCount, 2)
        let air = ReliabilityAQIProvider(values: [45, 90])
        let first = try await cache.currentAirQuality(for: location, provider: air)
        let second = try await cache.currentAirQuality(for: location, provider: air)
        XCTAssertEqual(first, second)
        let airCount = await air.count
        XCTAssertEqual(airCount, 1)
    }
}

private actor ControlledWeatherProvider: CanvasWeatherProviding {
    private(set) var count = 0
    private var pending: [Int: CheckedContinuation<CanvasWeatherProviderResult, Never>] = [:]
    func currentWeather(for location: CLLocation) async throws -> CanvasWeatherProviderResult {
        let index = count
        count += 1
        return await withCheckedContinuation { pending[index] = $0 }
    }
    func resolve(_ index: Int, with result: CanvasWeatherProviderResult) {
        pending.removeValue(forKey: index)?.resume(returning: result)
    }
}

private actor SequenceWeatherProvider: CanvasWeatherProviding {
    private(set) var count = 0
    let results: [CanvasWeatherProviderResult]
    init(_ results: [CanvasWeatherProviderResult]) { self.results = results }
    func currentWeather(for location: CLLocation) async throws -> CanvasWeatherProviderResult {
        defer { count += 1 }
        return results[min(count, results.count - 1)]
    }
}

private actor ReliabilityAQIProvider: CanvasAirQualityProviding {
    private(set) var count = 0
    let values: [Int?]
    let checkedAt: Date?
    init(values: [Int?] = [nil], checkedAt: Date? = nil) { self.values = values; self.checkedAt = checkedAt }
    func currentUSAirQualityIndex(for location: CLLocation) async throws -> Int? {
        try await currentObservation(for: location)?.value
    }
    func currentObservation(for location: CLLocation) async throws -> CanvasAirQualityObservation? {
        defer { count += 1 }
        guard let value = values[min(count, values.count - 1)] else { return nil }
        return CanvasAirQualityObservation(value: value, checkedAt: checkedAt ?? .now)
    }
}

private final class WeatherReliabilityURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "weather.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"reading":{"tempF":50,"hourlyRainIn":0}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
