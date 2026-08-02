import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showAlbumPicker = false
    @State private var newPresetName = ""
    @State private var showPresetPrompt = false
    @State private var showAudioImporter = false

    var body: some View {
        NavigationStack {
            List {
                settingsLink("Albums & Filters", icon: "photo.on.rectangle", summary: "\(store.settings.selectedAlbums.count) selected") { Form { albumsFiltersSection } }
                settingsLink("Playback & Timing", icon: "play.circle", summary: store.settings.photoDuration.cleanSeconds) { Form { playbackSection; timingSection } }
                settingsLink("Transitions & Layout", icon: "rectangle.3.group", summary: store.settings.layout.title) { Form { transitionSection; layoutSection } }
                settingsLink("Clock & Overlays", icon: "clock", summary: store.settings.overlays.showTime ? "Clock shown" : "Clock hidden") { clockOverlaysPage }
                settingsLink("Schedule & Power", icon: "bolt", summary: store.settings.keepAwake ? "Keep awake" : "System managed") { Form { scheduleSection; powerSection } }
                settingsLink("Audio", icon: "speaker.wave.2", summary: store.settings.videoMuted ? "All playback muted" : "Playback audio on") { Form { audioSection } }
                settingsLink("Accessibility & Privacy", icon: "hand.raised", summary: store.settings.appearanceMode.title) { Form { accessibilitySection; privacySection } }
                settingsLink("Presets", icon: "slider.horizontal.2.square", summary: "\(store.settings.presets.count) saved") { Form { presetsSection } }
            }
            .navigationTitle("Canvas settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fontWeight(.semibold) } }
            .sheet(isPresented: $showAlbumPicker) { AlbumPickerView(isOnboarding: false) }
            .alert("Save preset", isPresented: $showPresetPrompt) {
                TextField("Preset name", text: $newPresetName)
                Button("Save") { savePreset() }
                Button("Cancel", role: .cancel) { }
            }
            .fileImporter(isPresented: $showAudioImporter, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                importAudio(result)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, store.settings.overlays.showWeather {
                    store.weather.refreshAuthorization()
                }
            }
        }
    }

    private func settingsLink<Destination: View>(_ title: String, icon: String, summary: String, @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink(destination: destination().navigationTitle(title).navigationBarTitleDisplayMode(.inline)) {
            Label {
                VStack(alignment: .leading, spacing: 3) { Text(title); Text(summary).font(.caption).foregroundStyle(.secondary) }
            } icon: { Image(systemName: icon).foregroundStyle(.orange) }
        }
    }

    /// Keeps the live composition visible while the controls below it scroll.
    /// The preview is intentionally outside the Form so it cannot scroll away
    /// during a long overlay-settings edit session.
    private var clockOverlaysPage: some View {
        VStack(spacing: 0) {
            ClockOverlayPreview()
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(.regularMaterial)
                .zIndex(1)
            Divider()
            Form { overlaysSection }
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var albumsFiltersSection: some View {
        Section("Albums & Filters") {
            Button { showAlbumPicker = true } label: { Label("Selected albums", systemImage: "rectangle.stack") ; Spacer(); Text("\(store.settings.selectedAlbums.count)").foregroundStyle(.secondary) }
            Toggle("Include still photos", isOn: filterBinding(\.includePhotos))
            Toggle("Favorites only", isOn: binding(\.filters.favoritesOnly))
            Toggle("Include videos", isOn: binding(\.filters.includeVideos))
            Toggle("Include Live Photos", isOn: binding(\.filters.includeLivePhotos))
            Toggle("Include hidden items", isOn: binding(\.filters.includeHidden))
            Toggle("Include screenshots", isOn: filterBinding(\.includeScreenshots))
            Toggle("Include burst sequences", isOn: filterBinding(\.includeBursts))
            Toggle("Location-tagged only", isOn: filterBinding(\.locationTaggedOnly))
            if store.settings.filters.startDate != nil || store.settings.filters.endDate != nil {
                DatePicker("From", selection: optionalDateBinding(\.startDate, fallback: Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()), displayedComponents: .date)
                DatePicker("Through", selection: optionalDateBinding(\.endDate, fallback: Date()), displayedComponents: .date)
                Button("Clear date range", role: .destructive) { store.settingsStore.settings.filters.startDate = nil; store.settingsStore.settings.filters.endDate = nil }
            } else {
                Button { store.settingsStore.settings.filters.startDate = Calendar.current.date(byAdding: .year, value: -1, to: Date()); store.settingsStore.settings.filters.endDate = Date() } label: { Label("Add date range", systemImage: "calendar") }
            }
            Text("Canvas includes newly captured screenshots automatically when their selected Apple Photos album contains them. It also deduplicates provider IDs, downloaded hashes, and conservative capture metadata across Apple and Google Photos.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var playbackSection: some View {
        Section("Playback") {
            Picker("Queue", selection: binding(\.queueMode)) { ForEach(QueueMode.allCases) { Text($0.title).tag($0) } }
            Toggle("Repeat", isOn: binding(\.repeatEnabled))
            Toggle("Reshuffle each loop", isOn: binding(\.shuffleEachLoop))
            Stepper("Avoid last \(store.settings.recentAvoidance) items", value: binding(\.recentAvoidance), in: 0...20)
        }
    }

    private var timingSection: some View {
        Section("Timing") {
            DurationSlider(title: "Photo duration", value: binding(\.photoDuration), range: 1...3600)
            DurationSlider(title: "Live Photo duration", value: binding(\.livePhotoDuration), range: 1...3600)
            DurationSlider(title: "Video maximum", value: binding(\.videoDuration), range: 1...3600, allowsUnlimited: true)
            Toggle("Play full videos", isOn: binding(\.playFullVideo))
            Toggle("Loop Live Photos", isOn: binding(\.loopLivePhotos))
            Toggle("Mute all playback audio", isOn: binding(\.videoMuted))
            if !store.settings.videoMuted {
                InlineSliderRow(
                    title: "Media volume",
                    value: binding(\.videoVolume),
                    range: 0...1,
                    step: 0.01,
                    valueText: { "\(Int(($0 * 100).rounded()))%" }
                )
            }
        }
    }
    private var transitionSection: some View {
        Section("Transitions") {
            Picker("Style", selection: binding(\.transition)) { ForEach(TransitionStyle.allCases) { Text($0.title).tag($0) } }
            InlineSliderRow(
                title: "Transition duration",
                value: binding(\.transitionDuration),
                range: 0...5,
                step: 0.1,
                valueText: { String(format: "%.1f sec", $0) }
            )
            Toggle("Random style", isOn: binding(\.randomTransitions))
        }
    }
    private var layoutSection: some View {
        Section("Layout") {
            Picker("Layout", selection: binding(\.layout)) { ForEach(LayoutStyle.allCases) { Text($0.title).tag($0) } }
            Picker("Image framing", selection: Binding(
                get: { store.settings.effectiveFramingMode },
                set: { value in store.settingsStore.update { $0.framingMode = value } }
            )) {
                ForEach(MediaFramingMode.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityHint("Fit with border preserves the entire original image; Fill / zoom may crop to fill the tile.")
            Toggle("Blurred background", isOn: binding(\.blurBackground))
            InlineSliderRow(
                title: "Spacing",
                value: binding(\.spacing),
                range: 0...40,
                valueText: { "\(Int($0.rounded())) pt" }
            )
            InlineSliderRow(
                title: "Corners",
                value: binding(\.cornerRadius),
                range: 0...48,
                valueText: { "\(Int($0.rounded())) pt" }
            )
        }
    }
    private var overlaysSection: some View {
        Section("Overlays") {
            Toggle("Time", isOn: binding(\.overlays.showTime)); Toggle("Date", isOn: binding(\.overlays.showDate)); Toggle("Weekday", isOn: binding(\.overlays.showWeekday))
            Toggle("Capture date", isOn: binding(\.overlays.showCaptureDate)); Toggle("Album", isOn: binding(\.overlays.showAlbum)); Toggle("Item count", isOn: binding(\.overlays.showItemCount)); Toggle("Battery", isOn: binding(\.overlays.showBattery))
            Toggle("Location", isOn: binding(\.overlays.showLocation)); Toggle("Filename caption", isOn: binding(\.overlays.showCaption))
            Picker("Capture date badge", selection: optionalOverlayBinding(\.captureDateStyle, default: .darkBadgeLightText)) {
                ForEach(CaptureDateBadgeStyle.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityHint("Use one consistent badge and text treatment for every capture date.")
            Picker("Position", selection: binding(\.overlays.position)) { ForEach(OverlayPosition.allCases) { Text($0.rawValue.capitalized).tag($0) } }
            InlineSliderRow(
                title: "Overlay opacity (background)",
                value: binding(\.overlays.opacity),
                range: 0...1,
                step: 0.01,
                valueText: { "\(Int(($0 * 100).rounded()))%" }
            )
            InlineSliderRow(
                title: "Glass effect",
                value: optionalOverlayBinding(\.backgroundTransparency, default: OverlayBackgroundPolicy.defaultTransparency),
                range: 0...1,
                step: 0.01,
                valueText: { "\(Int(($0 * 100).rounded()))%" }
            )
            InlineSliderRow(
                title: "Text size",
                value: binding(\.overlays.fontSize),
                range: 12...48,
                valueText: { "\(Int($0.rounded())) pt" }
            )
            Picker("Clock weight", selection: optionalOverlayBinding(\.clockWeight, default: .semibold)) { ForEach(ClockWeight.allCases) { Text($0.title).tag($0) } }
            Picker("Clock width", selection: optionalOverlayBinding(\.clockWidth, default: .standard)) { ForEach(ClockWidth.allCases) { Text($0.title).tag($0) } }
            Picker("Clock style", selection: optionalOverlayBinding(\.clockStyle, default: .digital)) {
                ForEach(ClockStyle.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityHint("Choose a digital or analog clock face")
            if (store.settings.overlays.clockStyle ?? .digital) == .analog {
                Picker("Analog clock face", selection: optionalOverlayBinding(\.analogClockFace, default: .arabic)) {
                    ForEach(AnalogClockFace.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityHint("Choose Arabic numerals, Roman numerals, or dash markers")
            }
            InlineSliderRow(
                title: "Clock size",
                value: optionalOverlayBinding(\.clockSize, default: 72),
                range: 28...180,
                valueText: { "\(Int($0.rounded())) pt" }
            )
            InlineSliderRow(
                title: "Clock opacity",
                value: optionalOverlayBinding(\.clockOpacity, default: 0.95),
                range: 0.2...1,
                step: 0.01,
                valueText: { "\(Int(($0 * 100).rounded()))%" }
            )
            Picker("Clock font", selection: optionalOverlayBinding(\.clockFont, default: .system)) {
                ForEach(ClockFont.allCases) { Text($0.title).tag($0) }
            }
            Picker("Clock color", selection: optionalOverlayBinding(\.clockColor, default: .white)) {
                ForEach(ClockColor.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Always visible", isOn: binding(\.overlays.alwaysVisible))
            Toggle("Current weather (opt-in)", isOn: binding(\.overlays.showWeather))
            if store.settings.overlays.showWeather {
                weatherStatusRow
            }
        }
    }

    private var weatherStatusRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(store.weather.status.title, systemImage: store.weather.status.systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(store.weather.status == .live ? .green : .secondary)
                .accessibilityLabel("Weather status: \(store.weather.status.title)")
            Text(store.weather.status.message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let snapshot = store.weather.snapshot {
                Label(snapshot.displayText, systemImage: store.weather.isUsingCachedSnapshot || snapshot.isStale ? "clock.arrow.circlepath" : "location.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(snapshot.attributionText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if store.weather.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading current weather")
            }
            switch store.weather.status {
            case .needsLocationPermission:
                Button("Allow Location") { store.weather.update(showWeather: true) }
                    .buttonStyle(.bordered)
            case .locationDenied, .locationRestricted:
                Button("Open Location Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .buttonStyle(.bordered)
            case .networkUnavailable, .serviceUnavailable, .entitlementMissing, .locationUnavailable:
                Button("Retry weather") { store.weather.update(showWeather: true) }
                    .buttonStyle(.bordered)
            case .disabled, .requestingLocation, .locating, .fetching, .live:
                EmptyView()
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
    private var scheduleSection: some View {
        Section("Schedule") {
            Label("Schedules are local and evaluated while Canvas is active.", systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
            NavigationLink("Manage schedules") { ScheduleView() }
        }
    }
    private var powerSection: some View {
        Section("Power & Display") {
            Toggle("Keep awake while playing", isOn: binding(\.keepAwake))
            Toggle("Charging-only operation", isOn: binding(\.chargingOnly))
            Stepper("Stop below \(store.settings.lowBatteryStop)%", value: binding(\.lowBatteryStop), in: 0...50)
            InlineSliderRow(
                title: "Hide controls after",
                value: binding(\.controlAutoHide),
                range: 1...30,
                valueText: { $0.cleanSeconds }
            )
        }
    }
    private var audioSection: some View {
        Section("Audio") {
            Picker("Background audio", selection: binding(\.backgroundAudio)) { ForEach(BackgroundAudioMode.allCases) { Text($0.title).tag($0) } }
            if store.settings.backgroundAudio == .localFiles {
                Button { showAudioImporter = true } label: { Label("Add local audio", systemImage: "plus.circle") }
                Text("\(store.settings.audioFileURLs.count) file\(store.settings.audioFileURLs.count == 1 ? "" : "s") added").font(.footnote).foregroundStyle(.secondary)
                InlineSliderRow(
                    title: "Audio volume",
                    value: binding(\.audioVolume),
                    range: 0...1,
                    step: 0.01,
                    valueText: { "\(Int(($0 * 100).rounded()))%" }
                )
                Toggle("Shuffle", isOn: binding(\.audioShuffle))
                Toggle("Repeat", isOn: binding(\.audioRepeat))
            }
            Text("Apple Music playback is not enabled because iPadOS media-library access and subscription policy require a separate user-authorized integration. Local audio works without a subscription.").font(.footnote).foregroundStyle(.secondary)
        }
    }
    private var accessibilitySection: some View {
        Section("Accessibility") {
            Toggle("Lock controls in slideshow", isOn: binding(\.lockControls))
            Picker("Appearance", selection: binding(\.appearanceMode)) { ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) } }
            Text("Canvas follows Dynamic Type, VoiceOver labels, Reduce Motion, pointer, keyboard, and iPad multitasking conventions.").font(.footnote).foregroundStyle(.secondary)
        }
    }
    private var presetsSection: some View {
        Section("Presets") {
            if store.settings.presets.isEmpty { Text("Save complete setups for different rooms or seasons.").font(.footnote).foregroundStyle(.secondary) }
            ForEach(store.settings.presets) { preset in
                HStack {
                    Text(preset.name)
                    Spacer()
                    Button {
                        store.settingsStore.settings = PresetApplication.settings(for: preset, preserving: store.settings.presets)
                    } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Apply \(preset.name)")
                    Button(role: .destructive) { store.settingsStore.settings.presets.removeAll { $0.id == preset.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
            }
            Button { newPresetName = ""; showPresetPrompt = true } label: { Label("Save current setup", systemImage: "plus") }
        }
    }
    private var privacySection: some View { Section("Storage & Privacy") { Label("Private by default", systemImage: "lock.shield.fill"); Text("Canvas stores preferences and exclusions locally. Apple photos remain in Apple Photos. Google Photos access is opt-in; selected files are downloaded to this device for reliable playback and OAuth tokens stay in Keychain. Canvas has no uploads, analytics, ads, or tracking.").font(.footnote).foregroundStyle(.secondary) } }

    private func savePreset() { guard !newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }; var snapshot = store.settings; snapshot.presets = []; store.settingsStore.settings.presets.append(CanvasPreset(name: newPresetName, settings: snapshot)) }
    private func importAudio(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Canvas Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var copied = store.settings.audioFileURLs
        for url in urls where url.startAccessingSecurityScopedResource() {
            defer { url.stopAccessingSecurityScopedResource() }
            let destination = directory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            if (try? FileManager.default.copyItem(at: url, to: destination)) != nil { copied.append(destination) }
        }
        store.settingsStore.settings.audioFileURLs = Array(Set(copied))
    }
    private func binding<T>(_ keyPath: WritableKeyPath<CanvasSettings, T>) -> Binding<T> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { value in
                store.settingsStore.update { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func filterBinding<T>(_ keyPath: WritableKeyPath<CanvasFilters, T>) -> Binding<T> {
        Binding(
            get: { store.settings.filters[keyPath: keyPath] },
            set: { value in
                store.settingsStore.update { $0.filters[keyPath: keyPath] = value }
            }
        )
    }

    private func optionalDateBinding(_ keyPath: WritableKeyPath<CanvasFilters, Date?>, fallback: Date) -> Binding<Date> {
        Binding(
            get: { store.settings.filters[keyPath: keyPath] ?? fallback },
            set: { value in
                store.settingsStore.update { $0.filters[keyPath: keyPath] = value }
            }
        )
    }

    private func optionalOverlayBinding<T>(_ keyPath: WritableKeyPath<OverlaySettings, T?>, default defaultValue: T) -> Binding<T> {
        Binding(
            get: { store.settings.overlays[keyPath: keyPath] ?? defaultValue },
            set: { value in
                store.settingsStore.update { $0.overlays[keyPath: keyPath] = value }
            }
        )
    }
}

/// Shows the same overlay controls over a representative selected Canvas
/// image. It observes AppStore settings directly, so slider drags, toggles,
/// pickers, and weather/cache updates are visible before leaving Settings.
private struct ClockOverlayPreview: View {
    @EnvironmentObject private var store: AppStore
    @State private var previewImages: [UIImage] = []
    @State private var previewItems: [CanvasMediaItem] = []
    @State private var isLandscape = UIScreen.main.bounds.width > UIScreen.main.bounds.height

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Live preview", systemImage: "eye")
                .font(.subheadline.weight(.semibold))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                GeometryReader { proxy in
                    let canvasSize = OverlayPreviewGeometry.normalizedCanvasSize(
                        screenSize: UIScreen.main.bounds.size,
                        isLandscape: isLandscape
                    )
                    let scale = OverlayPreviewGeometry.scale(containerSize: proxy.size, canvasSize: canvasSize)
                    ZStack {
                        ZStack {
                            if !previewImages.isEmpty {
                                LayoutCanvas(
                                    images: previewImages,
                                    style: .automatic,
                                    fit: store.settings.effectiveFramingMode.preservesEntireImage,
                                    background: MediaBackdropView.neutralFallback,
                                    blurredBackground: store.settings.blurBackground,
                                    spacing: CGFloat(store.settings.spacing),
                                    cornerRadius: 18,
                                    captureDates: previewItems.map(\.creationDate),
                                    showCaptureDates: store.settings.overlays.showCaptureDate,
                                    captureDateStyle: store.settings.overlays.captureDateStyle ?? .darkBadgeLightText,
                                    framingMode: store.settings.effectiveFramingMode,
                                    clockSettings: store.settings.overlays,
                                    clockDate: context.date
                                )
                            } else {
                                MediaBackdropView(images: [], mode: .neutral, fallback: MediaBackdropView.neutralFallback)
                                VStack(spacing: 8) {
                                    Image(systemName: "photo.on.rectangle")
                                        .font(.title2)
                                    Text("Choose an album to preview its media")
                                        .font(.caption)
                                }
                                .foregroundStyle(.white.opacity(0.75))
                            }
                            previewOverlay(date: context.date, size: canvasSize)
                        }
                        .frame(width: canvasSize.width, height: canvasSize.height)
                        .scaleEffect(scale)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .clipped()
                }
                .frame(height: 230)
            }
            Text("Preview only — changes apply to the next frame immediately and are saved with your settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live clock and overlay preview")
        .task(id: previewKey) { await loadPreviewImage() }
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            updateOrientation()
        }
        .onDisappear { UIDevice.current.endGeneratingDeviceOrientationNotifications() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            updateOrientation()
        }
        .onChange(of: store.settings.overlays.showWeather) { _, enabled in
            store.weather.update(showWeather: enabled)
        }
    }

    private func updateOrientation() {
        let orientation = UIDevice.current.orientation
        if orientation == .landscapeLeft || orientation == .landscapeRight {
            isLandscape = true
        } else if orientation == .portrait || orientation == .portraitUpsideDown {
            isLandscape = false
        } else {
            isLandscape = UIScreen.main.bounds.width > UIScreen.main.bounds.height
        }
    }

    private var previewKey: String {
        let albums = store.settings.selectedAlbums.map(\.id).joined(separator: "|")
        let google = store.googlePhotos.albums.map { "\($0.id):\($0.updatedAt.timeIntervalSince1970)" }.joined(separator: "|")
        return "\(albums)#\(store.library.libraryRevision)#\(google)"
    }

    @MainActor
    private func loadPreviewImage() async {
        previewImages = []
        previewItems = []
        let apple = store.library.mediaItems(for: store.settings.selectedAlbums, filters: store.settings.filters)
        let google = store.googlePhotos.items(for: store.settings.selectedAlbums, filters: store.settings.filters)
        let items = MediaIdentityMatcher.deduplicated(apple + google)
        let candidates = HomePreviewSelection.representativeItems(from: items, limit: 2, seed: 0, albumID: "clock-preview")
        for item in candidates {
            guard !Task.isCancelled else { return }
            if let image = await store.loader.image(for: item, service: store.library, size: CGSize(width: 1400, height: 1000)) {
                previewItems.append(item)
                previewImages.append(image)
            }
        }
    }

    @ViewBuilder
    private func previewOverlay(date: Date, size: CGSize) -> some View {
        let settings = store.settings.overlays
        let opacity = OverlayOpacityPolicy.values(backgroundOpacity: settings.opacity, clockOpacity: settings.clockOpacity)
        let adaptiveClockPerTile = settings.showTime && settings.clockColor == .adaptive && !previewImages.isEmpty
        let showStandardOverlay = (settings.showTime && !adaptiveClockPerTile) || settings.showDate || settings.showWeekday || settings.showAlbum || settings.showLocation || settings.showCaption || settings.showItemCount || settings.showBattery || settings.showWeather
        if showStandardOverlay {
            VStack(alignment: .leading, spacing: 3) {
                if settings.showTime {
                    ClockOverlayView(date: date, settings: settings, mediaImage: previewImages.first)
                }
                if settings.showDate { Text(date, format: .dateTime.month(.wide).day().year()).font(.system(size: settings.fontSize * 0.64, design: .rounded)) }
                if settings.showWeekday { Text(date, format: .dateTime.weekday(.wide)).font(.system(size: settings.fontSize * 0.62)) }
                if settings.showAlbum { Text("Selected album").font(.system(size: settings.fontSize * 0.62)) }
                if settings.showItemCount { Text("1 / 12").font(.system(size: settings.fontSize * 0.62, design: .monospaced)) }
                if settings.showBattery { Label("91%", systemImage: "battery.75percent").font(.system(size: settings.fontSize * 0.54)) }
                if settings.showWeather {
                    if let weather = store.weather.snapshot {
                        HStack(spacing: 5) {
                            Image(systemName: weather.symbolName)
                            Text(weather.displayText)
                            Text(weather.attributionText)
                        }
                        .font(.system(size: settings.fontSize * 0.54))
                    }
                    if store.weather.status != .live {
                        Label(store.weather.status.title, systemImage: store.weather.status.systemImage)
                            .font(.system(size: settings.fontSize * 0.48))
                            .lineLimit(2)
                    }
                }
            }
            .foregroundStyle(.white.opacity(opacity.text))
            .padding(14)
            .background {
                OverlayMaterial.ultraThin.backgroundView(
                    cornerRadius: 14,
                    opacity: opacity.background,
                    transparency: settings.backgroundTransparency ?? OverlayBackgroundPolicy.defaultTransparency
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(for: settings.position))
            // Match PlayerView.overlay(in:) exactly; the whole simulated
            // canvas is then uniformly scaled into this preview card.
            .padding(24)
        } else if settings.showCaptureDate {
            if previewImages.isEmpty {
                Text("Choose media to preview capture dates")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(for: settings.position))
                    .padding(24)
            } else {
                Color.clear
            }
        } else {
            Text("Enable an overlay to preview it here")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func alignment(for position: OverlayPosition) -> Alignment {
        switch position {
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        case .center: .center
        }
    }
}

/// Keeps a slider, its descriptive label, and its live formatted value in one
/// row. The value remains visible while dragging, while the slider itself keeps
/// the control's semantic label/value for VoiceOver and UI automation.
struct InlineSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueText: (Double) -> String

    init(title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double = 1, valueText: @escaping (Double) -> String) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.valueText = valueText
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                Slider(value: $value, in: range, step: step)
                    .accessibilityLabel(title)
                    .accessibilityValue(valueText(value))
                    .accessibilityIdentifier("\(title)-slider")
                Text(valueText(value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 56, alignment: .trailing)
                    .accessibilityIdentifier("\(title)-value")
            }
        } label: {
            Text(title)
        }
    }
}

struct DurationSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let allowsUnlimited: Bool
    @State private var liveValue: Double
    @State private var typedValue: String

    init(title: String, value: Binding<Double>, range: ClosedRange<Double>, allowsUnlimited: Bool = false) {
        self.title = title
        _value = value
        self.range = range
        self.allowsUnlimited = allowsUnlimited
        _liveValue = State(initialValue: value.wrappedValue)
        _typedValue = State(initialValue: value.wrappedValue <= 0 ? "" : String(Int(value.wrappedValue)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title); Spacer()
                Menu {
                    if allowsUnlimited { Button("Unlimited") { setValue(0) } }
                    ForEach([1.0, 5, 10, 30, 60, 300, 900, 1800, 3600], id: \.self) { seconds in
                        Button(seconds.cleanSeconds) { setValue(seconds) }
                    }
                } label: {
                    Text(displayText)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("\(title)-value")
                }
            }
            HStack {
                Slider(value: Binding(get: { max(range.lowerBound, liveValue) }, set: { setValue($0) }), in: range, step: 1)
                .accessibilityLabel(title)
                .accessibilityValue(displayText)
                .accessibilityIdentifier("\(title)-slider")
                TextField("Seconds", text: $typedValue)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 78)
                    .accessibilityLabel("\(title) seconds")
                    .onChange(of: typedValue) { _, text in
                        guard let number = Double(text), range.contains(number) else { return }
                        liveValue = number; value = number
                    }
            }
        }
        .onAppear { syncFromBinding(value) }
        .onChange(of: value) { _, newValue in syncFromBinding(newValue) }
    }

    private var displayText: String { allowsUnlimited && liveValue <= 0 ? "Unlimited" : liveValue.cleanSeconds }

    private func syncFromBinding(_ newValue: Double) {
        liveValue = newValue
        typedValue = newValue <= 0 ? "" : String(Int(newValue))
    }

    private func setValue(_ newValue: Double) {
        liveValue = newValue
        value = newValue
        typedValue = newValue <= 0 ? "" : String(Int(newValue))
    }
}

struct ScheduleView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        List {
            Section { Text("iPadOS may pause apps in the background and cannot guarantee wake or unlock. Canvas applies schedules while running and shows the next event here.").font(.footnote).foregroundStyle(.secondary) }
            ForEach(Array(store.settings.schedules.enumerated()), id: \.element.id) { index, rule in
                NavigationLink { ScheduleEditor(rule: Binding(get: { store.settings.schedules[index] }, set: { store.settingsStore.settings.schedules[index] = $0 })) } label: {
                    VStack(alignment: .leading) { Text(rule.name).font(.headline); Text("\(rule.startMinutes / 60):\(String(format: "%02d", rule.startMinutes % 60)) to \(rule.stopMinutes / 60):\(String(format: "%02d", rule.stopMinutes % 60))").font(.caption).foregroundStyle(.secondary) }
                }
            }.onDelete { offsets in store.settingsStore.settings.schedules.remove(atOffsets: offsets) }
            Button { store.settingsStore.settings.schedules.append(ScheduleRule()) } label: { Label("Add schedule", systemImage: "plus") }
        }.navigationTitle("Schedules").toolbar { EditButton() }
    }
}

struct ScheduleEditor: View {
    @Binding var rule: ScheduleRule
    var body: some View {
        Form {
            TextField("Name", text: $rule.name)
            DatePicker("Start", selection: minutesBinding($rule.startMinutes), displayedComponents: .hourAndMinute)
            DatePicker("Stop", selection: minutesBinding($rule.stopMinutes), displayedComponents: .hourAndMinute)
            Toggle("Dim at night", isOn: $rule.dimsAtNight)
            Toggle("Black sleep screen", isOn: $rule.blackSleepScreen)
            Section("Weekdays") {
                ForEach(1...7, id: \.self) { day in Toggle(Calendar.current.weekdaySymbols[day - 1], isOn: Binding(get: { rule.weekdays.contains(day) }, set: { enabled in if enabled { rule.weekdays.insert(day) } else { rule.weekdays.remove(day) } })) }
            }
        }.navigationTitle("Edit schedule")
    }
    private func minutesBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(get: { Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: Date()) ?? Date() }, set: { value in let components = Calendar.current.dateComponents([.hour, .minute], from: value); minutes.wrappedValue = (components.hour ?? 0) * 60 + (components.minute ?? 0) })
    }
}
