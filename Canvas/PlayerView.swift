import SwiftUI
import Photos
import AVKit

struct PlayerView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = PlaybackViewModel()
    @StateObject private var scheduleMonitor = ScheduleMonitor()
    @StateObject private var nightDimmingMonitor = NightDimmingMonitor()
    @State private var controlsVisible = true
    @GestureState private var gestureZoom: CGFloat = InteractivePhotoZoomPolicy.restingScale
    @State private var hideTask: Task<Void, Never>?
    @State private var isLocked = false
    @State private var showDetails = false
    @State private var lastSwipeTime = Date.distantPast
    @State private var presentedFrame: PlaybackViewModel.DisplayedFrame?
    @State private var outgoingFrame: PlaybackViewModel.DisplayedFrame?
    @State private var activeTransitionStyle: TransitionStyle = .cut
    @State private var transitionProgress: CGFloat = 1
    @State private var transitionCompletionTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if isWeatherFramePreview {
                weatherFramePreview
            } else if !powerAllowsPlayback {
                VStack(spacing: 14) { Image(systemName: "bolt.fill").font(.largeTitle); Text("Canvas is waiting for power") .font(.headline); Text("Charging-only mode or the low-battery limit is enabled in Power & Display.").font(.subheadline).foregroundStyle(.white.opacity(0.65)) }.foregroundStyle(.white.opacity(0.85)).padding(28).multilineTextAlignment(.center)
            } else if !store.settings.schedules.isEmpty && !scheduleMonitor.isPlaybackAllowed {
                if store.settings.schedules.contains(where: \.blackSleepScreen) {
                    Color.black.ignoresSafeArea()
                } else {
                    VStack(spacing: 14) { Image(systemName: "moon.stars.fill").font(.largeTitle); Text("Canvas is resting until the next schedule").font(.headline); Text("You can close this frame or adjust Schedules in Settings.").font(.subheadline).foregroundStyle(.white.opacity(0.65)) }.foregroundStyle(.white.opacity(0.85)).padding(28).multilineTextAlignment(.center)
                }
            } else { nightDimmedMedia }
            if controlsVisible && !isLocked { controls }
            if isLocked { lockBadge }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The slideshow is a photo surface, not a safe-area content panel.
        // Apply this at the container boundary so the GeometryReader that
        // determines each tile's viewport receives the entire display.
        .ignoresSafeArea()
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .task {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            store.weather.setActive(true)
            if isWeatherFramePreview { controlsVisible = false }
            isLocked = store.settings.lockControls
            scheduleMonitor.start(rules: store.settings.schedules)
            updateNightDimmingSchedule()
            model.setPlaybackAllowed(playbackGateAllows)
            model.configure(library: store.library, googlePhotos: store.googlePhotos, loader: store.loader, settings: store.settings)
            store.audio.configure(store.settings)
            if store.settings.backgroundAudio == .localFiles, !store.settings.videoMuted { store.audio.start() }
            updateWeather()
            scheduleHide()
        }
        .onDisappear {
            hideTask?.cancel()
            transitionCompletionTask?.cancel()
            nightDimmingMonitor.stop()
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            store.power.endPlayback(); store.audio.stop(); store.weather.clear()
        }
        .onAppear { store.power.refresh(); if powerAllowsPlayback { store.power.beginPlayback(keepAwake: store.settings.keepAwake) }; scheduleHide() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in store.power.refresh(); updatePowerState() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in store.power.refresh(); updatePowerState() }
        .onChange(of: store.library.libraryRevision) { _, _ in Task { await model.refreshLibrary() } }
        .onChange(of: model.currentAsset?.id) { _, _ in scheduleHide() }
        .onChange(of: model.isPlaying) { _, _ in scheduleHide() }
        .onChange(of: store.settings.overlays.showWeather) { _, _ in updateWeather() }
        .onChange(of: store.settings.effectiveWeatherSource) { _, _ in updateWeather() }
        .onChange(of: store.settings) { _, updated in
            Task {
                await model.updateSettings(updated)
                if model.queueCount == 0 { dismiss() }
            }
            store.audio.update(updated)
            isLocked = updated.lockControls
            updateNightDimmingSchedule(settings: updated)
            scheduleHide()
        }
        .onChange(of: store.googlePhotos.albums) { _, _ in
            Task {
                await model.refreshLibrary()
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
        .onChange(of: scenePhase) { _, phase in
            store.weather.setActive(phase == .active)
            if phase == .active {
                // Re-evaluate immediately after foregrounding so a frame that
                // crossed a night boundary while suspended never waits for
                // the monitor's next periodic tick.
                updateNightDimmingSchedule()
            } else {
                finishFrameTransition()
            }
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

    private var isWeatherFramePreview: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--canvas-ui-weather-frame")
#else
        false
#endif
    }

    private var weatherFramePreview: some View {
        GeometryReader { proxy in
            ZStack {
                Color(red: 0.075, green: 0.09, blue: 0.11)
                overlay(in: proxy.size)
            }
        }
        .ignoresSafeArea()
    }

    private var media: some View {
        GeometryReader { proxy in
            ZStack {
                if let outgoingFrame {
                    frameLayer(outgoingFrame, role: .outgoing, in: proxy.size)
                }
                if let presentedFrame {
                    frameLayer(presentedFrame, role: .incoming, in: proxy.size)
                } else if model.errorMessage != nil {
                    VStack(spacing: 12) { Image(systemName: "icloud.slash").font(.largeTitle); Text(model.errorMessage ?? "Unavailable").foregroundStyle(.white.opacity(0.8)) }.transition(.opacity)
                } else {
                    ProgressView().tint(.white)
                }
                overlay(in: proxy.size)
            }
            .background(Color.black)
            .onAppear {
                model.updateCanvasSize(proxy.size)
                present(model.displayedFrame)
            }
            .onChange(of: model.displayedFrame?.id) { _, _ in
                present(model.displayedFrame)
            }
            .onChange(of: proxy.size) { _, size in model.updateCanvasSize(size) }
        }
        // The media/backdrop surface owns the full display. Controls remain
        // in the parent safe-area layout, so a home-indicator inset cannot
        // leave a black strip below the photo while chrome stays reachable.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
    }

    /// Video and Live Photo surfaces are UIKit-backed and therefore cannot
    /// share LayoutCanvas's background layer. Give them the same contextual
    /// backdrop so fit gaps or a not-yet-ready surface never reveal a fixed
    /// blue placeholder.
    private func playbackBackdrop(for frame: PlaybackViewModel.DisplayedFrame) -> some View {
        let images = frame.layoutImages.isEmpty ? [frame.image] : frame.layoutImages
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

    private func frameLayer(
        _ frame: PlaybackViewModel.DisplayedFrame,
        role: CanvasFrameTransitionRole,
        in size: CGSize
    ) -> some View {
        let visualState = CanvasFrameTransitionGeometry.state(
            style: activeTransitionStyle,
            role: role,
            progress: transitionProgress,
            canvasSize: size
        )
        return frameSurface(
            frame,
            in: size,
            gestureScale: role == .incoming ? gestureZoom : InteractivePhotoZoomPolicy.restingScale
        )
        // Give every frame a non-negotiable viewport before applying visual
        // effects. A transition can move this layer, but it can never feed a
        // partial proposal back into the pair's HStack geometry.
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .modifier(CanvasTransitionModifier(state: visualState))
        .clipped()
    }

    @ViewBuilder
    private func frameSurface(
        _ frame: PlaybackViewModel.DisplayedFrame,
        in size: CGSize,
        gestureScale: CGFloat
    ) -> some View {
        let item = frame.asset
        if item.kind == .video, let asset = item.appleAsset {
            ZStack {
                playbackBackdrop(for: frame)
                VideoAssetView(
                    asset: asset,
                    isPlaying: model.isPlaying,
                    muted: store.settings.videoMuted,
                    volume: store.settings.videoVolume,
                    framingMode: store.settings.effectiveFramingMode
                )
                singleSurfaceCaptureDate(for: frame, in: size)
            }
        } else if item.kind == .video, let url = item.localURL {
            ZStack {
                playbackBackdrop(for: frame)
                LocalVideoView(
                    url: url,
                    isPlaying: model.isPlaying,
                    muted: store.settings.videoMuted,
                    volume: store.settings.videoVolume,
                    framingMode: store.settings.effectiveFramingMode
                )
                singleSurfaceCaptureDate(for: frame, in: size)
            }
        } else if item.kind == .livePhoto, let asset = item.appleAsset {
            ZStack {
                playbackBackdrop(for: frame)
                LivePhotoAssetView(
                    asset: asset,
                    isPlaying: model.isPlaying,
                    loop: store.settings.loopLivePhotos,
                    muted: store.settings.videoMuted,
                    framingMode: store.settings.effectiveFramingMode
                )
                singleSurfaceCaptureDate(for: frame, in: size)
            }
        } else {
            ZStack(alignment: .topLeading) {
                LayoutCanvas(
                    images: frame.layoutImages,
                    style: fullscreenLayout,
                    fit: store.settings.effectiveFramingMode.preservesEntireImage,
                    background: MediaBackdropView.neutralFallback,
                    blurredBackground: store.settings.blurBackground,
                    spacing: CGFloat(store.settings.spacing),
                    cornerRadius: CGFloat(store.settings.cornerRadius),
                    captureDates: frame.layoutAssets.map(\.creationDate),
                    showCaptureDates: false,
                    captureDateStyle: store.settings.overlays.captureDateStyle ?? .darkBadgeLightText,
                    framingMode: store.settings.effectiveFramingMode,
                    overlaySettings: store.settings.overlays
                )
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .scaleEffect(gestureScale)
                // Capture dates live in final device/tile coordinates and are
                // never scaled by a pinch gesture.
                if store.settings.overlays.showCaptureDate {
                    CaptureDateOverlayLayer(
                        imageSizes: frame.layoutImages.map(\.canvasDisplaySize),
                        captureDates: frame.layoutAssets.map(\.creationDate),
                        style: fullscreenLayout,
                        canvasSize: size,
                        spacing: CGFloat(store.settings.spacing),
                        badgeStyle: store.settings.overlays.captureDateStyle ?? .darkBadgeLightText,
                        overlaySettings: store.settings.overlays
                    )
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func singleSurfaceCaptureDate(
        for frame: PlaybackViewModel.DisplayedFrame,
        in size: CGSize
    ) -> some View {
        if store.settings.overlays.showCaptureDate {
            CaptureDateOverlayLayer(
                imageSizes: [frame.image.canvasDisplaySize],
                captureDates: [frame.asset.creationDate],
                style: .single,
                canvasSize: size,
                spacing: 0,
                badgeStyle: store.settings.overlays.captureDateStyle ?? .darkBadgeLightText,
                overlaySettings: store.settings.overlays
            )
        }
    }

    private func present(_ frame: PlaybackViewModel.DisplayedFrame?) {
        guard frame?.id != presentedFrame?.id else { return }
        transitionCompletionTask?.cancel()

        guard let frame else {
            finishFrameTransition()
            presentedFrame = nil
            return
        }
        guard let current = presentedFrame else {
            presentedFrame = frame
            outgoingFrame = nil
            activeTransitionStyle = .cut
            transitionProgress = 1
            return
        }

        // Resolve the complete transition once and keep it stable until the
        // compositor's completion boundary. Random settings, reduce motion,
        // or another view update cannot mutate an animation in flight.
        activeTransitionStyle = TransitionEngine.resolvedStyle(
            preferred: store.settings.transition,
            random: store.settings.randomTransitions,
            excluded: store.settings.excludedTransitions,
            reduceMotion: reduceMotion,
            seed: frame.transitionSeed,
            gestureDirection: frame.gestureDirection
        )
        outgoingFrame = current
        presentedFrame = frame
        transitionProgress = 0

        let duration = activeTransitionStyle == .cut
            ? 0
            : PlaybackTimingPolicy.normalizedTransitionDuration(store.settings.transitionDuration)
        guard duration > 0 else {
            finishFrameTransition()
            return
        }

        let frameID = frame.id
        withAnimation(.easeInOut(duration: duration)) {
            transitionProgress = 1
        }
        transitionCompletionTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration + 0.1))
            guard !Task.isCancelled, presentedFrame?.id == frameID else { return }
            finishFrameTransition()
        }
    }

    private func finishFrameTransition() {
        transitionCompletionTask?.cancel()
        transitionCompletionTask = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            transitionProgress = 1
            outgoingFrame = nil
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
        let items = overlayItems(for: settings)
        let pairsClockAndWeather = WeatherClockLayoutPolicy.pairsClockAndWeather(
            showTime: settings.showTime,
            showWeather: settings.showWeather
        )
        let date = Date()
        return ZStack {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(items) { item in
                        if WeatherClockLayoutPolicy.shouldRenderStandalone(item, paired: pairsClockAndWeather) {
                            if item == .clock, pairsClockAndWeather {
                                clockAndWeatherRow(date: date, settings: settings, textOpacity: opacity.text, canvasSize: size)
                            } else {
                                overlayItem(item, date: date, settings: settings, textOpacity: opacity.text)
                            }
                        }
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
            if CaptureDateOverlayPolicy.showsStandaloneDate(
                enabled: settings.showCaptureDate,
                kind: model.currentAsset?.kind,
                layoutImagesEmpty: model.layoutImages.isEmpty
            ),
               let date = model.currentAsset?.creationDate {
                CaptureDateBadge(
                    date: date,
                    image: model.currentImage,
                    textStrokeSettings: settings
                )
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
    }

    private func clockAndWeatherRow(
        date: Date,
        settings: OverlaySettings,
        textOpacity: Double,
        canvasSize: CGSize
    ) -> some View {
        WeatherClockRow(
            date: date,
            settings: settings,
            mediaImage: model.currentImage,
            weather: WeatherOverlayWidget(
                snapshot: store.weather.snapshot,
                status: store.weather.status,
                isUsingCachedSnapshot: store.weather.isUsingCachedSnapshot,
                settings: settings,
                mediaImage: model.currentImage,
                textOpacity: textOpacity
            ),
            canvasSize: canvasSize
        )
    }

    private func overlayItems(for settings: OverlaySettings) -> [OverlayStackItem] {
        OverlayStackOrder.items(
            position: settings.position,
            showTime: settings.showTime,
            showDate: settings.showDate,
            showAlbum: settings.showAlbum && model.currentAsset?.albumTitle != nil,
            showWeekday: settings.showWeekday,
            showLocation: settings.showLocation && model.currentAsset?.appleAsset?.location != nil,
            showCaption: settings.showCaption && !(model.currentAsset?.filename ?? "").isEmpty,
            showItemCount: settings.showItemCount,
            showBattery: settings.showBattery,
            showWeather: settings.showWeather
        )
    }

    @ViewBuilder
    private func overlayItem(
        _ item: OverlayStackItem,
        date: Date,
        settings: OverlaySettings,
        textOpacity: Double
    ) -> some View {
        switch item {
        case .clock:
            ClockOverlayView(date: date, settings: settings, mediaImage: model.currentImage)
                .accessibilityIdentifier("canvas.clock.overlay")
        case .date:
            Text(settings.effectiveDateFormat.string(from: date))
                .font(.system(size: settings.fontSize * 0.64, weight: settings.effectiveTextWeight.fontWeight, design: .rounded))
                .overlayTextStroke(settings: settings, mediaImage: model.currentImage, opacity: textOpacity)
        case .album:
            if let title = model.currentAsset?.albumTitle {
                Text(title)
                    .font(.system(size: settings.fontSize * 0.62, weight: settings.effectiveTextWeight.fontWeight))
                    .overlayTextStroke(settings: settings, mediaImage: model.currentImage, opacity: textOpacity)
            }
        case .weekday:
            Text(date, format: .dateTime.weekday(.wide))
                .font(.system(size: settings.fontSize * 0.62, weight: settings.effectiveTextWeight.fontWeight))
                .overlayTextStroke(settings: settings, mediaImage: model.currentImage, opacity: textOpacity)
        case .location:
            if let location = model.currentAsset?.appleAsset?.location {
                Text("\(location.coordinate.latitude, specifier: "%.3f"), \(location.coordinate.longitude, specifier: "%.3f")")
                    .font(.system(size: settings.fontSize * 0.54, weight: settings.effectiveTextWeight.fontWeight, design: .monospaced))
                    .overlayTextStroke(settings: settings, mediaImage: model.currentImage, opacity: textOpacity)
            }
        case .caption:
            if let filename = model.currentAsset?.filename, !filename.isEmpty {
                Text(filename)
                    .font(.system(size: settings.fontSize * 0.62, weight: settings.effectiveTextWeight.fontWeight))
                    .lineLimit(1)
                    .overlayTextStroke(settings: settings, mediaImage: model.currentImage, opacity: textOpacity)
            }
        case .itemCount:
            Text("\(model.currentIndex + 1) / \(model.queueCount)")
                .font(.system(size: settings.fontSize * 0.62, weight: settings.effectiveTextWeight.fontWeight, design: .monospaced))
                .overlayTextStroke(settings: settings, mediaImage: model.currentImage, opacity: textOpacity)
        case .battery:
            Label(
                "\(Int(UIDevice.current.batteryLevel * 100))%",
                systemImage: UIDevice.current.batteryState == .charging ? "bolt.fill" : "battery.75percent"
            )
            .font(.system(size: settings.fontSize * 0.54, weight: settings.effectiveTextWeight.fontWeight))
            .overlayTextStroke(settings: settings, mediaImage: model.currentImage, opacity: textOpacity)
        case .weather:
            weatherWidget(settings: settings, textOpacity: textOpacity)
        }
    }

    private func weatherWidget(settings: OverlaySettings, textOpacity: Double) -> some View {
        WeatherOverlayWidget(
            snapshot: store.weather.snapshot,
            status: store.weather.status,
            isUsingCachedSnapshot: store.weather.isUsingCachedSnapshot,
            settings: settings,
            mediaImage: model.currentImage,
            textOpacity: textOpacity
        )
    }
    private func alignment(for position: OverlayPosition) -> Alignment { switch position { case .topLeading: .topLeading; case .topTrailing: .topTrailing; case .bottomLeading: .bottomLeading; case .bottomTrailing: .bottomTrailing; case .center: .center } }
    private func updateWeather() {
        let showWeather = store.settings.overlays.showWeather
        store.weather.update(showWeather: showWeather)
    }
    private var isNightDimActive: Bool {
        nightDimmingMonitor.isActive || scheduleMonitor.activeRule?.dimsAtNight == true
    }
    private var nightDimmedMedia: some View {
        media
            .overlay {
                Color.black
                    .opacity(isNightDimActive ? NightDimmingPolicy.overlayOpacity : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.2), value: isNightDimActive)
    }
    private func updateNightDimmingSchedule(settings: CanvasSettings? = nil) {
        let settings = settings ?? store.settings
        nightDimmingMonitor.start(
            enabled: settings.effectiveAutomaticNightDimmingEnabled,
            startMinutes: settings.effectiveNightDimmingStartMinutes,
            stopMinutes: settings.effectiveNightDimmingStopMinutes
        )
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
                _ = model.navigateByDisplayedGroup(direction: direction, gestureDirection: direction)
            } else if abs(value.translation.width) < abs(value.translation.height), value.translation.height > 80 {
                dismiss()
            }
            scheduleHide()
        }
    }
    private var magnifyGesture: some Gesture {
        MagnifyGesture().updating($gestureZoom) { value, state, _ in
            state = InteractivePhotoZoomPolicy.scale(for: value.magnification)
        }
    }
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

/// Shared visual state for the non-geometric transition styles. Keeping the
/// modifier value-type and pure lets SwiftUI interpolate every property during
/// the same transition animation.
private struct CanvasTransitionModifier: ViewModifier {
    let state: CanvasFrameTransitionState

    private var anchor: UnitPoint {
        switch state.anchor {
        case .center: .center
        case .leading: .leading
        case .trailing: .trailing
        }
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(state.scale, anchor: anchor)
            .blur(radius: state.blur)
            .opacity(state.opacity)
            .offset(state.offset)
            .rotation3DEffect(
                .degrees(state.rotationDegrees),
                axis: (x: 0, y: 1, z: 0),
                anchor: anchor,
                perspective: state.perspective
            )
    }
}
