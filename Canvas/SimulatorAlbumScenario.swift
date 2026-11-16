#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import Photos

/// Opt-in disposable Photos fixtures. Never compiled into a device build.
@MainActor
struct SimulatorAlbumScenario: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var ready = false
    @State private var status = "Preparing"
    @State private var savedCatalog: ((PHFetchResult<PHAssetCollection>) -> [PHAssetCollection])?
    @State private var savedCollection: ((String) -> PHAssetCollection?)?
    @State private var savedMembers: ((PHAssetCollection) -> PHFetchResult<PHAsset>)?
    private let receiptKey = "canvas.simulator-fixture-cleanup"
    private let activeKey = "canvas.simulator-active-album"
    private let missingKey = "canvas.simulator-missing-album"
    private var pairingScenario: Bool { ProcessInfo.processInfo.arguments.contains("--canvas-simulator-portrait-pairing") }
    private var recoveryScenario: Bool { ProcessInfo.processInfo.arguments.contains("--canvas-simulator-stuck-recovery") }

    var body: some View {
        ZStack(alignment: .top) {
            if ready { PlayerView() }
            VStack {
                Text(status).accessibilityIdentifier("fixture-status")
                HStack {
                    Button("Add batch during gap") { Task { await addBatch() } }.accessibilityIdentifier("fixture-add")
                    Button("Recover") { recover() }.accessibilityIdentifier("fixture-recover")
                    if recoveryScenario {
                        Button("Restore Photos reads") { restoreReads(); status = "Reads restored" }
                            .accessibilityIdentifier("fixture-restore-reads")
                    }
                    Button("Clean fixtures") { Task { await cleanup() } }.accessibilityIdentifier("fixture-cleanup")
                }
            }.padding().background(.white).foregroundStyle(.black)
        }.task { await prepare() }
        .onChange(of: scenePhase) { _, phase in
            // This diagnostic root replaces RootView; mirror its recovery
            // lifecycle so foreground tests exercise the production policy.
            store.library.setRecoveryActive(phase == .active)
        }
    }

    private func write(_ block: @escaping () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges(block) { success, error in
                if success { continuation.resume() }
                else { continuation.resume(throwing: error ?? NSError(domain: "SimulatorFixture", code: 1)) }
            }
        }
    }

    private func image() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160)).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
        }
    }

    private func pairingImage(portrait: Bool, label: String, color: UIColor) -> UIImage {
        let size = portrait ? CGSize(width: 240, height: 360) : CGSize(width: 480, height: 240)
        return UIGraphicsImageRenderer(size: size).image { context in
            color.setFill(); context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setStroke(); context.cgContext.setLineWidth(8)
            context.cgContext.stroke(CGRect(origin: .zero, size: size).insetBy(dx: 12, dy: 12))
            (label as NSString).draw(at: CGPoint(x: 25, y: 100), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 23), .foregroundColor: UIColor.white])
        }
    }

    /// Deterministic provider gap for the disposable mixed-orientation fixture.
    /// Real PhotoKit pixels and the production player/renderer are still used.
    static func missingDimensions(_ item: CanvasMediaItem) -> CanvasMediaItem {
        CanvasMediaItem(id: item.id, source: item.source, kind: item.kind, creationDate: item.creationDate,
            filename: item.filename, isFavorite: item.isFavorite, pixelWidth: 0, pixelHeight: 0,
            albumTitle: item.albumTitle, appleAsset: item.appleAsset, localURL: item.localURL,
            contentHash: item.contentHash, libraryID: item.libraryID)
    }

    private func prepare() async {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            status = "Fixture requires simulator Photos authorization"; return
        }
        if ProcessInfo.processInfo.arguments.contains("--canvas-simulator-cleanup") {
            status = "Ready to clean"; return
        }
        if let id = UserDefaults.standard.string(forKey: activeKey),
           PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).count == 1 {
            store.library.track(store.settings.selectedAlbums)
            ready = true; status = "Ready"; return
        }
        do {
            var albumID = "", secondID = "", ids: [String] = []
            let pictures = pairingScenario ? [pairingImage(portrait: true, label: "PORTRAIT A", color: .systemTeal),
                pairingImage(portrait: true, label: "PORTRAIT B", color: .systemOrange),
                pairingImage(portrait: false, label: "LANDSCAPE C", color: .systemIndigo)] : [image(), image(), image()]
            try await write {
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: "Canvas disposable addition scenario \(UUID())")
                albumID = request.placeholderForCreatedAssetCollection.localIdentifier
                let placeholders = pictures.enumerated().compactMap { index, picture in
                    let asset = PHAssetChangeRequest.creationRequestForAsset(from: picture)
                    asset.creationDate = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
                    return asset.placeholderForCreatedAsset
                }
                ids = placeholders.map(\.localIdentifier)
                request.addAssets(placeholders as NSArray)
                if recoveryScenario {
                    let second = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: "Canvas disposable recovery scenario \(UUID())")
                    secondID = second.placeholderForCreatedAssetCollection.localIdentifier
                    second.addAssets(placeholders as NSArray)
                }
            }
            var receipts = UserDefaults.standard.array(forKey: receiptKey) as? [[String: Any]] ?? []
            receipts.append(["albumID": albumID, "assetIDs": ids])
            if !secondID.isEmpty { receipts.append(["albumID": secondID, "assetIDs": [String]()]) }
            UserDefaults.standard.set(receipts, forKey: receiptKey)
            UserDefaults.standard.set(albumID, forKey: activeKey)
            UserDefaults.standard.set(secondID, forKey: missingKey)
            let reference = AlbumReference(id: albumID, title: "Disposable simulator album", subtype: PHAssetCollectionSubtype.albumRegular.rawValue, estimatedCount: 3, isSmart: false, isShared: false)
            var selections = [reference]
            var presets: [CanvasPreset] = []
            if recoveryScenario {
                let reader = store.library.simulatorReadAccess
                savedCatalog = reader.catalog; savedCollection = reader.collection; savedMembers = reader.members
                let hiddenID = secondID, liveCatalog = reader.catalog, liveCollection = reader.collection
                reader.catalog = { liveCatalog($0).filter { $0.localIdentifier != hiddenID } }
                reader.collection = { $0 == hiddenID ? nil : liveCollection($0) }
                // Saved metadata from two versions of the same local album.
                // Mapping service remains unavailable even after local reads recover.
                reader.cloudIdentity = { _ in nil }; reader.localIdentity = { _ in nil }
                var second = AlbumReference(id: secondID, title: "Recovering simulator album", subtype: reference.subtype,
                    estimatedCount: 3, isSmart: false, isShared: false, cloudIdentifier: "fixture-current-cloud")
                selections.append(second)
                second.cloudIdentifier = "fixture-older-cloud"
                var snapshot = CanvasSettings(); snapshot.selectedAlbums = [second]
                presets = [CanvasPreset(name: "Older saved identity", settings: snapshot)]
            }
            store.settingsStore.update {
                $0.presets = presets
                $0.hasCompletedOnboarding = true; $0.selectedAlbums = selections
                $0.queueMode = pairingScenario ? .albumOrder : .shuffle
                $0.layout = pairingScenario ? .automatic : .single; $0.photoDuration = 600
                if pairingScenario { $0.framingMode = .fillZoom }
                $0.schedules = []; $0.lockControls = false
            }
            store.reconcileAlbumSelections()
            ready = true; status = "Ready"
        } catch { status = "Fixture failed: \(error.localizedDescription)" }
    }

    private func addBatch() async {
        guard let id = UserDefaults.standard.string(forKey: recoveryScenario ? missingKey : activeKey),
              let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else { return }
        let reader = store.library.simulatorReadAccess
        if savedCatalog == nil {
            savedCatalog = reader.catalog; savedCollection = reader.collection; savedMembers = reader.members
        }
        reader.catalog = { _ in [] }; reader.collection = { _ in nil }
        reader.members = { _ in PHAsset.fetchAssets(withLocalIdentifiers: [], options: nil) }
        status = "Adding"
        do {
            let picture = image()
            var added: [String] = []
            try await write {
                let placeholders = (0..<4).compactMap { _ in PHAssetChangeRequest.creationRequestForAsset(from: picture).placeholderForCreatedAsset }
                added = placeholders.map(\.localIdentifier)
                PHAssetCollectionChangeRequest(for: album)?.addAssets(placeholders as NSArray)
            }
            var receipts = UserDefaults.standard.array(forKey: receiptKey) as? [[String: Any]] ?? []
            if let index = receipts.firstIndex(where: { $0["albumID"] as? String == id }) {
                receipts[index]["assetIDs"] = (receipts[index]["assetIDs"] as? [String] ?? []) + added
            }
            UserDefaults.standard.set(receipts, forKey: receiptKey)
            store.library.refreshAlbums(contentChanged: true)
            status = "Gap active"
        } catch { status = "Addition failed: \(error.localizedDescription)" }
    }

    private func restoreReads() {
        let reader = store.library.simulatorReadAccess
        if let savedCatalog { reader.catalog = savedCatalog }
        if let savedCollection { reader.collection = savedCollection }
        if let savedMembers { reader.members = savedMembers }
    }

    private func recover() {
        restoreReads()
        store.library.refreshAuthorization()
        status = "Recovered"
    }

    private func cleanup() async {
        ready = false; recover(); status = "Cleaning"
        do {
            let receipts = UserDefaults.standard.array(forKey: receiptKey) as? [[String: Any]] ?? []
            let ids = receipts.compactMap { $0["albumID"] as? String }
            let assets = receipts.flatMap { $0["assetIDs"] as? [String] ?? [] }
            let albums = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: ids, options: nil)
            let photos = PHAsset.fetchAssets(withLocalIdentifiers: assets, options: nil)
            if albums.count > 0 { try await write { PHAssetCollectionChangeRequest.deleteAssetCollections(albums) } }
            if photos.count > 0 { try await write { PHAssetChangeRequest.deleteAssets(photos) } }
            UserDefaults.standard.removeObject(forKey: receiptKey)
            UserDefaults.standard.removeObject(forKey: activeKey)
            UserDefaults.standard.removeObject(forKey: missingKey)
            status = "Cleaned"
        } catch { status = "Cleanup failed: \(error.localizedDescription)" }
    }
}
#endif
