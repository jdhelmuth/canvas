import Foundation
import Combine

@MainActor
final class SettingsStore: ObservableObject {
    private static let currentSchema = 5
    @Published var settings: CanvasSettings { didSet { save() } }
    private let defaults: UserDefaults
    private let key = "canvas.settings.v1"
    private let schemaKey = "canvas.settings.schema"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), var decoded = try? JSONDecoder().decode(CanvasSettings.self, from: data) {
            var migrated = false
            // Migrate the original blue placeholder backdrop to the neutral contextual treatment.
            if decoded.backgroundHex.uppercased() == "#0B1020" {
                decoded.backgroundHex = "#151513"
                migrated = true
            }
            // Retain the original schema migration for users who already ran
            // those builds. The explicit framingMode migration below is the
            // current source of truth and defaults legacy users to no crop.
            if defaults.object(forKey: schemaKey) == nil {
                decoded.fitMode = false
                defaults.set(2, forKey: schemaKey)
                migrated = true
            }
            // The framing choice is explicit in current builds. Older builds
            // only had the ambiguous Fit image toggle (and some persisted
            // settings have no key at all), so migrate those users to the
            // safe no-crop presentation rather than silently cropping media.
            if decoded.framingMode == nil {
                decoded.framingMode = .fitWithBorder
                defaults.set(3, forKey: schemaKey)
                migrated = true
            }
            if decoded.overlays.migrateLegacySharedStroke() {
                migrated = true
            }
            if decoded.normalizePlaybackTiming() {
                migrated = true
            }
            for index in decoded.presets.indices {
                if decoded.presets[index].settings.overlays.migrateLegacySharedStroke() {
                    migrated = true
                }
                if decoded.presets[index].settings.normalizePlaybackTiming() {
                    migrated = true
                }
            }
            // Schema 4 briefly forced every existing device to Fit. Restore
            // Fill / zoom only for devices affected by that migration; other
            // explicit framing choices remain untouched.
            if defaults.integer(forKey: schemaKey) == 4 {
                decoded.framingMode = .fillZoom
                migrated = true
            }
            if defaults.integer(forKey: schemaKey) < Self.currentSchema {
                defaults.set(Self.currentSchema, forKey: schemaKey)
                migrated = true
            }
            settings = decoded
            // Persist migrations immediately so a launch followed by a force
            // quit does not silently rehydrate the old blue/letterboxed state.
            if migrated { save() }
        } else {
            settings = CanvasSettings()
            defaults.set(Self.currentSchema, forKey: schemaKey)
        }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }

    /// Applies a settings edit as one value-type replacement. SwiftUI sliders
    /// can mutate nested fields many times per drag; replacing the snapshot
    /// guarantees @Published, AppStore observers, and UserDefaults persistence
    /// all see every intermediate value.
    func update(_ mutate: (inout CanvasSettings) -> Void) {
        var snapshot = settings
        mutate(&snapshot)
        snapshot.normalizePlaybackTiming()
        settings = snapshot
    }
}

@MainActor
final class AppStore: ObservableObject {
    let settingsStore: SettingsStore
    let library: PhotoLibraryService
    let googlePhotos: GooglePhotosService
    let queue: QueueService
    let loader: AssetImageLoader
    let audio: AudioService
    let power: PowerService
    let weather: CanvasWeatherService
    private var settingsSubscription: AnyCancellable?
    private var librarySubscription: AnyCancellable?
    private var googlePhotosSubscription: AnyCancellable?
    private var weatherSubscription: AnyCancellable?

    var settings: CanvasSettings { settingsStore.settings }
    init() {
        if ProcessInfo.processInfo.arguments.contains("--canvas-ui-reset") {
            UserDefaults.standard.removeObject(forKey: "canvas.settings.v1")
            UserDefaults.standard.removeObject(forKey: "canvas.settings.schema")
        }
        settingsStore = SettingsStore()
        if ProcessInfo.processInfo.arguments.contains("--canvas-ui-home") {
            settingsStore.settings.hasCompletedOnboarding = true
        }
        if ProcessInfo.processInfo.arguments.contains("--canvas-ui-minute-duration") {
            settingsStore.settings.hasCompletedOnboarding = true
            settingsStore.settings.photoDuration = 60
            settingsStore.settings.selectedAlbums = [AlbumReference(id: "ui-test-album", title: "Family favorites", subtype: 0, estimatedCount: 12, isSmart: false, isShared: false)]
        }
        if ProcessInfo.processInfo.arguments.contains("--canvas-ui-onboarding-album") {
            settingsStore.settings.selectedAlbums = [AlbumReference(id: "ui-test-album", title: "Family favorites", subtype: 0, estimatedCount: 12, isSmart: false, isShared: false)]
        }
        if ProcessInfo.processInfo.arguments.contains("--canvas-ui-weather-preview") || ProcessInfo.processInfo.arguments.contains("--canvas-ui-weather-frame") {
            settingsStore.settings.hasCompletedOnboarding = true
            settingsStore.settings.overlays.showTime = true
            settingsStore.settings.overlays.showWeather = true
            settingsStore.settings.overlays.position = .bottomLeading
            settingsStore.settings.overlays.clockSize = 78
            settingsStore.settings.overlays.clockFont = .rounded
            settingsStore.settings.overlays.clockWeight = .medium
            settingsStore.settings.overlays.backgroundTransparency = 0.28
        }
        if ProcessInfo.processInfo.arguments.contains("--canvas-ui-weather-expanded") {
            settingsStore.settings.overlays.weatherShowFeelsLike = true
            settingsStore.settings.overlays.weatherShowHumidity = true
            settingsStore.settings.overlays.weatherShowWind = true
            settingsStore.settings.overlays.weatherShowUVIndex = true
            settingsStore.settings.overlays.weatherShowPrecipitationChance = true
            settingsStore.settings.overlays.weatherShowDailyHighLow = true
            settingsStore.settings.overlays.weatherShowSunriseSunset = true
            settingsStore.settings.overlays.weatherShowNextHour = true
        }
        library = PhotoLibraryService()
        googlePhotos = GooglePhotosService()
        // Repair selections left by an older build or by deleting a saved
        // Google album while its picker view was not observing the change.
        // Only source-tagged Google references are pruned; Apple references
        // remain independent and are refreshed by PhotoLibraryService.
        let validGoogleAlbumIDs = Set(googlePhotos.albums.map(\.id))
        let cleanedGoogleSelection = AlbumSelectionCleanup.removingMissingGoogleAlbums(
            from: settingsStore.settings.selectedAlbums,
            validIDs: validGoogleAlbumIDs
        )
        if cleanedGoogleSelection != settingsStore.settings.selectedAlbums {
            var repaired = settingsStore.settings
            repaired.selectedAlbums = cleanedGoogleSelection
            settingsStore.settings = repaired
        }
        queue = QueueService()
        loader = AssetImageLoader()
        audio = AudioService()
        power = PowerService()
        weather = CanvasWeatherService()
        settingsSubscription = settingsStore.objectWillChange.sink { [weak self] _ in
            // @Published announces before assigning. Forward on the next main-actor turn so
            // views reading AppStore.settings observe the new value, not the previous one.
            Task { @MainActor [weak self] in self?.objectWillChange.send() }
        }
        librarySubscription = library.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.objectWillChange.send() }
        }
        googlePhotosSubscription = googlePhotos.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.objectWillChange.send() }
        }
        weatherSubscription = weather.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.objectWillChange.send() }
        }
    }

    @discardableResult
    func deleteGoogleAlbum(_ id: String) -> Bool {
        let current = settingsStore.settings.selectedAlbums
        let cleaned = AlbumSelectionCleanup.removingGoogleAlbum(id, from: current)
        if cleaned != current {
            var updated = settingsStore.settings
            updated.selectedAlbums = cleaned
            settingsStore.settings = updated
        }
        guard googlePhotos.deleteAlbum(id) else {
            if cleaned != current {
                var restored = settingsStore.settings
                restored.selectedAlbums = current
                settingsStore.settings = restored
            }
            return false
        }
        // Both the nested service and SettingsStore publish their changes, but
        // send one final app-level update so Home and an open picker converge
        // immediately on the same remaining selections.
        objectWillChange.send()
        return true
    }
}
