import SwiftUI
import Photos
import AVKit

struct PlayerView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var model = PlaybackViewModel()
    @StateObject private var scheduleMonitor = ScheduleMonitor()
    @State private var controlsVisible = true
    @State private var zoom: CGFloat = 1
    @State private var dragOffset: CGSize = .zero
    @State private var hideTask: Task<Void, Never>?
    @State private var isLocked = false
    @State private var showDetails = false
    @State private var lastSwipeTime = Date.distantPast
    @State private var swipeDirection = 0
    @State private var swipeResetToken = UUID()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if !powerAllowsPlayback {
                VStack(spacing: 14) { Image(systemName: "bolt.fill").font(.largeTitle); Text("Canvas is waiting for power") .font(.headline); Text("Charging-only mode or the low-battery limit is enabled in Power & Display.").font(.subheadline).foregroundStyle(.white.opacity(0.65)) }.foregroundStyle(.white.opacity(0.85)).padding(28).multilineTextAlignment(.center)
            } else if !store.settings.schedules.isEmpty && !scheduleMonitor.isPlaybackAllowed {
                if store.settings.schedules.contains(where: \.blackSleepScreen) {
                    Color.black.ignoresSafeArea()
                } else {
                    VStack(spacing: 14) { Image(systemName: "moon.stars.fill").font(.largeTitle); Text("Canvas is resting until the next schedule").font(.headline); Text("You can close this frame or adjust Schedules in Settings.").font(.subheadline).foregroundStyle(.white.opacity(0.65)) }.foregroundStyle(.white.opacity(0.85)).padding(28).multilineTextAlignment(.center)
                }
            } else { media.opacity(scheduleMonitor.activeRule?.dimsAtNight == true ? 0.55 : 1) }
            if controlsVisible && !isLocked { controls }
            if isLocked { lockBadge }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .task {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            isLocked = store.settings.lockControls
            scheduleMonitor.start(rules: store.settings.schedules)
            model.setPlaybackAllowed(playbackGateAllows)
            model.configure(library: store.library, googlePhotos: store.googlePhotos, loader: store.loader, settings: store.settings)
            store.audio.configure(store.settings)
            if store.settings.backgroundAudio == .localFiles, !store.settings.videoMuted { store.audio.start() }
            updateWeather()
            scheduleHide()
        }
        .onDisappear {
            hideTask?.cancel()
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            store.power.endPlayback(); store.audio.stop(); store.weather.clear()
        }
        .onAppear { store.power.refresh(); if powerAllowsPlayback { store.power.beginPlayback(keepAwake: store.settings.keepAwake) }; scheduleHide() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in store.power.refresh(); updatePowerState() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in store.power.refresh(); updatePowerState() }
        .onChange(of: store.library.libraryRevision) { _, _ in Task { await model.reload() } }
        .onChange(of: model.currentAsset?.id) { _, _ in scheduleSwipeReset(); scheduleHide() }
        .onChange(of: model.isPlaying) { _, _ in scheduleHide() }
        .onChange(of: store.settings.overlays.showWeather) { _, _ in updateWeather() }
        .onChange(of: store.settings) { _, updated in
            Task {
                await model.updateSettings(updated)
                if model.queueCount == 0 { dismiss() }
            }
            store.audio.update(updated)
            isLocked = updated.lockControls
            scheduleHide()
        }
        .onChange(of: store.googlePhotos.albums) { _, _ in
            Task {
                await model.reload(settings: store.settings)
                if model.queueCount == 0 { dismiss() }
            }
        }
        .onChange(of: powerAllowsPlayback) { _, _ in updatePowerState() }
        .onChange(of: store.settings.schedules) { _, rules in scheduleMonitor.start(rules: rules) }
        .onChange(of: store.settings.keepAwake) { _, _ in updatePowerState() }
        .onChange(of: playbackGateAllows) { _, allowed in
            model.setPlaybackAllowed(allowed)
            if allowed { scheduleHide() }
            else { hideTask?.cancel(); controlsVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in scheduleHide() }
        .simultaneousGesture(tapGesture)
        .simultaneousGesture(swipeGesture)
        .simultaneousGesture(magnifyGesture)
        .onLongPressGesture(minimumDuration: 0.55) { if isLocked { isLocked = false } else { showDetails = true } }
        .sheet(isPresented: $showDetails) { detailsSheet }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Canvas slideshow")
    }

    private var media: some View {
        GeometryReader { proxy in
            ZStack {
                if let item = model.currentAsset, item.kind == .video, let asset = item.appleAsset {
                    ZStack {
                        playbackBackdrop
                        VideoAssetView(asset: asset, isPlaying: model.isPlaying, muted: store.settings.videoMuted, volume: store.settings.videoVolume, framingMode: store.settings.effectiveFramingMode)
                        if store.settings.overlays.showCaptureDate, let image = model.currentImage {
                            CaptureDateOverlayLayer(
                                imageSizes: [image.size],
                                captureDates: [model.currentAsset?.creationDate],
                                style: .single,
                                canvasSize: proxy.size,
                                spacing: 0,
                                badgeStyle: store.settings.overlays.captureDateStyle ?? .darkBadgeLightText
                            )
                        }
                    }
                    .id(item.id)
                    .transition(transition)
                } else if let item = model.currentAsset, item.kind == .video, let url = item.localURL {
                    ZStack {
                        playbackBackdrop
                        LocalVideoView(url: url, isPlaying: model.isPlaying, muted: store.settings.videoMuted, volume: store.settings.videoVolume, framingMode: store.settings.effectiveFramingMode)
                        if store.settings.overlays.showCaptureDate, let image = model.currentImage {
                            CaptureDateOverlayLayer(
                                imageSizes: [image.size],
                                captureDates: [model.currentAsset?.creationDate],
                                style: .single,
                                canvasSize: proxy.size,
                                spacing: 0,
                                badgeStyle: store.settings.overlays.captureDateStyle ?? .darkBadgeLightText
                            )
                        }
                    }
                    .id(item.id)
                    .transition(transition)
                } else if let item = model.currentAsset, item.kind == .livePhoto, let asset = item.appleAsset {
                    ZStack {
                        playbackBackdrop
                        LivePhotoAssetView(asset: asset, isPlaying: model.isPlaying, loop: store.settings.loopLivePhotos, muted: store.settings.videoMuted, framingMode: store.settings.effectiveFramingMode)
                        if store.settings.overlays.showCaptureDate, let image = model.currentImage {
                            CaptureDateOverlayLayer(
                                imageSizes: [image.size],
                                captureDates: [model.currentAsset?.creationDate],
                                style: .single,
                                canvasSize: proxy.size,
                                spacing: 0,
                                badgeStyle: store.settings.overlays.captureDateStyle ?? .darkBadgeLightText
                            )
                        }
                    }
                    .id(item.id)
                    .transition(transition)
                } else if !model.layoutImages.isEmpty {
                    ZStack {
                        LayoutCanvas(
                            images: model.layoutImages,
                            style: fullscreenLayout,
                            fit: store.settings.effectiveFramingMode.preservesEntireImage,
                            background: MediaBackdropView.neutralFallback,
                            blurredBackground: store.settings.blurBackground,
                            spacing: CGFloat(store.settings.spacing),
                            cornerRadius: CGFloat(store.settings.cornerRadius),
                            captureDates: model.layoutAssets.map(\.creationDate),
                            showCaptureDates: false,
                            captureDateStyle: store.settings.overlays.captureDateStyle ?? .darkBadgeLightText,
                            framingMode: store.settings.effectiveFramingMode,
                            clockSettings: store.settings.overlays,
                            clockDate: Date()
                        )
                        .scaleEffect(zoom)
                        .offset(dragOffset)
                        // Capture dates live in the final device/tile space,
                        // outside the pinch/drag transform applied to media.
                        if store.settings.overlays.showCaptureDate {
                            CaptureDateOverlayLayer(
                                imageSizes: model.layoutImages.map(\.size),
                                captureDates: model.layoutAssets.map(\.creationDate),
                                style: fullscreenLayout,
                                canvasSize: proxy.size,
                                spacing: CGFloat(store.settings.spacing),
                                badgeStyle: store.settings.overlays.captureDateStyle ?? .darkBadgeLightText
                            )
                        }
                    }
                    .id(model.currentAsset?.id ?? "photo-loading")
                    .transition(transition)
                } else if model.errorMessage != nil {
                    VStack(spacing: 12) { Image(systemName: "icloud.slash").font(.largeTitle); Text(model.errorMessage ?? "Unavailable").foregroundStyle(.white.opacity(0.8)) }.transition(.opacity)
                } else {
                    ProgressView().tint(.white)
                }
                overlay(in: proxy.size)
            }
            .background(Color.black)
            .animation(reduceMotion ? nil : .easeInOut(duration: store.settings.transitionDuration), value: model.currentAsset?.id)
            .onAppear { model.updateCanvasSize(proxy.size) }
            .onChange(of: proxy.size) { _, size in model.updateCanvasSize(size) }
        }
        // The media/backdrop surface owns the full display. Controls remain
        // in the parent safe-area layout, so a home-indicator inset cannot
        // leave a black strip below the photo while chrome stays reachable.
        .ignoresSafeArea()
    }

    /// Video and Live Photo surfaces are UIKit-backed and therefore cannot
    /// share LayoutCanvas's background layer. Give them the same contextual
    /// backdrop so fit gaps or a not-yet-ready surface never reveal a fixed
    /// blue placeholder.
    private var playbackBackdrop: some View {
        let images = model.layoutImages.isEmpty
            ? (model.currentImage.map { [$0] } ?? [])
            : model.layoutImages
        return MediaBackdropView(
            images: images,
            mode: MediaBackdropResolver.mode(imageCount: images.count, blurredBackground: store.settings.blurBackground),
            fallback: MediaBackdropView.neutralFallback
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fullscreenLayout: LayoutStyle {
        switch store.settings.layout {
        case .fitBlurred, .intelligentFill, .solidBackground: .single
        default: store.settings.layout
        }
    }

    private var transition: AnyTransition {
        switch SwipeTransitionState.from(direction: swipeDirection) {
        case .forward:
            // A left finger swipe moves the outgoing frame left and brings
            // the next displayed group in from the right.
            return .asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading))
        case .backward:
            return .asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .trailing))
        case .automatic:
            break
        }
        let style = TransitionEngine.choose(preferred: store.settings.transition, random: store.settings.randomTransitions, excluded: store.settings.excludedTransitions, reduceMotion: reduceMotion, seed: UInt64(model.currentIndex + 1))
        switch style {
        case .cut: return AnyTransition.identity
        case .slideLeft, .push: return AnyTransition.asymmetric(insertion: AnyTransition.move(edge: .trailing), removal: AnyTransition.move(edge: .leading))
        case .slideRight: return AnyTransition.asymmetric(insertion: AnyTransition.move(edge: .leading), removal: AnyTransition.move(edge: .trailing))
        case .slideUp: return AnyTransition.asymmetric(insertion: AnyTransition.move(edge: .bottom), removal: AnyTransition.move(edge: .top))
        case .slideDown: return AnyTransition.asymmetric(insertion: AnyTransition.move(edge: .top), removal: AnyTransition.move(edge: .bottom))
        case .zoomIn, .kenBurns: return AnyTransition.scale.combined(with: AnyTransition.opacity)
        case .zoomOut: return AnyTransition.scale(scale: 1.2).combined(with: AnyTransition.opacity)
        case .blurDissolve: return AnyTransition.opacity
        case .scaleFade, .pageSwipe, .crossfade: return AnyTransition.opacity
        }
    }

    private var controls: some View {
        VStack {
            HStack { Button { dismiss() } label: { Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44) }.buttonStyle(.plain).background(.ultraThinMaterial, in: Circle()); Spacer(); Text("Canvas").font(.headline); Spacer(); Button { isLocked = true } label: { Image(systemName: "lock.open").font(.headline).frame(width: 44, height: 44) }.buttonStyle(.plain).background(.ultraThinMaterial, in: Circle()) }
                .padding(.horizontal, 24).padding(.top, 18)
            Spacer()
            VStack(spacing: 14) {
                ProgressView(value: model.progress).tint(.white).padding(.horizontal, 24)
                HStack(spacing: 34) {
                    Button { model.previous(); scheduleHide() } label: { Image(systemName: "backward.fill").font(.title2) }
                    Button { model.togglePlaying(); scheduleHide() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.title).frame(width: 64, height: 64).background(.white, in: Circle()).foregroundStyle(.black) }
                    Button { model.next(); scheduleHide() } label: { Image(systemName: "forward.fill").font(.title2) }
                }.foregroundStyle(.white)
                HStack { Label("\(model.currentIndex + 1) of \(model.queueCount)", systemImage: "photo").font(.caption); Spacer(); if model.currentAsset?.isFavorite == true { Image(systemName: "heart.fill") } }
                    .foregroundStyle(.white.opacity(0.8)).padding(.horizontal, 24)
            }.padding(.bottom, 24).background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
        }.foregroundStyle(.white).transition(.opacity)
    }

    private func overlay(in size: CGSize) -> some View {
        let settings = store.settings.overlays
        let opacity = OverlayOpacityPolicy.values(backgroundOpacity: settings.opacity, clockOpacity: settings.clockOpacity)
        // Adaptive color is evaluated separately in each visible tile by
        // LayoutCanvas. Other media surfaces still use this shared overlay.
        let adaptiveClockPerTile = settings.showTime && settings.clockColor == .adaptive && !model.layoutImages.isEmpty
        let showStandardOverlay = (settings.showTime && !adaptiveClockPerTile) || settings.showDate || settings.showWeekday || settings.showAlbum || settings.showLocation || settings.showCaption || settings.showItemCount || settings.showBattery || settings.showWeather
        return ZStack {
            if showStandardOverlay {
                VStack(alignment: .leading, spacing: 3) {
                    if settings.showTime {
                        ClockOverlayView(date: Date(), settings: settings, mediaImage: model.currentImage)
                    }
                    if settings.showDate { Text(Date(), format: .dateTime.month(.wide).day().year()).font(.system(size: settings.fontSize * 0.64, design: .rounded)) }
                    if settings.showAlbum, let title = model.currentAsset?.albumTitle { Text(title).font(.system(size: settings.fontSize * 0.62)) }
                    if settings.showWeekday { Text(Date(), format: .dateTime.weekday(.wide)).font(.system(size: settings.fontSize * 0.62)) }
                    if settings.showLocation, let location = model.currentAsset?.appleAsset?.location { Text("\(location.coordinate.latitude, specifier: "%.3f"), \(location.coordinate.longitude, specifier: "%.3f")").font(.system(size: settings.fontSize * 0.54, design: .monospaced)) }
                    if settings.showCaption, let filename = model.currentAsset?.filename, !filename.isEmpty { Text(filename).font(.system(size: settings.fontSize * 0.62)).lineLimit(1) }
                    if settings.showItemCount { Text("\(model.currentIndex + 1) / \(model.queueCount)").font(.system(size: settings.fontSize * 0.62, design: .monospaced)) }
                    if settings.showBattery { Label("\(Int(UIDevice.current.batteryLevel * 100))%", systemImage: UIDevice.current.batteryState == .charging ? "bolt.fill" : "battery.75percent").font(.system(size: settings.fontSize * 0.54)) }
                    if settings.showWeather, let weather = store.weather.snapshot {
                        HStack(spacing: 5) {
                            Image(systemName: weather.symbolName)
                            Text(weather.displayText)
                            if store.weather.isUsingCachedSnapshot || weather.isStale {
                                Text("Last known")
                            }
                            if let url = store.weather.attributionURL {
                                Link(weather.attributionText, destination: url)
                            } else {
                                Text(weather.attributionText)
                            }
                        }
                        .font(.system(size: settings.fontSize * 0.54))
                    } else if settings.showWeather {
                        Label(store.weather.status.title, systemImage: store.weather.status.systemImage)
                            .font(.system(size: settings.fontSize * 0.54))
                    }
                }.foregroundStyle(.white.opacity(opacity.text)).padding(14).background {
                    // Keep one neutral backing style; continuous controls in
                    // Settings own its opacity/transparency.
                    OverlayMaterial.ultraThin.backgroundView(
                        cornerRadius: 14,
                        opacity: opacity.background,
                        transparency: settings.backgroundTransparency ?? OverlayBackgroundPolicy.defaultTransparency
                    )
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(for: settings.position)).padding(24)
            }
            if settings.showCaptureDate,
               (model.currentAsset?.kind == .video || model.currentAsset?.kind == .livePhoto || model.layoutImages.isEmpty),
               let date = model.currentAsset?.creationDate {
                CaptureDateBadge(date: date, image: model.currentImage)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
    }
    private func alignment(for position: OverlayPosition) -> Alignment { switch position { case .topLeading: .topLeading; case .topTrailing: .topTrailing; case .bottomLeading: .bottomLeading; case .bottomTrailing: .bottomTrailing; case .center: .center } }
    private func updateWeather() {
        let showWeather = store.settings.overlays.showWeather
        store.weather.update(showWeather: showWeather)
    }
    private var lockBadge: some View { VStack { Spacer(); Label("Controls locked", systemImage: "lock.fill").font(.caption).foregroundStyle(.white.opacity(0.7)).padding(10).background(.black.opacity(0.35), in: Capsule()).padding(.bottom, 24) } }
    private var tapGesture: some Gesture { TapGesture(count: 2).onEnded { if !isLocked, let asset = model.currentAsset?.appleAsset { Task { await store.library.toggleFavorite(asset) } } }
        .exclusively(before: TapGesture(count: 1).onEnded { if !isLocked { controlsVisible.toggle(); scheduleHide() } }) }
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 40).onEnded { value in
            guard !isLocked else { return }
            if let direction = SwipeNavigation.direction(for: value.translation) {
                // SwiftUI may deliver the same completed drag to overlapping
                // gesture recognizers during a transition. Treat a close pair
                // of callbacks as one physical swipe.
                let now = Date()
                guard now.timeIntervalSince(lastSwipeTime) > 0.18 else { return }
                lastSwipeTime = now
                swipeDirection = direction
                swipeResetToken = UUID()
                let moved = model.navigateByDisplayedGroup(direction: direction)
                if !moved { swipeDirection = 0 }
            } else if abs(value.translation.width) < abs(value.translation.height), value.translation.height > 80 {
                dismiss()
            }
            scheduleHide()
        }
    }
    private func scheduleSwipeReset() {
        guard swipeDirection != 0 else { return }
        let token = swipeResetToken
        let delay = max(0.35, store.settings.transitionDuration + 0.1)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard swipeResetToken == token else { return }
            swipeDirection = 0
        }
    }
    private var magnifyGesture: some Gesture { MagnifyGesture().onChanged { value in zoom = min(max(value.magnification, 1), 4) }.onEnded { _ in withAnimation { zoom = 1; dragOffset = .zero } } }
    private func scheduleHide() {
        hideTask?.cancel()
        let delay = store.settings.controlAutoHide
        guard ControlsAutoHidePolicy.shouldSchedule(
            alwaysVisible: store.settings.overlays.alwaysVisible,
            playbackAllowed: playbackGateAllows,
            delay: delay
        ) else { return }
        let startedAt = Date()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled,
                  ControlsAutoHidePolicy.isExpired(now: Date(), startedAt: startedAt, delay: delay),
                  playbackGateAllows,
                  !store.settings.overlays.alwaysVisible else { return }
            controlsVisible = false
        }
    }
    private var detailsSheet: some View {
        NavigationStack {
            List {
                if let item = model.currentAsset {
                    LabeledContent("Source", value: item.source.title)
                    LabeledContent("Media", value: item.kind == .video ? "Video" : (item.kind == .livePhoto ? "Live Photo" : "Photo"))
                    if let date = item.creationDate { LabeledContent("Captured", value: date.formatted(date: .long, time: .shortened)) }
                    LabeledContent("Dimensions", value: "\(item.pixelWidth) × \(item.pixelHeight)")
                    LabeledContent("Favorite", value: item.isFavorite ? "Yes" : "No")
                    if let asset = item.appleAsset {
                        Button { Task { await store.library.toggleFavorite(asset) } } label: { Label(asset.isFavorite ? "Remove favorite" : "Favorite", systemImage: asset.isFavorite ? "heart.slash" : "heart") }
                        Button { UIApplication.shared.open(URL(string: "photos-redirect://")!) } label: { Label("Open Photos", systemImage: "photo.on.rectangle") }
                    }
                    Button { store.settingsStore.settings.filters.excludedAssetIDs.insert(item.id); showDetails = false; Task { await model.reload() } } label: { Label("Exclude from Canvas", systemImage: "eye.slash") }
                    if let url = item.localURL { ShareLink(item: url) { Label("Share item", systemImage: "square.and.arrow.up") } }
                }
            }.navigationTitle("Photo details").navigationBarTitleDisplayMode(.inline)
        }.presentationDetents([.medium, .large])
    }

    private var powerAllowsPlayback: Bool {
        let settings = store.settings
        let chargingOkay = !settings.chargingOnly || store.power.isCharging
        let batteryOkay = store.power.batteryLevel < 0 || store.power.batteryLevel * 100 >= Float(settings.lowBatteryStop)
        return chargingOkay && batteryOkay
    }

    private var playbackGateAllows: Bool {
        powerAllowsPlayback && scheduleMonitor.isPlaybackAllowed
    }

    private func updatePowerState() {
        if powerAllowsPlayback {
            store.power.beginPlayback(keepAwake: store.settings.keepAwake)
        } else {
            store.power.endPlayback()
        }
    }
}
