import SwiftUI
import SafariServices

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if store.settings.hasCompletedOnboarding { LibraryHomeView() }
            else { OnboardingView() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.library.refreshAuthorization()
                store.googlePhotos.handleAppReturn()
            }
        }
    }
}

struct OnboardingView: View {
    @EnvironmentObject private var store: AppStore
    @State private var step = 0
    @State private var isRequesting = false
    @State private var showAlbumPicker = false
    @State private var albumsConfirmed = false

    var body: some View {
        ZStack {
            CanvasBackground()
            VStack(spacing: 0) {
                HStack {
                    AppMark(size: 44)
                    Text("Canvas").font(.title2.weight(.semibold))
                    Spacer()
                    Text("\(step + 1) / 2").font(.footnote.monospaced()).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 28).padding(.top, 24)
                TabView(selection: $step) {
                    welcome.tag(0)
                    albums.tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 14) {
                if step > 0 {
                    Button("Back") {
                        withAnimation {
                            if step == 1 && albumsConfirmed { albumsConfirmed = false }
                            else { step -= 1 }
                        }
                    }.buttonStyle(.secondaryCanvas)
                }
                Spacer()
                Button(step == 1 && albumsConfirmed ? "Start Canvas" : "Continue") {
                    if step == 1 && store.settings.selectedAlbums.isEmpty && !store.library.authorization.canRead {
                        isRequesting = true
                        Task {
                            await store.library.requestAccess()
                            isRequesting = false
                            // The chooser also contains Google Photos, so Apple access being denied
                            // must not strand onboarding.
                            showAlbumPicker = true
                        }
                    } else if step == 1 && store.settings.selectedAlbums.isEmpty {
                        showAlbumPicker = true
                    } else if step == 1 && !albumsConfirmed {
                        withAnimation { albumsConfirmed = true }
                    } else if step < 1 {
                        withAnimation { step += 1 }
                    } else {
                        completeOnboarding()
                    }
                }
                .buttonStyle(.primaryCanvas)
                .disabled(isRequesting)
            }
            .padding(.horizontal, 28).padding(.bottom, 20)
            .background(.ultraThinMaterial)
        }
        .sheet(isPresented: $showAlbumPicker) { AlbumPickerView(isOnboarding: true) }
        // A confirmed selection is only valid for the collection that was
        // reviewed. If the picker adds/removes an album afterward, require one
        // fresh Continue tap so Start Canvas can never complete onboarding with
        // an empty or stale selection.
        .onChange(of: store.settings.selectedAlbums) { oldSelection, newSelection in
            if oldSelection != newSelection { albumsConfirmed = false }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer()
            AppMark(size: 112)
            Text("Your photos,\nbeautifully at rest.")
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
            Text("Canvas turns your iPad into a calm, private digital frame. Choose the albums you love and let the moments unfold.")
                .font(.title3).foregroundStyle(.secondary).lineSpacing(4)
            Spacer()
        }.padding(.horizontal, 36)
    }

    private var albums: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Image(systemName: "rectangle.stack.badge.plus").font(.system(size: 64)).foregroundStyle(.blue.gradient)
            Text("Choose your first albums").font(.system(size: 36, weight: .bold, design: .rounded))
            Text(albumsConfirmed ? "Your albums are ready. Start Canvas now, or go back to change the selection." : (store.settings.selectedAlbums.isEmpty ? "Start with Recents, Favorites, or any albums from your library." : "\(store.settings.selectedAlbums.count) album\(store.settings.selectedAlbums.count == 1 ? "" : "s") selected"))
                .font(.title3).foregroundStyle(.secondary)
            if !store.settings.selectedAlbums.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.settings.selectedAlbums) { album in
                        Label {
                            Text(album.title).lineLimit(1)
                        } icon: {
                            Image(systemName: album.source == .googlePhotos ? "g.circle.fill" : "photo.stack.fill")
                                .foregroundStyle(album.source == .googlePhotos ? .blue : .orange)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            Button { showAlbumPicker = true } label: { Label("Select albums", systemImage: "plus") }.buttonStyle(.secondaryCanvas)
            Spacer()
        }.padding(.horizontal, 36)
    }

    private func completeOnboarding() {
        var updated = store.settings
        updated.hasCompletedOnboarding = true
        store.settingsStore.settings = updated
    }
}

struct LibraryHomeView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showAlbumPicker = false
    @State private var showSettings = false
    @State private var showPlayer = false
    @State private var previewImages: [UIImage] = []
    @State private var isStartingFrame = false
    @State private var showStartRecovery = false
    @AppStorage("canvas.home.preview.seed") private var previewSeed = 0
    @State private var deviceOrientation = UIDevice.current.orientation

    var body: some View {
        NavigationStack {
            ZStack {
                CanvasBackground()
                GeometryReader { viewport in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 26) {
                            content(albumAreaHeight: HomeContentGeometry.albumAreaHeight(
                                viewportHeight: viewport.size.height,
                                fixedContentHeight: 250,
                                minimumHeight: minimumAlbumGridHeight,
                                bottomExtension: HomeContentGeometry.bottomEdgeExtension(reportedSafeAreaBottom: viewport.safeAreaInsets.bottom)
                            ))
                            // A normal Google-only frame should not carry a
                            // persistent Photos warning underneath its media.
                            // Keep the actionable card only when there is no
                            // selection and Apple access needs attention.
                            if store.settings.selectedAlbums.isEmpty,
                               !store.library.authorization.canRead {
                                permissionCard
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.bottom, 0)
                        .frame(minHeight: viewport.size.height, alignment: .top)
                    }
                    .ignoresSafeArea(edges: .bottom)
                }
                .ignoresSafeArea(edges: .bottom)
            }
            .navigationBarHidden(true)
            // Keep the toolbar out of the scrolling/clipped content layer.
            // This prevents the portrait layout's album grid or safe-area
            // adjustment from covering the two top-right hit regions.
            .safeAreaInset(edge: .top, spacing: 0) {
                header
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
                    .contentShape(Rectangle())
                    .zIndex(10)
            }
            .sheet(isPresented: $showAlbumPicker) { AlbumPickerView(isOnboarding: false) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .fullScreenCover(isPresented: $showPlayer) { PlayerView() }
            .alert("Choose photos to start", isPresented: $showStartRecovery) {
                Button("Manage albums") { showAlbumPicker = true }
                Button("Try again") { startFrame() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(startRecoveryMessage)
            }
            .onAppear {
                previewSeed += 1
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                updateDeviceOrientation(UIDevice.current.orientation)
            }
            .onDisappear { UIDevice.current.endGeneratingDeviceOrientationNotifications() }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                updateDeviceOrientation(UIDevice.current.orientation)
            }
            .task(id: "\(previewKey)#\(previewSeed)") { await loadPreviewImages() }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 12) {
                AppMark(size: 46)
                VStack(alignment: .leading) { Text("Canvas").font(.title.weight(.bold)); Text("Your quiet gallery").font(.subheadline).foregroundStyle(.secondary) }
            }
            Spacer()
            HStack(spacing: 12) {
                Button { showAlbumPicker = true } label: { Image(systemName: "rectangle.stack.badge.plus").font(.title3).frame(width: 46, height: 46) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Manage albums")
                    .accessibilityIdentifier("manage-albums")
                    .background(.thinMaterial, in: Circle())
                Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3").font(.title3).frame(width: 46, height: 46) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("settings")
                    .background(.thinMaterial, in: Circle())
            }
        }
        .frame(minHeight: 70)
        .allowsHitTesting(true)
    }

    private func content(albumAreaHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if store.settings.selectedAlbums.isEmpty { emptyState }
            else {
                Button { startFrame() } label: {
                    playbackCard
                        .frame(maxWidth: .infinity, minHeight: 148, alignment: .leading)
                }
                    .buttonStyle(.plain)
                    .disabled(isStartingFrame)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("start-your-frame")
                    .accessibilityLabel("Start your frame")
                    .accessibilityHint("Starts the slideshow using the selected albums, or explains how to choose playable media.")
                Text("Selected albums").font(.title3.weight(.semibold))
                selectedAlbumGrid(height: albumAreaHeight)
            }
        }
    }

    private func selectedAlbumGrid(height: CGFloat) -> some View {
        GeometryReader { proxy in
            let count = store.settings.selectedAlbums.count
            let columns = albumGridColumns(count: count, size: proxy.size)
            let rows = max(1, Int(ceil(Double(count) / Double(columns))))
            let gridHeight = max(height, CGFloat(rows) * 190 + CGFloat(max(0, rows - 1)) * 14)
            let tileHeight = (gridHeight - CGFloat(max(0, rows - 1)) * 14) / CGFloat(rows)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: columns), spacing: 14) {
                ForEach(store.settings.selectedAlbums) { album in
                    albumCard(album).frame(height: tileHeight)
                }
            }
        }
        .frame(height: max(height, minimumAlbumGridHeight))
    }

    private var minimumAlbumGridHeight: CGFloat {
        let count = store.settings.selectedAlbums.count
        let rows = count <= 1 ? 1 : (count <= 4 ? 2 : Int(ceil(Double(count) / 2.0)))
        return CGFloat(rows) * 190 + CGFloat(max(0, rows - 1)) * 14
    }

    private func albumGridColumns(count: Int, size: CGSize) -> Int {
        if count <= 1 { return 1 }
        if count == 4 { return 2 }
        if count == 2 { return size.width > size.height ? 2 : 1 }
        if count == 3 { return size.width > size.height ? 3 : 2 }
        return size.width > size.height ? 3 : 2
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 44)).foregroundStyle(.orange)
            Text("Pick a few albums to begin").font(.title2.weight(.semibold))
            Text("Canvas will keep your choices local and build a responsive slideshow from the Photos library.").foregroundStyle(.secondary)
            Button { showAlbumPicker = true } label: { Label("Choose albums", systemImage: "plus") }.buttonStyle(.primaryCanvas)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Photos access needed", systemImage: "lock.shield").font(.title3.weight(.semibold))
            Text(store.library.authorization.explanation ?? "Allow access to choose albums.").foregroundStyle(.secondary)
            Button("Request access") { Task { await store.library.requestAccess() } }.buttonStyle(.primaryCanvas)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var playbackCard: some View {
        HStack(spacing: 18) {
            ZStack {
                if previewImages.isEmpty {
                    RoundedRectangle(cornerRadius: 18).fill(.quaternary)
                    Image(systemName: "photo.on.rectangle").font(.largeTitle).foregroundStyle(.secondary)
                } else if let image = previewImages.first {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 116, height: 116)
                        .clipped()
                }
                Image(systemName: "play.fill").font(.title).foregroundStyle(.white).padding(20).background(.black.opacity(0.22), in: Circle())
            }
            .frame(width: 116, height: 116)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            VStack(alignment: .leading, spacing: 7) {
                Text("Start your frame").font(.title2.weight(.bold))
                Text("\(store.settings.selectedAlbums.count) album\(store.settings.selectedAlbums.count == 1 ? "" : "s")  ·  \(store.settings.photoDuration.cleanSeconds) photos").foregroundStyle(.secondary)
                Label(
                    HomePlaybackSummary.label(queueMode: store.settings.queueMode, transition: store.settings.transition),
                    systemImage: "shuffle"
                )
                .font(.subheadline)
                .foregroundStyle(.orange)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }.padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private func startFrame() {
        guard !isStartingFrame else { return }
        isStartingFrame = true
        // Resolve the same sources PlaybackViewModel uses, on the button's
        // main-actor action. The old detached Task could leave the button in a
        // busy state or attempt to present a sheet without any visible change.
        // Refreshing first keeps newly-added Apple Photos screenshots visible,
        // while local Google downloads remain available without a network call.
        store.library.refreshAuthorization()
        store.library.refreshAlbums()
        let apple = store.library.mediaItems(for: store.settings.selectedAlbums, filters: store.settings.filters)
        let google = store.googlePhotos.items(for: store.settings.selectedAlbums, filters: store.settings.filters)
        let playable = MediaIdentityMatcher.deduplicated(apple + google)
        switch FrameLaunchPolicy.decision(for: playable) {
        case .ready:
            showStartRecovery = false
            showPlayer = true
        case .needsSelection:
            showStartRecovery = true
        }
        isStartingFrame = false
    }

    private var startRecoveryMessage: String {
        if store.settings.selectedAlbums.isEmpty {
            return "Select at least one Apple Photos album or saved Google Photos album. Canvas will use the media already available on this iPad."
        }
        if !store.library.authorization.canRead {
            return "Canvas cannot read the selected Apple Photos album yet. Allow Photos access, or choose a saved Google Photos album with downloaded items."
        }
        return "The selected albums do not currently contain playable media. Check Photos access or return to Manage albums and choose another source."
    }

    private func albumCard(_ album: AlbumReference) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            AlbumThumbnail(album: album, previewSeed: previewSeed, isLandscapeDevice: deviceIsLandscape).frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
            Text(album.title).font(.headline).lineLimit(1)
            Text("\(album.estimatedCount) items · \(album.source.title)").font(.caption).foregroundStyle(.secondary)
        }.padding(12).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private var deviceIsLandscape: Bool? {
        switch deviceOrientation {
        case .landscapeLeft, .landscapeRight: true
        case .portrait, .portraitUpsideDown: false
        default: nil
        }
    }

    private func updateDeviceOrientation(_ orientation: UIDeviceOrientation) {
        switch orientation {
        case .landscapeLeft, .landscapeRight, .portrait, .portraitUpsideDown:
            deviceOrientation = orientation
        default:
            break
        }
    }

    private var previewKey: String {
        let albums = store.settings.selectedAlbums.map(\.id).joined(separator: "|")
        let google = store.googlePhotos.albums.map { "\($0.id):\($0.updatedAt.timeIntervalSince1970)" }.joined(separator: "|")
        let filters = store.settings.filters
        let filterKey = [
            filters.includePhotos,
            filters.includeLivePhotos,
            filters.includeVideos,
            filters.includeHidden,
            filters.includeScreenshots,
            filters.includeBursts,
            filters.locationTaggedOnly,
            filters.favoritesOnly
        ].map(String.init).joined(separator: ",")
        let dateKey = "\(filters.startDate?.timeIntervalSince1970 ?? 0):\(filters.endDate?.timeIntervalSince1970 ?? 0)"
        return "\(albums)#\(store.library.libraryRevision)#\(google)#\(filterKey)#\(dateKey)"
    }

    private func loadPreviewImages() async {
        let apple = store.library.mediaItems(for: store.settings.selectedAlbums, filters: store.settings.filters)
        let google = store.googlePhotos.items(for: store.settings.selectedAlbums, filters: store.settings.filters)
        let items = HomePreviewSelection.representativeItems(
            from: MediaIdentityMatcher.deduplicated(apple + google),
            limit: 2,
            seed: previewSeed,
            albumID: "home"
        )
        var loaded: [UIImage] = []
        for item in items {
            if let image = await store.loader.image(for: item, service: store.library, size: CGSize(width: 600, height: 600)) { loaded.append(image) }
        }
        previewImages = loaded
    }
}

private struct AlbumThumbnail: View {
    @EnvironmentObject private var store: AppStore
    let album: AlbumReference
    let previewSeed: Int
    let isLandscapeDevice: Bool?
    @State private var images: [UIImage] = []

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                if !images.isEmpty {
                    collage(in: proxy.size)
                    Color.black.opacity(0.12)
                } else {
                    Color.secondary.opacity(0.12)
                    Image(systemName: album.source == .googlePhotos ? "g.circle.fill" : "photo.on.rectangle")
                        .font(.title2).foregroundStyle(.secondary).padding(14)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .clipped()
        .task(id: "\(album.id)#\(previewSeed)#\(store.library.libraryRevision)#\(store.googlePhotos.albums.first(where: { $0.id == album.id })?.updatedAt.timeIntervalSince1970 ?? 0)") {
            let filters = store.settings.filters
            let items = album.source == .googlePhotos
                ? store.googlePhotos.items(for: [album], filters: filters)
                : store.library.mediaItems(for: [album], filters: filters)
            var loaded: [UIImage] = []
            let representatives = HomePreviewSelection.representativeItems(from: items, limit: 4, seed: previewSeed, albumID: album.id)
            for item in representatives {
                if let image = await store.loader.image(for: item, service: store.library, size: CGSize(width: 700, height: 500)) {
                    loaded.append(image)
                }
            }
            images = loaded
        }
    }

    @ViewBuilder
    private func collage(in size: CGSize) -> some View {
        let selection = HomePreviewLayoutResolver.selection(imageSizes: images.map(\.size), canvasSize: size, isLandscapeDevice: isLandscapeDevice)
        switch selection.style {
        case .single:
            tile(images[selection.indices.first ?? 0], width: size.width, height: size.height)
        case .pairHorizontal:
            HStack(spacing: 2) {
                tile(images[selection.indices[0]], width: (size.width - 2) / 2, height: size.height)
                tile(images[selection.indices[1]], width: (size.width - 2) / 2, height: size.height)
            }
        case .pairVertical:
            VStack(spacing: 2) {
                tile(images[selection.indices[0]], width: size.width, height: (size.height - 2) / 2)
                tile(images[selection.indices[1]], width: size.width, height: (size.height - 2) / 2)
            }
        }
    }

    private func tile(_ image: UIImage, width: CGFloat, height: CGFloat) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: max(0, width), height: max(0, height))
            .clipped()
    }
}

struct AlbumPickerView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let isOnboarding: Bool
    @State private var selection: Set<String> = []
    @State private var search = ""
    @State private var showGoogleImport = false
    @State private var knownGoogleAlbumIDs: Set<String> = []

    private func appleAlbums(in category: AppleAlbumCategory) -> [AlbumReference] {
        filtered(store.library.albums.filter { AppleAlbumCategory.category(for: $0) == category })
    }
    private var googleAlbums: [AlbumReference] { filtered(store.googlePhotos.albumReferences) }
    private var availableAlbums: [AlbumReference] { store.library.albums + store.googlePhotos.albumReferences }
    var body: some View {
        NavigationStack {
            List {
                ForEach(AppleAlbumCategory.allCases) { category in
                    albumCategorySection(category)
                }
                Section("Google Photos") {
                    Button { showGoogleImport = true } label: {
                        Label("Add or refresh a Google album", systemImage: "photo.badge.plus")
                    }
                    Text("Saved Google selections appear here as albums. Google’s external Picker starts with media and requires searching for an album title; it cannot open to an album list.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if googleAlbums.isEmpty {
                        Text("No Google albums saved yet.").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(googleAlbums) { album in albumChoice(album) }
                    }
                }
                Section {
                    Text("Canvas reads only the albums you select. Apple shared and smart albums appear when Photos makes them available.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .searchable(text: $search, prompt: "Find an album")
            .navigationTitle("Choose albums")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { commit() }.fontWeight(.semibold) } }
            .onAppear { selection = Set(store.settings.selectedAlbums.map(\.id)); knownGoogleAlbumIDs = Set(store.googlePhotos.albumReferences.map(\.id)); store.library.refreshAlbums() }
            .onChange(of: store.googlePhotos.albums) { _, _ in
                let current = Set(store.googlePhotos.albumReferences.map(\.id))
                selection.subtract(knownGoogleAlbumIDs.subtracting(current))
                selection.formUnion(current.subtracting(knownGoogleAlbumIDs))
                knownGoogleAlbumIDs = current
            }
            .onChange(of: store.settings.selectedAlbums) { _, references in
                selection = Set(references.map(\.id))
            }
            .onChange(of: store.googlePhotos.lastSyncedAlbumID) { _, id in
                if let id, !id.isEmpty { selection.insert(id) }
            }
            .sheet(isPresented: $showGoogleImport) { GooglePhotosImportView() }
        }
    }
    private func filtered(_ albums: [AlbumReference]) -> [AlbumReference] {
        albums.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    @ViewBuilder
    private func albumCategorySection(_ category: AppleAlbumCategory) -> some View {
        let albums = appleAlbums(in: category)
        Section("Apple Photos · \(category.title)") {
            if albums.isEmpty {
                Text(search.isEmpty ? "No \(category.title.lowercased()) available." : "No matching albums.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(albums) { album in albumChoice(album) }
            }
        }
    }
    private func albumChoice(_ album: AlbumReference) -> some View {
        Button {
            if selection.contains(album.id) { selection.remove(album.id) } else { selection.insert(album.id) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: selection.contains(album.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selection.contains(album.id) ? .orange : .secondary).font(.title3)
                VStack(alignment: .leading) {
                    Text(album.title).foregroundStyle(.primary)
                    Text("\(album.estimatedCount) items\(album.isSmart ? " · Smart" : "")").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }.buttonStyle(.plain)
    }
    private func commit() { store.settingsStore.settings.selectedAlbums = availableAlbums.filter { selection.contains($0.id) }; dismiss() }
}

struct GooglePhotosImportView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var albumName = "Google Photos"
    @State private var pickerTask: Task<Void, Never>?
    @State private var albumToDelete: GoogleAlbumRecord?
    @State private var safariFallback: SafariFallbackRequest?

    var body: some View {
        NavigationStack {
            Form {
                Section("Google Photos") {
                    connectionStatus
                    if store.googlePhotos.configurationAvailable && !isFailure {
                        TextField("Saved album name", text: $albumName)
                        Button { choosePhotos() } label: {
                            Label("Open Google Photos", systemImage: "photo.badge.plus")
                        }
                        .disabled(isBusy)
                        Text("Canvas first tries the Google Photos app’s supported handoff, then falls back to the web Picker. Google starts with recent items—not an album list—so use Search for the album title, select its contents, and tap Done.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let summary = store.googlePhotos.lastImportSummary {
                    Section(summary.isPartial ? "Import finished with issues" : "Imported successfully") {
                        Label(summary.statusTitle, systemImage: summary.isPartial ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(summary.isPartial ? .orange : .green)
                        Text(summary.message)
                        if !summary.failureSummaries.isEmpty {
                            ForEach(summary.failureSummaries) { failure in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(failure.category.title): \(failure.count) item\(failure.count == 1 ? "" : "s")")
                                        .font(.subheadline.weight(.semibold))
                                    Text(failure.category.guidance)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if let example = failure.example, !example.isEmpty {
                                        Text("Observed: \(example)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        if summary.canRetryFailedItems {
                            Button("Retry unavailable items (\(summary.skippedCount))") { retryFailedDownloads() }
                                .disabled(isBusy)
                            Text("Canvas will retry only these items while the current Google Picker session is still available; it will not ask you to select the whole album again.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if summary.failureSummaries.contains(where: { $0.category == .authorization }) {
                                Button("Reconnect Google Photos") { reconnectGooglePhotos() }
                                    .disabled(isBusy)
                                Text("Reconnect first if Google authorization expired during the download. The saved failures remain available for a retry.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text(summary.isPartial ? "This Picker session has been closed. Start a new Google selection to try the remaining items." : "Canvas selected this saved album for your next frame. Tap Done to return to the album list, or choose photos again to update it.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("How shared albums work") {
                    Text("Google’s current Picker API does not let Canvas enumerate or browse your Google album list. To import a shared album, search for its title in Google Photos, select the items you want, and finish the Picker. Canvas saves those selected items offline as one Google album; repeat the flow with the same Canvas name to refresh it.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !store.googlePhotos.configurationAvailable {
                    Section("One-time developer setup") {
                        LabeledContent("OAuth client type", value: "iOS")
                        LabeledContent("Bundle ID", value: "com.johnhelmuth.canvas")
                        Button("Copy bundle ID") { UIPasteboard.general.string = "com.johnhelmuth.canvas" }
                        Link("Enable Google Photos Picker API", destination: URL(string: "https://console.cloud.google.com/apis/library/photospicker.googleapis.com")!)
                        Link("Create the OAuth client", destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                        Text("After Google creates the client, set GOOGLE_PHOTOS_CLIENT_ID to its client ID and GOOGLE_PHOTOS_CALLBACK_SCHEME to that client ID in reverse-DNS form, then rebuild and reinstall Canvas. No client secret is needed or safe in the app.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !store.googlePhotos.albums.isEmpty {
                    Section("Synced Google albums") {
                        ForEach(store.googlePhotos.albums) { album in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(album.title)
                                    Text("\(album.items.count) items · Updated \(album.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { albumToDelete = album } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.red)
                                .accessibilityLabel("Delete saved Canvas copy of \(album.title)")
                                .disabled(isBusy)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Google Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { finish() } } }
            .interactiveDismissDisabled(isBusy)
            .onChange(of: store.googlePhotos.pickerHandoff) { _, handoff in
                if handoff == .browserFallback, let url = store.googlePhotos.pickerBrowserURL {
                    safariFallback = SafariFallbackRequest(url: url)
                }
            }
            .sheet(item: $safariFallback) { request in
                SafariFallbackView(url: request.url)
                    .ignoresSafeArea()
            }
            .confirmationDialog("Delete saved Canvas copy?", isPresented: Binding(
                get: { albumToDelete != nil },
                set: { if !$0 { albumToDelete = nil } }
            )) {
                Button("Delete saved copy", role: .destructive) {
                    if let album = albumToDelete { store.deleteGoogleAlbum(album.id) }
                    albumToDelete = nil
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Delete \(albumToDelete?.title ?? "this album") from Canvas only. Nothing will be deleted from Google Photos.")
            }
        }
    }

    @ViewBuilder private var connectionStatus: some View {
        switch store.googlePhotos.state {
        case .unavailable(let message): Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .disconnected: Label("Not connected", systemImage: "link.badge.plus")
        case .connecting: Label("Connecting…", systemImage: "person.crop.circle")
        case .authorizationSaved: Label("Google access is saved. Canvas will verify it when you choose photos.", systemImage: "key.fill").foregroundStyle(.secondary)
        case .connected:
            if store.googlePhotos.lastImportSummary?.isPartial == true {
                Label("Google Photos connected, import incomplete", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                Label("Google Photos is connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case .selecting:
            VStack(alignment: .leading, spacing: 10) {
                Label("Waiting for your Google Photos selection…", systemImage: "photo.on.rectangle")
                switch store.googlePhotos.pickerHandoff {
                case .nativeApp:
                    Text("Canvas handed the session to the Google Photos app. Return here after selecting items and tapping Done.")
                case .browserFallback:
                    Text("iPadOS did not resolve the Google Photos app link, so Canvas opened the supported Safari fallback. Return here after selecting items and tapping Done.")
                case nil:
                    Text("Opening the Google Photos picker…")
                }
                Text("The Picker starts with recent media. Use Search for the album title, select its photos or videos, and finish the selection.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Open Picker again") { reopenPicker() }
                    .disabled(!isBusy)
                if store.googlePhotos.pickerHandoff == .nativeApp {
                    Button("Open Picker in Safari instead") { openPickerInBrowser() }
                        .disabled(!isBusy)
                        .font(.subheadline)
                }
                if let url = store.googlePhotos.pickerBrowserURL {
                    Button {
                        UIPasteboard.general.string = url.absoluteString
                    } label: {
                        Label("Copy Safari fallback link", systemImage: "doc.on.doc")
                    }
                    Text("If the browser tab keeps loading, copy this link and open it in Safari after signing in to the same Google account.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Cancel Google Photos selection", role: .cancel) { cancelPicker() }
            }
        case .syncing(let completed, let total): VStack(alignment: .leading) { Text("Saving \(completed) of \(total)…"); ProgressView(value: Double(completed), total: Double(max(1, total))) }
        case .retrying(let completed, let total): VStack(alignment: .leading) { Text("Retrying \(completed) of \(total) unavailable items…"); ProgressView(value: Double(completed), total: Double(max(1, total))) }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Button("Retry Google Photos selection") { retrySelection() }
                if let url = store.googlePhotos.pickerBrowserURL {
                    Button {
                        UIPasteboard.general.string = url.absoluteString
                    } label: {
                        Label("Copy Safari fallback link", systemImage: "doc.on.doc")
                    }
                    Text("The previous session may have expired; try again in Canvas to create a fresh link.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func choosePhotos() {
        let title = albumName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = title.isEmpty ? "Google Photos" : title
        albumName = resolvedTitle
        pickerTask?.cancel()
        pickerTask = Task { @MainActor in
            await store.googlePhotos.syncAlbum(named: resolvedTitle, matchingWith: store.library)
            if let summary = store.googlePhotos.lastImportSummary {
                selectImportedAlbum(summary.albumID)
            }
            pickerTask = nil
        }
    }

    private func selectImportedAlbum(_ id: String) {
        guard let album = store.googlePhotos.albumReferences.first(where: { $0.id == id }) else { return }
        var updated = store.settings
        if let index = updated.selectedAlbums.firstIndex(where: { $0.id == id }) {
            updated.selectedAlbums[index] = album
        } else {
            updated.selectedAlbums.append(album)
        }
        store.settingsStore.settings = updated
    }

    private func finish() {
        if isBusy { cancelPicker() }
        else { store.googlePhotos.discardPendingImport() }
        dismiss()
    }
    private func retrySelection() {
        store.googlePhotos.retryAfterError()
        choosePhotos()
    }
    private func retryFailedDownloads() {
        pickerTask?.cancel()
        pickerTask = Task { @MainActor in
            await store.googlePhotos.retryFailedDownloads()
            if let summary = store.googlePhotos.lastImportSummary, !summary.albumID.isEmpty {
                selectImportedAlbum(summary.albumID)
            }
            pickerTask = nil
        }
    }

    private func reconnectGooglePhotos() {
        pickerTask?.cancel()
        pickerTask = Task { @MainActor in
            await store.googlePhotos.connect()
            pickerTask = nil
        }
    }
    private func cancelPicker() {
        pickerTask?.cancel()
        pickerTask = nil
        store.googlePhotos.cancelPicker()
    }
    private func reopenPicker() {
        Task { @MainActor in
            await store.googlePhotos.reopenPicker()
            // If the same session is reopened after a previous Safari sheet
            // was dismissed, pickerHandoff may remain `.browserFallback` and
            // SwiftUI will not emit an onChange event for the equal value.
            // Present the existing documented URL explicitly in that case so
            // “Open Picker again” always performs a visible action.
            if store.googlePhotos.pickerHandoff == .browserFallback,
               let url = store.googlePhotos.pickerBrowserURL {
                safariFallback = SafariFallbackRequest(url: url)
            }
        }
    }
    private func openPickerInBrowser() {
        if let url = store.googlePhotos.useBrowserFallback() {
            safariFallback = SafariFallbackRequest(url: url)
        }
    }
    private var isBusy: Bool { switch store.googlePhotos.state { case .connecting, .selecting, .syncing, .retrying: true; default: false } }
    private var isFailure: Bool { if case .failed = store.googlePhotos.state { return true }; return false }
}

private struct SafariFallbackRequest: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct SafariFallbackView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
