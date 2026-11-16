#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import Photos

/// Opt-in disposable Photos fixtures. Never compiled into a device build.
@MainActor
struct SimulatorAlbumScenario: View {
    @EnvironmentObject var store: AppStore
    @State private var ready = false
    @State private var status = "Preparing"
    @State private var savedCatalog: ((PHFetchResult<PHAssetCollection>) -> [PHAssetCollection])?
    @State private var savedCollection: ((String) -> PHAssetCollection?)?
    @State private var savedMembers: ((PHAssetCollection) -> PHFetchResult<PHAsset>)?
    private let receiptKey = "canvas.simulator-fixture-cleanup"
    private let activeKey = "canvas.simulator-active-album"

    var body: some View {
        ZStack(alignment: .top) {
            if ready { PlayerView() }
            VStack {
                Text(status).accessibilityIdentifier("fixture-status")
                HStack {
                    Button("Add batch during gap") { Task { await addBatch() } }.accessibilityIdentifier("fixture-add")
                    Button("Recover") { recover() }.accessibilityIdentifier("fixture-recover")
                    Button("Clean fixtures") { Task { await cleanup() } }.accessibilityIdentifier("fixture-cleanup")
                }
            }.padding().background(.white).foregroundStyle(.black)
        }.task { await prepare() }
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
            var albumID = "", ids: [String] = []
            let picture = image()
            try await write {
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: "Canvas disposable addition scenario \(UUID())")
                albumID = request.placeholderForCreatedAssetCollection.localIdentifier
                let placeholders = (0..<3).compactMap { _ in PHAssetChangeRequest.creationRequestForAsset(from: picture).placeholderForCreatedAsset }
                ids = placeholders.map(\.localIdentifier)
                request.addAssets(placeholders as NSArray)
            }
            var receipts = UserDefaults.standard.array(forKey: receiptKey) as? [[String: Any]] ?? []
            receipts.append(["albumID": albumID, "assetIDs": ids])
            UserDefaults.standard.set(receipts, forKey: receiptKey)
            UserDefaults.standard.set(albumID, forKey: activeKey)
            let reference = AlbumReference(id: albumID, title: "Disposable simulator album", subtype: PHAssetCollectionSubtype.albumRegular.rawValue, estimatedCount: 3, isSmart: false, isShared: false)
            store.settingsStore.update {
                $0.hasCompletedOnboarding = true; $0.selectedAlbums = [reference]
                $0.queueMode = .shuffle; $0.layout = .single; $0.photoDuration = 600
                $0.schedules = []; $0.lockControls = false
            }
            store.library.track([reference])
            ready = true; status = "Ready"
        } catch { status = "Fixture failed: \(error.localizedDescription)" }
    }

    private func addBatch() async {
        guard let id = UserDefaults.standard.string(forKey: activeKey),
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

    private func recover() {
        let reader = store.library.simulatorReadAccess
        if let savedCatalog { reader.catalog = savedCatalog }
        if let savedCollection { reader.collection = savedCollection }
        if let savedMembers { reader.members = savedMembers }
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
            status = "Cleaned"
        } catch { status = "Cleanup failed: \(error.localizedDescription)" }
    }
}
#endif
