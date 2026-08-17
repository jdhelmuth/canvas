import AuthenticationServices
import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import Security
import UIKit

enum GooglePhotosConnectionState: Equatable {
    case unavailable(String)
    case disconnected
    case connecting
    case authorizationSaved
    case connected
    case selecting
    case syncing(completed: Int, total: Int)
    case retrying(completed: Int, total: Int)
    case failed(String)

    var isConnected: Bool {
        switch self { case .connected, .selecting, .syncing, .retrying: true; default: false }
    }
}

enum GooglePhotosPickerHandoff: Equatable {
    case nativeApp
    case browserFallback
}

enum GooglePhotosError: LocalizedError {
    case missingConfiguration
    case cancelled
    case invalidResponse
    case authorizationFailed(String)
    case api(String)
    case http(status: Int, message: String)
    case selectionTimedOut
    case noItemsSelected
    case albumPersistence(GoogleAlbumPersistenceError)
    case importFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration: GooglePhotosService.missingConfigurationMessage
        case .cancelled: "Google Photos connection was cancelled."
        case .invalidResponse: "Google Photos returned an unreadable response."
        case .authorizationFailed(let message): "Google authorization failed: \(message)"
        case .api(let message): message
        case .http(_, let message): message
        case .selectionTimedOut: "The Google Photos picker did not finish in time. Tap Retry Google Photos selection to create a fresh session."
        case .noItemsSelected: "No Google Photos items were selected."
        case .albumPersistence(let error): error.localizedDescription
        case .importFailed(let message): message
        }
    }
}

enum GoogleAlbumPersistenceError: LocalizedError, Equatable {
    case corrupt
    case unsupportedSchema(Int)
    case couldNotPersist

    var errorDescription: String? {
        switch self {
        case .corrupt:
            "Canvas could not read its saved Google Photos albums. It preserved the file and stopped importing so no saved selection is lost."
        case .unsupportedSchema(let version):
            "Canvas found newer saved Google Photos album data (schema \(version)) and stopped rather than treating it as empty or overwriting it."
        case .couldNotPersist:
            "Canvas could not durably save the Google Photos album selection. Existing saved items were preserved."
        }
    }
}

struct GoogleAlbumPersistenceDocument: Codable, Equatable {
    static let currentSchemaVersion = 1
    var schemaVersion = currentSchemaVersion
    var albums: [GoogleAlbumRecord]
}

/// Durable local Google-import metadata. A malformed or newer document is an
/// explicit load error: the store exposes no writable empty replacement and
/// refuses every subsequent persist until the app can understand the file.
final class GoogleAlbumPersistenceStore {
    private let fileManager: FileManager
    let url: URL
    private(set) var albums: [GoogleAlbumRecord]
    private(set) var loadError: GoogleAlbumPersistenceError?

    init(fileManager: FileManager = .default, url: URL? = nil) {
        self.fileManager = fileManager
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Canvas", isDirectory: true)
        self.url = url ?? applicationSupport.appendingPathComponent("google-photos-albums.json")
        self.albums = []

        do {
            self.albums = try Self.load(fileManager: fileManager, url: self.url)
        } catch let error as GoogleAlbumPersistenceError {
            self.loadError = error
        } catch {
            self.loadError = .corrupt
        }
    }

    func persist(_ updated: [GoogleAlbumRecord]) throws {
        if let loadError { throw loadError }
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(GoogleAlbumPersistenceDocument(albums: updated))
            try data.write(to: url, options: .atomic)
            albums = updated
        } catch {
            throw GoogleAlbumPersistenceError.couldNotPersist
        }
    }

    private static func load(fileManager: FileManager, url: URL) throws -> [GoogleAlbumRecord] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw GoogleAlbumPersistenceError.corrupt
        }

        do {
            let document = try JSONDecoder().decode(GoogleAlbumPersistenceDocument.self, from: data)
            guard document.schemaVersion <= GoogleAlbumPersistenceDocument.currentSchemaVersion else {
                throw GoogleAlbumPersistenceError.unsupportedSchema(document.schemaVersion)
            }
            return document.albums
        } catch let error as GoogleAlbumPersistenceError {
            throw error
        } catch {
            // c49e6de wrote a bare array. Keep that valid historical data
            // readable, but do not reinterpret any other unreadable bytes as
            // an empty import.
            if let legacy = try? JSONDecoder().decode([GoogleAlbumRecord].self, from: data) {
                return legacy
            }
            throw GoogleAlbumPersistenceError.corrupt
        }
    }
}

private struct GooglePhotosConfiguration {
    let clientID: String
    let callbackScheme: String

    static var bundled: GooglePhotosConfiguration? {
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "GooglePhotosClientID") as? String,
              let callbackScheme = Bundle.main.object(forInfoDictionaryKey: "GooglePhotosCallbackScheme") as? String,
              !clientID.isEmpty, !callbackScheme.isEmpty,
              !clientID.contains("$("), !callbackScheme.contains("$(") else { return nil }
        return GooglePhotosConfiguration(clientID: clientID, callbackScheme: callbackScheme)
    }

    var redirectURI: String { "\(callbackScheme):/oauthredirect" }
}

private struct OAuthTokens: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiration: Date
}

private struct PickerSession: Decodable {
    struct Polling: Decodable { let pollInterval: String?; let timeoutIn: String? }
    let id: String
    let pickerUri: String?
    let pollingConfig: Polling?
    let mediaItemsSet: Bool?
}

private struct PickerMediaPage: Decodable {
    let mediaItems: [PickedMediaItem]?
    let nextPageToken: String?
}

struct GooglePickerPaginationState: Equatable {
    private(set) var pagesFetched = 0
    private(set) var nextPageToken: String?
    private var requestedPageTokens: Set<String> = []

    var hasNextPage: Bool { nextPageToken != nil }

    mutating func markPageTokenRequested(_ pageToken: String) -> Bool {
        requestedPageTokens.insert(pageToken).inserted
    }

    mutating func consume(nextPageToken: String?) {
        pagesFetched += 1
        self.nextPageToken = nextPageToken?.isEmpty == true ? nil : nextPageToken
    }
}

private struct PickedMediaItem: Decodable {
    struct MediaFile: Decodable {
        struct Metadata: Decodable { let width: Int?; let height: Int? }
        let baseUrl: String
        let mimeType: String?
        let filename: String?
        let mediaFileMetadata: Metadata?
    }
    let id: String
    let createTime: String?
    let type: String
    let mediaFile: MediaFile
}

private struct GoogleDownloadResult {
    let records: [GoogleMediaRecord]
    let failures: [GoogleDownloadFailure]

    var skippedCount: Int { failures.count }
    var firstErrorDescription: String? { failures.first?.reason }
    var failureSummaries: [GoogleImportFailureSummary] {
        let grouped = Dictionary(grouping: failures, by: \.category)
        return grouped.keys.sorted { $0.title < $1.title }.map { category in
            let values = grouped[category] ?? []
            return GoogleImportFailureSummary(category: category, count: values.count, example: values.first?.reason)
        }
    }
}

private struct GoogleDownloadFailure {
    let item: PickedMediaItem
    let category: GoogleImportFailureCategory
    let reason: String
}

private struct PendingGoogleImport {
    let sessionID: String
    let title: String
    let selectedCount: Int
    let matchedAppleAlbumID: String?
    let updatedExistingAlbum: Bool
    var albumID: String?
    var savedRecords: [GoogleMediaRecord]
    var failedItems: [PickedMediaItem]
}

private enum GoogleDownloadProgress {
    case initial
    case retry
}

@MainActor
final class GooglePhotosService: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    nonisolated static let missingConfigurationMessage = "This Canvas build has no Google OAuth client. Enable Google Photos Picker API, create an iOS OAuth client for bundle ID com.johnhelmuth.canvas, set GOOGLE_PHOTOS_CLIENT_ID and GOOGLE_PHOTOS_CALLBACK_SCHEME (the reversed client ID), then rebuild and reinstall Canvas."
    /// Google supplies a session timeout, but keep a local upper bound so a
    /// browser handoff that never loads cannot leave Canvas polling forever.
    nonisolated static let maximumPickerWait: TimeInterval = 5 * 60
    /// Google coerces larger Picker selections to 2,000 items. Additional
    /// media must be selected in another additive session.
    nonisolated static let maximumPickerItemCount = 2_000
    @Published private(set) var state: GooglePhotosConnectionState
    @Published private(set) var albums: [GoogleAlbumRecord] = []
    @Published private(set) var albumPersistenceError: GoogleAlbumPersistenceError?
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var lastSyncedAlbumID: String?
    @Published private(set) var lastImportSummary: GooglePhotosImportSummary?
    @Published private(set) var pickerNativeURL: URL?
    @Published private(set) var pickerBrowserURL: URL?
    @Published private(set) var pickerHandoff: GooglePhotosPickerHandoff?

    private let fileManager: FileManager
    private let session: URLSession
    private let albumsStore: GoogleAlbumPersistenceStore
    private var authSession: ASWebAuthenticationSession?
    private var tokens: OAuthTokens?
    private let tokenService = "com.johnhelmuth.canvas.google-photos"
    private var activePickerSessionID: String?
    private var activeOperationID: UUID?
    private var activeAppleMirrorRetryID: UUID?
    private var pendingImport: PendingGoogleImport?

    override init() {
        fileManager = .default
        session = .shared
        albumsStore = GoogleAlbumPersistenceStore(fileManager: fileManager)
        if GooglePhotosConfiguration.bundled == nil {
            state = .unavailable(Self.missingConfigurationMessage)
        } else {
            state = .disconnected
        }
        super.init()
        tokens = loadTokens()
        albums = albumsStore.albums
        albumPersistenceError = albumsStore.loadError
        lastSyncDate = albums.map(\.updatedAt).max()
        // A token in Keychain is only saved authorization, not proof that the Photos
        // Picker API currently accepts it. We mark the connection usable only after
        // a Picker session has actually been created.
        if let albumPersistenceError = albumPersistenceError {
            state = .failed(albumPersistenceError.localizedDescription)
        } else if GooglePhotosConfiguration.bundled != nil, tokens != nil {
            state = .authorizationSaved
        }
    }

    // Keep provider choices independent even when an imported Google selection
    // appears to match an Apple album. Playback deduplicates the media themselves.
    var albumReferences: [AlbumReference] { albums.map(\.reference) }
    var configurationAvailable: Bool { GooglePhotosConfiguration.bundled != nil }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }

    func connect() async {
        activeAppleMirrorRetryID = nil
        do {
            state = .connecting
            _ = try await authorizeInteractively()
            state = .authorizationSaved
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect(removeImportedAlbums: Bool = false) {
        discardPendingImport()
        tokens = nil
        deleteTokens()
        if let albumPersistenceError {
            state = .failed(albumPersistenceError.localizedDescription)
            return
        }
        if removeImportedAlbums {
            let importedAlbums = albums
            albums = []
            if saveAlbums() {
                for album in importedAlbums { removeFiles(for: album) }
                removeUnreferencedMediaFiles()
            } else {
                albums = importedAlbums
            }
        }
        state = configurationAvailable ? .disconnected : .unavailable(Self.missingConfigurationMessage)
    }

    /// Opens Google's supported Picker. Users can search for an album title there
    /// (including a shared album) and select its items; the API does not expose an
    /// album-list endpoint for this flow.
    func syncAlbum(
        named rawTitle: String,
        matchingWith appleLibrary: PhotoLibraryService,
        mirrorWith mirrorService: GooglePhotosMirrorService
    ) async {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { state = .failed("Enter an album name before selecting from Google Photos."); return }
        if let persistenceError = albumPersistenceError {
            state = .failed(persistenceError.localizedDescription)
            return
        }
        discardPendingImport()
        let operationID = UUID()
        activeOperationID = operationID
        activePickerSessionID = nil
        pickerBrowserURL = nil
        pickerNativeURL = nil
        pickerHandoff = nil
        lastImportSummary = nil
        lastSyncedAlbumID = nil
        var keepSessionForRetry = false
        defer {
            if activeOperationID == operationID {
                activeOperationID = nil
                if !keepSessionForRetry {
                    let sessionID = activePickerSessionID
                    activePickerSessionID = nil
                    pickerNativeURL = nil
                    pickerBrowserURL = nil
                    pickerHandoff = nil
                    if let sessionID {
                        Task { [weak self] in
                            try? await self?.deletePickerSession(id: sessionID)
                        }
                    }
                }
            }
        }
        do {
            state = .connecting
            let token = try await validAccessToken(interactive: true)
            guard isCurrent(operationID) else { return }
            let pickerSession = try await createPickerSession(token: token)
            guard let pickerUri = pickerSession.pickerUri,
                  let rawURL = URL(string: pickerUri),
                  let url = Self.validatedPickerURL(rawURL) else { throw GooglePhotosError.invalidResponse }
            activePickerSessionID = pickerSession.id
            pickerNativeURL = url
            let browserURL = Self.browserURL(for: url)
            pickerBrowserURL = browserURL
            // Reaching this state means both OAuth and the Photos Picker API have
            // accepted the session; a cached token alone never earns a connected badge.
            state = .selecting
            // Google documents pickerUri as the supported handoff into Google
            // Photos. Prefer the installed app's universal-link route; if iPadOS
            // cannot resolve it, fall back to Google's documented web URL with
            // /autoclose so Safari closes when the selection is done.
            pickerHandoff = try await openPicker(nativeURL: url, browserURL: browserURL)
            guard isCurrent(operationID) else { return }
            let completed = try await waitForSelection(session: pickerSession, operationID: operationID)
            let picked = uniquePickedItems(try await listPickedItemsWithRetry(sessionID: completed.id))
            guard !picked.isEmpty else { throw GooglePhotosError.noItemsSelected }
            let downloadResult = try await download(picked, progress: .initial)
            guard isCurrent(operationID) else {
                removeUncommittedFiles(for: downloadResult.records)
                return
            }
            let existingAlbum = albums.first { $0.title.normalizedAlbumTitle == title.normalizedAlbumTitle }
            // Keep any legacy display-only metadata already attached to this
            // Canvas album, but never create a new Apple match from a title or
            // media overlap. The dedicated mirror resolves ownership through
            // its own persisted ID/marker index.
            let appleMatch = existingAlbum?.matchedAppleAlbumID
            var importedID = existingAlbum?.id
            var preservedCount = existingAlbum?.items.count ?? 0
            var totalSavedCount = existingAlbum?.items.count ?? 0
            var updatedExistingAlbum = existingAlbum != nil
            if !downloadResult.records.isEmpty {
                let plan = try addToAlbum(title: title, records: downloadResult.records, matchedAppleAlbumID: appleMatch)
                importedID = plan.albumID
                preservedCount = plan.itemMerge.preservedCount
                totalSavedCount = plan.itemMerge.records.count
                updatedExistingAlbum = plan.updatedExistingAlbum
                lastSyncedAlbumID = plan.albumID
            }
            let applePhotosMirror: GoogleApplePhotosMirrorSummary? = if let importedID, !importedID.isEmpty {
                await mirrorAlbum(importedID, with: mirrorService, photoLibrary: appleLibrary)
            } else {
                nil
            }
            guard isCurrent(operationID) else { return }
            let hasFailures = !downloadResult.failures.isEmpty
            lastImportSummary = GooglePhotosImportSummary(
                albumID: importedID ?? "",
                title: title,
                selectedCount: picked.count,
                savedCount: downloadResult.records.count,
                preservedCount: preservedCount,
                totalSavedCount: totalSavedCount,
                skippedCount: downloadResult.skippedCount,
                failureSummaries: downloadResult.failureSummaries,
                canRetryFailedItems: hasFailures,
                updatedExistingAlbum: updatedExistingAlbum,
                applePhotosMirror: applePhotosMirror
            )
            lastSyncDate = Date()
            if hasFailures {
                pendingImport = PendingGoogleImport(
                    sessionID: completed.id,
                    title: title,
                    selectedCount: picked.count,
                    matchedAppleAlbumID: appleMatch,
                    updatedExistingAlbum: updatedExistingAlbum,
                    albumID: importedID,
                    savedRecords: downloadResult.records,
                    failedItems: downloadResult.failures.map(\.item)
                )
                keepSessionForRetry = true
                activePickerSessionID = completed.id
                pickerNativeURL = nil
                pickerBrowserURL = nil
                pickerHandoff = nil
                state = importedID == nil ? .failed("Canvas could not save any of the selected Google media. Retry unavailable items below before choosing a new Picker session.") : .connected
            } else {
                guard let importedID, !importedID.isEmpty else {
                    throw GooglePhotosError.importFailed("Canvas downloaded the Google selection but could not save its album record. Try again.")
                }
                try? await deletePickerSession(id: completed.id)
                pendingImport = nil
                pickerNativeURL = nil
                pickerBrowserURL = nil
                pickerHandoff = nil
                state = .connected
                activePickerSessionID = nil
            }
        } catch {
            guard isCurrent(operationID, allowCancelled: true) else { return }
            let wasCancelled: Bool
            if error is CancellationError {
                wasCancelled = true
            } else if let googleError = error as? GooglePhotosError, case .cancelled = googleError {
                wasCancelled = true
            } else {
                wasCancelled = false
            }
            if wasCancelled {
                state = .failed("Google Photos selection was cancelled. Tap Retry Google Photos selection to start again.")
            } else {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func retryAfterError() {
        discardPendingImport()
        pickerBrowserURL = nil
        pickerNativeURL = nil
        pickerHandoff = nil
        lastImportSummary = nil
        state = tokens == nil ? .disconnected : .authorizationSaved
    }

    /// Retries only the media records that failed during the most recent
    /// import. The Picker session is kept alive for this purpose until the
    /// person taps Done or starts a fresh selection.
    func retryFailedDownloads(
        mirroringWith mirrorService: GooglePhotosMirrorService,
        photoLibrary: PhotoLibraryService
    ) async {
        activeAppleMirrorRetryID = nil
        if let persistenceError = albumPersistenceError {
            state = .failed(persistenceError.localizedDescription)
            return
        }
        guard var pending = pendingImport, !pending.failedItems.isEmpty else {
            state = .failed("There are no saved Google Photos failures to retry. Start a new selection.")
            return
        }
        let operationID = UUID()
        activeOperationID = operationID
        activePickerSessionID = pending.sessionID
        defer {
            if activeOperationID == operationID { activeOperationID = nil }
        }
        do {
            let candidates = try await refreshedFailedItems(for: pending)
            guard isCurrent(operationID) else { return }
            guard !candidates.isEmpty else {
                throw GooglePhotosError.importFailed("Google no longer exposes the failed media in this Picker session. Start a new selection.")
            }
            let result = try await download(candidates, progress: .retry)
            guard isCurrent(operationID) else {
                removeUncommittedFiles(for: result.records)
                return
            }
            let combinedRecords = GoogleMediaMergePolicy.adding(result.records, to: pending.savedRecords).records
            var mergePlan: GoogleAlbumImportPlan?
            if !result.records.isEmpty {
                let plan = try addToAlbum(title: pending.title, records: combinedRecords, matchedAppleAlbumID: pending.matchedAppleAlbumID)
                mergePlan = plan
                pending.albumID = plan.albumID
                pending.savedRecords = combinedRecords
                lastSyncedAlbumID = pending.albumID
            }
            pending.failedItems = result.failures.map(\.item)
            pendingImport = pending
            let savedAlbum = pending.albumID.flatMap { id in albums.first(where: { $0.id == id }) }
            let currentSessionIDs = Set(combinedRecords.map(\.googleID))
            let preservedCount = mergePlan?.itemMerge.preservedCount ?? savedAlbum?.items.filter { !currentSessionIDs.contains($0.googleID) }.count ?? 0
            let totalSavedCount = mergePlan?.itemMerge.records.count ?? savedAlbum?.items.count ?? 0
            let applePhotosMirror: GoogleApplePhotosMirrorSummary? = if let albumID = pending.albumID, !albumID.isEmpty {
                await mirrorAlbum(albumID, with: mirrorService, photoLibrary: photoLibrary)
            } else {
                nil
            }
            guard isCurrent(operationID) else { return }
            let summary = GooglePhotosImportSummary(
                albumID: pending.albumID ?? "",
                title: pending.title,
                selectedCount: pending.selectedCount,
                savedCount: combinedRecords.count,
                preservedCount: preservedCount,
                totalSavedCount: totalSavedCount,
                skippedCount: result.skippedCount,
                failureSummaries: result.failureSummaries,
                canRetryFailedItems: !result.failures.isEmpty,
                updatedExistingAlbum: pending.updatedExistingAlbum,
                applePhotosMirror: applePhotosMirror
            )
            lastImportSummary = summary
            lastSyncDate = Date()
            if result.failures.isEmpty {
                pendingImport = nil
                try? await deletePickerSession(id: pending.sessionID)
                activePickerSessionID = nil
                state = .connected
            } else {
                activePickerSessionID = pending.sessionID
                state = pending.albumID == nil ? .failed("Canvas still could not save any selected Google media. Retry the unavailable items again or start a new Picker session.") : .connected
            }
        } catch {
            guard isCurrent(operationID, allowCancelled: true) else { return }
            if error is CancellationError {
                state = .failed("Google Photos retry was cancelled. Retry the unavailable items when ready.")
            } else {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Retries only the non-destructive Apple Photos mirror. It never opens a
    /// new Google Picker session and never deletes or replaces Photos content.
    func retryApplePhotosMirror(
        albumID: String,
        with mirrorService: GooglePhotosMirrorService,
        photoLibrary: PhotoLibraryService
    ) async {
        guard let album = albums.first(where: { $0.id == albumID }) else {
            state = .failed("The saved Google album is no longer available in Canvas.")
            return
        }
        switch state {
        case .connecting, .selecting, .syncing, .retrying:
            return
        default:
            break
        }
        let retryID = UUID()
        activeAppleMirrorRetryID = retryID
        defer {
            if activeAppleMirrorRetryID == retryID { activeAppleMirrorRetryID = nil }
        }
        let returnState = state
        state = .syncing(completed: 0, total: max(1, album.items.count))
        let mirrorSummary = await mirrorAlbum(albumID, with: mirrorService, photoLibrary: photoLibrary)
        guard activeAppleMirrorRetryID == retryID, !Task.isCancelled else { return }
        if var summary = lastImportSummary, summary.albumID == albumID {
            summary.applePhotosMirror = mirrorSummary
            lastImportSummary = summary
        } else {
            lastImportSummary = GooglePhotosImportSummary(
                albumID: albumID,
                title: album.title,
                selectedCount: 0,
                savedCount: 0,
                preservedCount: album.items.count,
                totalSavedCount: album.items.count,
                skippedCount: 0,
                failureSummaries: [],
                canRetryFailedItems: false,
                updatedExistingAlbum: true,
                applePhotosMirror: mirrorSummary
            )
        }
        // This is an Apple-only retry and must not imply that Google OAuth or
        // a Picker session was revalidated.
        state = returnState
    }

    /// Discards an incomplete Picker session when the user chooses Done or
    /// starts a new selection. Google recommends deleting sessions after the
    /// media bytes have been retrieved.
    func discardPendingImport() {
        let sessionID = pendingImport?.sessionID ?? activePickerSessionID
        pendingImport = nil
        activeOperationID = nil
        activeAppleMirrorRetryID = nil
        activePickerSessionID = nil
        pickerNativeURL = nil
        pickerBrowserURL = nil
        pickerHandoff = nil
        guard let sessionID else { return }
        Task { [weak self] in
            try? await self?.deletePickerSession(id: sessionID)
        }
    }

    /// Reopens the currently active Picker session. This is useful when the
    /// browser tab was left spinning or iPadOS chose Safari instead of the app.
    func reopenPicker() async {
        guard Self.pickerSessionCanContinueAfterAppReturn(state: state), activeOperationID != nil, activePickerSessionID != nil, let nativeURL = pickerNativeURL, let browserURL = pickerBrowserURL else {
            state = .failed("That Google Photos session has expired. Tap Try again to create a fresh Picker.")
            return
        }
        do {
            pickerHandoff = try await openPicker(nativeURL: nativeURL, browserURL: browserURL)
            state = .selecting
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Selects the documented web fallback for the current session without
    /// creating a second session. The view presents the returned URL in a
    /// Safari browser sheet, avoiding an opaque default-browser handoff.
    @discardableResult
    func useBrowserFallback() -> URL? {
        guard Self.pickerSessionCanContinueAfterAppReturn(state: state), activeOperationID != nil, activePickerSessionID != nil, let browserURL = pickerBrowserURL else {
            state = .failed("That Google Photos session has expired. Tap Try again to create a fresh Picker.")
            return nil
        }
        pickerHandoff = .browserFallback
        state = .selecting
        return browserURL
    }

    /// Picker handoff has no OAuth callback of its own. Returning from Google
    /// Photos or Safari therefore only needs to leave the existing session and
    /// polling task intact; this hook intentionally does not create a second
    /// session or cancel the first one.
    func handleAppReturn() {
        guard activePickerSessionID != nil,
              Self.pickerSessionCanContinueAfterAppReturn(state: state) else { return }
    }

    /// Stops polling and cleans up the server session when the person decides
    /// not to continue. The caller also cancels its awaiting Task.
    func cancelPicker() {
        authSession?.cancel()
        authSession = nil
        let sessionID = activePickerSessionID ?? pendingImport?.sessionID
        activePickerSessionID = nil
        activeOperationID = nil
        activeAppleMirrorRetryID = nil
        pendingImport = nil
        pickerBrowserURL = nil
        pickerNativeURL = nil
        pickerHandoff = nil
        lastImportSummary = nil
        state = .failed("Google Photos selection was cancelled. Tap Retry Google Photos selection to start again.")
        if let sessionID {
            Task { [weak self] in
                try? await self?.deletePickerSession(id: sessionID)
            }
        }
    }

    func items(for references: [AlbumReference], filters: CanvasFilters) -> [CanvasMediaItem] {
        let selected = Set(references.filter { $0.source == .googlePhotos }.map(\.id))
        return albums.filter { selected.contains($0.id) }.flatMap { album in
            album.items.compactMap { item in
                let url = mediaRoot.appendingPathComponent(item.relativePath)
                guard fileManager.fileExists(atPath: url.path) else { return nil }
                let value = CanvasMediaItem(id: item.id, source: .googlePhotos, kind: item.kind, creationDate: item.creationDate, filename: item.filename, isFavorite: false, pixelWidth: item.pixelWidth, pixelHeight: item.pixelHeight, albumTitle: album.title, appleAsset: nil, localURL: url, contentHash: item.contentHash, libraryID: album.id)
                return filters.accepts(value.descriptor) ? value : nil
            }
        }
    }

    @discardableResult
    func deleteAlbum(_ id: String) -> Bool {
        guard albumPersistenceError == nil else { return false }
        guard let plan = GoogleAlbumDeletionPlan.removing(albumID: id, from: albums) else { return false }
        // Do not discard a Picker session or retry state until the local
        // deletion has durably committed. A failed persistence write must be
        // a true no-op for both the album and its in-flight retry.
        let pendingAlbumID = pendingImport?.albumID
        let previousAlbums = albums
        albums = plan.remainingAlbums
        guard saveAlbums() else {
            albums = previousAlbums
            return false
        }
        let committed = GoogleAlbumDeletionCommitPolicy.decide(
            albumID: id,
            from: previousAlbums,
            pendingAlbumID: pendingAlbumID,
            persistenceSucceeded: true
        )!
        if committed.discardPendingImport { discardPendingImport() }
        for path in committed.removableRelativePaths { try? fileManager.removeItem(at: mediaRoot.appendingPathComponent(path)) }
        removeUnreferencedMediaFiles()
        if lastSyncedAlbumID == id { lastSyncedAlbumID = nil }
        if lastImportSummary?.albumID == id { lastImportSummary = nil }
        return true
    }

    // MARK: OAuth

    private func authorizeInteractively() async throws -> String {
        guard let configuration = GooglePhotosConfiguration.bundled else { throw GooglePhotosError.missingConfiguration }
        let verifier = randomURLSafeString(byteCount: 48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        let stateValue = randomURLSafeString(byteCount: 24)
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/photospicker.mediaitems.readonly"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: stateValue)
        ]
        guard let authURL = components.url else { throw GooglePhotosError.invalidResponse }
        let callback: URL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let auth = ASWebAuthenticationSession(url: authURL, callbackURLScheme: configuration.callbackScheme) { url, error in
                if let authError = error as? ASWebAuthenticationSessionError, authError.code == .canceledLogin {
                    continuation.resume(throwing: GooglePhotosError.cancelled)
                } else if let error {
                    continuation.resume(throwing: error)
                } else if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: GooglePhotosError.invalidResponse)
                }
            }
            auth.presentationContextProvider = self
            auth.prefersEphemeralWebBrowserSession = false
            authSession = auth
            guard auth.start() else {
                authSession = nil
                continuation.resume(throwing: GooglePhotosError.authorizationFailed("The sign-in window could not open."))
                return
            }
        }
        authSession = nil
        let callbackComponents = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        let queryItems: [URLQueryItem] = callbackComponents?.queryItems ?? []
        let values: [String: String] = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
        guard values["state"] == stateValue else { throw GooglePhotosError.authorizationFailed("Invalid OAuth state.") }
        if let error = values["error"] { throw GooglePhotosError.authorizationFailed(error) }
        guard let code = values["code"], !code.isEmpty else { throw GooglePhotosError.invalidResponse }
        return try await exchangeCode(code, verifier: verifier, configuration: configuration)
    }

    private func exchangeCode(_ code: String, verifier: String, configuration: GooglePhotosConfiguration) async throws -> String {
        let form = ["client_id": configuration.clientID, "code": code, "code_verifier": verifier, "grant_type": "authorization_code", "redirect_uri": configuration.redirectURI]
        let response: TokenResponse = try await postTokenForm(form)
        let value = OAuthTokens(accessToken: response.access_token, refreshToken: response.refresh_token, expiration: Date().addingTimeInterval(TimeInterval(response.expires_in ?? 3600) - 60))
        tokens = value
        saveTokens(value)
        return value.accessToken
    }

    private func validAccessToken(interactive: Bool) async throws -> String {
        if let tokens, tokens.expiration > Date() { return tokens.accessToken }
        if let refresh = tokens?.refreshToken, let configuration = GooglePhotosConfiguration.bundled {
            do {
                let response: TokenResponse = try await postTokenForm(["client_id": configuration.clientID, "refresh_token": refresh, "grant_type": "refresh_token"])
                let value = OAuthTokens(accessToken: response.access_token, refreshToken: response.refresh_token ?? refresh, expiration: Date().addingTimeInterval(TimeInterval(response.expires_in ?? 3600) - 60))
                tokens = value; saveTokens(value); return value.accessToken
            } catch {
                tokens = nil; deleteTokens()
            }
        }
        guard interactive else { throw GooglePhotosError.authorizationFailed("Please reconnect Google Photos.") }
        return try await authorizeInteractively()
    }

    private struct TokenResponse: Decodable { let access_token: String; let refresh_token: String?; let expires_in: Int? }
    private func postTokenForm<T: Decodable>(_ values: [String: String]) async throws -> T {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = values.map { "\($0.key.formEncoded)=\($0.value.formEncoded)" }.sorted().joined(separator: "&").data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Picker

    private func createPickerSession(token: String) async throws -> PickerSession {
        var request = URLRequest(url: URL(string: "https://photospicker.googleapis.com/v1/sessions")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["pickingConfig": ["maxItemCount": String(Self.maximumPickerItemCount)]])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await decode(request)
    }

    private func waitForSelection(session initial: PickerSession, operationID: UUID) async throws -> PickerSession {
        let started = Date()
        var current = initial
        while current.mediaItemsSet != true {
            try Task.checkCancellation()
            guard isCurrent(operationID) else { throw GooglePhotosError.cancelled }
            let interval = duration(current.pollingConfig?.pollInterval) ?? 2
            let timeout = duration(current.pollingConfig?.timeoutIn) ?? 900
            let elapsed = Date().timeIntervalSince(started)
            let effectiveTimeout = min(timeout, Self.maximumPickerWait)
            guard elapsed < effectiveTimeout else { throw GooglePhotosError.selectionTimedOut }
            try await Task.sleep(for: .seconds(min(interval, effectiveTimeout - elapsed)))
            let token = try await validAccessToken(interactive: false)
            var request = URLRequest(url: URL(string: "https://photospicker.googleapis.com/v1/sessions/\(current.id)")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            current = try await decode(request)
        }
        return current
    }

    private func isCurrent(_ operationID: UUID, allowCancelled: Bool = false) -> Bool {
        guard activeOperationID == operationID else { return false }
        return allowCancelled || !Task.isCancelled
    }

    private func openPicker(nativeURL: URL, browserURL: URL) async throws -> GooglePhotosPickerHandoff {
        // The Picker URI itself is Google's supported native handoff. Do not
        // invent a private googlephotos:// scheme: iPadOS can only resolve the
        // app when the installed Google Photos build advertises this universal
        // link, and the API's URI may vary by account/session.
        if await UIApplication.shared.open(nativeURL, options: [.universalLinksOnly: true]) {
            return Self.pickerHandoff(nativeLinkOpened: true)
        }
        // The SwiftUI import sheet presents this URL in SFSafariViewController
        // after this method returns. Do not launch the user's default browser
        // here: Chrome can retain a blank/spinning tab without a clear way back.
        return Self.pickerHandoff(nativeLinkOpened: false)
    }

    nonisolated static func pickerHandoff(nativeLinkOpened: Bool) -> GooglePhotosPickerHandoff {
        nativeLinkOpened ? .nativeApp : .browserFallback
    }

    nonisolated static func pickerSessionCanContinueAfterAppReturn(state: GooglePhotosConnectionState) -> Bool {
        switch state {
        case .selecting, .syncing, .retrying: true
        default: false
        }
    }

    nonisolated static func validatedPickerURL(_ pickerURL: URL) -> URL? {
        guard pickerURL.scheme?.lowercased() == "https",
              let host = pickerURL.host, !host.isEmpty,
              !pickerURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty else { return nil }
        return pickerURL
    }

    nonisolated static func browserURL(for pickerURL: URL) -> URL {
        guard let validated = validatedPickerURL(pickerURL) else { return pickerURL }
        guard validated.pathComponents.last?.lowercased() != "autoclose" else { return validated }
        var components = URLComponents(url: validated, resolvingAgainstBaseURL: false)
        let path = components?.path ?? validated.path
        components?.path = path.hasSuffix("/") ? path + "autoclose" : path + "/autoclose"
        return components?.url ?? validated.appendingPathComponent("autoclose")
    }

    private func listPickedItems(sessionID: String) async throws -> [PickedMediaItem] {
        var output: [PickedMediaItem] = []
        var pagination = GooglePickerPaginationState()
        repeat {
            let token = try await validAccessToken(interactive: false)
            var components = URLComponents(string: "https://photospicker.googleapis.com/v1/mediaItems")!
            components.queryItems = [URLQueryItem(name: "sessionId", value: sessionID), URLQueryItem(name: "pageSize", value: "100")]
            if let pageToken = pagination.nextPageToken {
                // A malformed/replayed page token must not leave the import
                // task spinning forever.  Treat it as an API failure that the
                // user can retry with a fresh session.
                guard pagination.markPageTokenRequested(pageToken) else {
                    throw GooglePhotosError.api("Google Photos returned a repeated media page. Retry the selection.")
                }
                components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let page: PickerMediaPage = try await decode(request)
            output.append(contentsOf: page.mediaItems ?? [])
            pagination.consume(nextPageToken: page.nextPageToken)
        } while pagination.hasNextPage
        return output
    }

    private func listPickedItemsWithRetry(sessionID: String) async throws -> [PickedMediaItem] {
        var attempt = 0
        while true {
            do {
                return try await listPickedItems(sessionID: sessionID)
            } catch {
                guard Self.pickerReadinessRetryAllowed(message: error.localizedDescription, attempt: attempt) else { throw error }
                attempt += 1
                try await Task.sleep(for: .seconds(2))
            }
        }
    }

    nonisolated static func isPickerReadinessMessage(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("failed_precondition") || normalized.contains("failed precondition") || normalized.contains("not ready") || normalized.contains("not finished") || normalized.contains("mediaitemsset")
    }

    nonisolated static func pickerReadinessRetryAllowed(message: String, attempt: Int) -> Bool {
        attempt < 3 && isPickerReadinessMessage(message)
    }

    private func download(_ picked: [PickedMediaItem], progress: GoogleDownloadProgress) async throws -> GoogleDownloadResult {
        try fileManager.createDirectory(at: mediaRoot, withIntermediateDirectories: true)
        var result: [GoogleMediaRecord] = []
        var failures: [GoogleDownloadFailure] = []
        for (index, item) in picked.enumerated() {
            setDownloadProgress(progress, completed: index, total: picked.count)
            do {
                result.append(try await download(item))
            } catch {
                if error is CancellationError {
                    removeUncommittedFiles(for: result)
                    throw error
                }
                if Self.isAuthorizationFailure(error) {
                    let reason = "Google Photos authorization expired while downloading this selection. Reconnect Google Photos, then retry unavailable items."
                    let remaining = picked[index...].map { GoogleDownloadFailure(item: $0, category: .authorization, reason: reason) }
                    failures.append(contentsOf: remaining)
                    break
                }
                let classified = classifyDownloadFailure(error, item: item)
                failures.append(GoogleDownloadFailure(item: item, category: classified.category, reason: classified.reason))
            }
        }
        setDownloadProgress(progress, completed: picked.count, total: picked.count)
        return GoogleDownloadResult(records: result, failures: failures)
    }

    private nonisolated static func isAuthorizationFailure(_ error: Error) -> Bool {
        guard let googleError = error as? GooglePhotosError else { return false }
        switch googleError {
        case .authorizationFailed: return true
        case .http(status: 401, message: _): return true
        default: return false
        }
    }

    private func download(_ item: PickedMediaItem) async throws -> GoogleMediaRecord {
        let kind: MediaKind
        switch item.type.uppercased() {
        case "PHOTO": kind = .photo
        case "VIDEO": kind = .video
        default: throw GooglePhotosError.importFailed("Google returned an unsupported media type (\(item.type)).")
        }
        guard !item.mediaFile.baseUrl.isEmpty else {
            throw GooglePhotosError.importFailed("Google returned no download URL for this media item.")
        }
        if let mimeType = item.mediaFile.mimeType?.lowercased(), !mimeType.isEmpty {
            let isSupportedMIME = kind == .photo ? mimeType.hasPrefix("image/") : mimeType.hasPrefix("video/")
            guard isSupportedMIME else {
                throw GooglePhotosError.importFailed("Google returned an unsupported \(mimeType) media file.")
            }
        }
        let suffix = kind == .video ? "=dv" : "=d"
        guard let url = URL(string: item.mediaFile.baseUrl + suffix) else {
            throw GooglePhotosError.importFailed("Google returned an invalid media URL.")
        }
        var attempt = 0
        while true {
            do {
                let token = try await validAccessToken(interactive: false)
                var request = URLRequest(url: url)
                request.timeoutInterval = 180
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let (temporaryURL, response) = try await session.download(for: request)
                defer { try? fileManager.removeItem(at: temporaryURL) }
                // URLSession writes HTTP error bodies to the temporary file for
                // download requests.  Preserve that body when validating a
                // failed response so Google quota/access/processing messages
                // survive classification instead of becoming only "forbidden"
                // or "not found".  Do not load successful media into memory.
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    let errorBody = (try? Data(contentsOf: temporaryURL)) ?? Data()
                    try validate(response, data: errorBody)
                } else {
                    try validate(response, data: Data())
                }
                let values = try temporaryURL.resourceValues(forKeys: [.fileSizeKey])
                guard let fileSize = values.fileSize, fileSize > 0 else {
                    throw GooglePhotosError.importFailed("Google returned an empty media file.")
                }
                try await Self.validateDownloadedMedia(at: temporaryURL, kind: kind)
                let hash = try hashFile(at: temporaryURL)
                let safeName = (item.mediaFile.filename?.isEmpty == false ? item.mediaFile.filename! : "\(item.id).\(kind == .video ? "mp4" : "jpg")").safeFilename
                let relative = GoogleMediaStoragePathPolicy.relativePath(
                    sanitizedGoogleID: item.id.safeFilename,
                    sanitizedFilename: safeName,
                    contentHash: hash
                )
                let destination = mediaRoot.appendingPathComponent(relative)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: destination.path) {
                    // A content-addressed path may already be referenced by a
                    // prior successful session. Reuse only verified bytes and
                    // never overwrite that last-known-good file before the
                    // updated album metadata has committed.
                    guard try hashFile(at: destination) == hash else {
                        throw GooglePhotosError.importFailed("Canvas found conflicting local media bytes and preserved the existing file.")
                    }
                } else {
                    try fileManager.moveItem(at: temporaryURL, to: destination)
                }
                let metadata = item.mediaFile.mediaFileMetadata
                return GoogleMediaRecord(googleID: item.id, kind: kind, creationDate: Self.parseDate(item.createTime), filename: safeName, pixelWidth: metadata?.width ?? 0, pixelHeight: metadata?.height ?? 0, relativePath: relative, contentHash: hash)
            } catch {
                if error is CancellationError { throw error }
                if let googleError = error as? GooglePhotosError, case .http(status: 401, message: _) = googleError { throw error }
                let limit = retryLimit(for: error, kind: kind)
                guard attempt < limit else { throw error }
                let delay = retryDelay(for: error, attempt: attempt)
                attempt += 1
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func setDownloadProgress(_ progress: GoogleDownloadProgress, completed: Int, total: Int) {
        switch progress {
        case .initial: state = .syncing(completed: completed, total: total)
        case .retry: state = .retrying(completed: completed, total: total)
        }
    }

    private func retryLimit(for error: Error, kind: MediaKind) -> Int {
        if let googleError = error as? GooglePhotosError, case .http(let status, let message) = googleError {
            let lower = message.lowercased()
            if status == 429 || (status == 403 && (lower.contains("rate") || lower.contains("quota") || lower.contains("resource_exhausted"))) || status == 408 || status == 425 || (500...599).contains(status) { return 3 }
            if kind == .video && (status == 400 || status == 404 || status == 409) { return 1 }
            return 0
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed, .secureConnectionFailed:
                return 2
            default: return 0
            }
        }
        return 0
    }

    private func retryDelay(for error: Error, attempt: Int) -> Double {
        if let googleError = error as? GooglePhotosError, case .http(let status, let message) = googleError {
            let lower = message.lowercased()
            if status == 429 || (status == 403 && (lower.contains("rate") || lower.contains("quota") || lower.contains("resource_exhausted"))) {
                return [2.0, 5.0, 10.0][min(attempt, 2)]
            }
        }
        return [1.0, 3.0, 7.0][min(attempt, 2)]
    }

    private func classifyDownloadFailure(_ error: Error, item: PickedMediaItem) -> (category: GoogleImportFailureCategory, reason: String) {
        if let googleError = error as? GooglePhotosError {
            switch googleError {
            case .http(let status, let message):
                switch status {
                case 401: return (.authorization, "Google authorization expired (HTTP 401).")
                case 403:
                    let lower = message.lowercased()
                    if lower.contains("rate") || lower.contains("quota") || lower.contains("resource_exhausted") {
                        return (.rateLimited, message.isEmpty ? "Google rate-limited this download (HTTP 403)." : message)
                    }
                    return (.accessDenied, "Google denied access to this media (HTTP 403).")
                case 404, 410:
                    return (item.type.uppercased() == "VIDEO" ? .processing : .notFound, message)
                case 408, 425, 429, 500...599: return (status == 429 ? .rateLimited : .transientNetwork, message)
                default: return (.unknown, message)
                }
            case .importFailed(let message):
                let lower = message.lowercased()
                if lower.contains("unsupported") { return (.unsupported, message) }
                if lower.contains("empty") || lower.contains("invalid media") { return (.invalidMedia, message) }
                return (.unknown, message)
            case .authorizationFailed(let message): return (.authorization, message)
            default: return (.unknown, googleError.localizedDescription)
            }
        }
        if let urlError = error as? URLError {
            return (.transientNetwork, "Network error \(urlError.code.rawValue): \(urlError.localizedDescription)")
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain || nsError.domain == NSPOSIXErrorDomain {
            return (.storage, nsError.localizedDescription)
        }
        return (.unknown, error.localizedDescription)
    }

    private func refreshedFailedItems(for pending: PendingGoogleImport) async throws -> [PickedMediaItem] {
        do {
            let latest = try await listPickedItemsWithRetry(sessionID: pending.sessionID)
            let failedIDs = Set(pending.failedItems.map(\.id))
            let refreshed = uniquePickedItems(latest).filter { failedIDs.contains($0.id) }
            return GoogleFailedItemRefreshPolicy.merging(
                refreshed: refreshed,
                into: pending.failedItems,
                id: \.id
            )
        } catch let error as GooglePhotosError {
            if case .authorizationFailed = error { throw error }
            return pending.failedItems
        } catch {
            return pending.failedItems
        }
    }

    private func uniquePickedItems(_ items: [PickedMediaItem]) -> [PickedMediaItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    private func hashFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A successful HTTP response and a non-empty file are not enough: a
    /// proxy or expired media URL can still return bytes that are not a
    /// playable photo/video. Validate the temporary download before it can
    /// become a new content-versioned last-known-good file.
    nonisolated static func validateDownloadedMedia(at url: URL, kind: MediaKind) async throws {
        try Task.checkCancellation()
        switch kind {
        case .photo, .livePhoto:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  CGImageSourceGetCount(source) > 0,
                  CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
                throw GooglePhotosError.importFailed("Google returned invalid media bytes for a photo.")
            }
        case .video:
            let asset = AVURLAsset(url: url)
            do {
                let isPlayable = try await asset.load(.isPlayable)
                let tracks = try await asset.load(.tracks)
                guard isPlayable, !tracks.isEmpty else {
                    throw GooglePhotosError.importFailed("Google returned invalid media bytes for a video.")
                }
            } catch let error as GooglePhotosError {
                throw error
            } catch {
                throw GooglePhotosError.importFailed("Google returned invalid media bytes for a video.")
            }
        }
    }

    private func deletePickerSession(id: String) async throws {
        let token = try await validAccessToken(interactive: false)
        var request = URLRequest(url: URL(string: "https://photospicker.googleapis.com/v1/sessions/\(id)")!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
    }

    private func decode<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw GooglePhotosError.invalidResponse }
        guard 200..<300 ~= http.statusCode else {
            if http.statusCode == 401 {
                tokens = nil
                deleteTokens()
            }
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let error = object?["error"] as? [String: Any]
            let message = error?["message"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw GooglePhotosError.http(status: http.statusCode, message: "Google Photos: \(message)")
        }
    }

    private func mirrorAlbum(
        _ albumID: String,
        with mirrorService: GooglePhotosMirrorService,
        photoLibrary: PhotoLibraryService
    ) async -> GoogleApplePhotosMirrorSummary {
        guard let album = albums.first(where: { $0.id == albumID }) else {
            return GoogleApplePhotosMirrorSummary(
                albumTitle: "Apple Photos",
                addedCount: 0,
                alreadyMirroredCount: 0,
                failedCount: 0,
                preservedUserRemovalCount: 0,
                issue: "The saved Canvas album record could not be found.",
                retryAvailable: false
            )
        }
        let sourceURLs = Dictionary(uniqueKeysWithValues: album.items.map {
            ($0.googleID, mediaRoot.appendingPathComponent($0.relativePath))
        })
        do {
            let result = try await mirrorService.mirror(
                canvasAlbumID: album.id,
                title: album.title,
                records: album.items,
                sourceURLsByGoogleID: sourceURLs,
                photoLibrary: photoLibrary
            )
            let failedCount = result.failedGoogleIDs.count
            return GoogleApplePhotosMirrorSummary(
                albumTitle: album.title,
                addedCount: result.addedCount,
                alreadyMirroredCount: result.alreadyMirroredCount,
                failedCount: failedCount,
                preservedUserRemovalCount: result.tombstoneGoogleIDs.count,
                issue: failedCount == 0
                    ? nil
                    : "\(failedCount) item\(failedCount == 1 ? "" : "s") could not be copied. Retry the Apple Photos album without reopening Google’s Picker.",
                retryAvailable: failedCount > 0
            )
        } catch {
            let retryAvailable: Bool
            if let mirrorError = error as? GoogleApplePhotosMirrorError {
                switch mirrorError {
                case .managedAlbumRemoved:
                    retryAvailable = false
                default:
                    retryAvailable = true
                }
            } else if error is GooglePhotosMirrorIndexError {
                retryAvailable = false
            } else {
                retryAvailable = true
            }
            return GoogleApplePhotosMirrorSummary(
                albumTitle: album.title,
                addedCount: 0,
                alreadyMirroredCount: 0,
                failedCount: album.items.count,
                preservedUserRemovalCount: 0,
                issue: error.localizedDescription,
                retryAvailable: retryAvailable
            )
        }
    }

    // MARK: Persistence and matching

    private var applicationSupport: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Canvas", isDirectory: true)
    }
    private var mediaRoot: URL { applicationSupport.appendingPathComponent("Google Photos Media", isDirectory: true) }

    @discardableResult
    private func addToAlbum(title: String, records: [GoogleMediaRecord], matchedAppleAlbumID: String?) throws -> GoogleAlbumImportPlan {
        if let albumPersistenceError = albumPersistenceError {
            throw GooglePhotosError.albumPersistence(albumPersistenceError)
        }
        let plan = GoogleAlbumImportPolicy.adding(
            title: title,
            records: records,
            matchedAppleAlbumID: matchedAppleAlbumID,
            to: albums
        )
        let removablePaths: Set<String>
        if let replacedAlbumIndex = plan.replacedAlbumIndex {
            // A later Picker session is additive. Remove only a path superseded
            // by a newly downloaded record with the same stable Google ID, and
            // only when no other saved album still references that old path.
            removablePaths = GoogleAlbumMediaCleanup.pathsNoLongerReferenced(
                replacing: replacedAlbumIndex,
                with: plan.itemMerge.records,
                in: albums
            )
        } else {
            removablePaths = []
        }
        let previousAlbums = albums
        let previouslyReferencedPaths = Set(previousAlbums.flatMap { $0.items.map(\.relativePath) })
        albums = plan.albums
        guard saveAlbums() else {
            albums = previousAlbums
            // The album metadata did not commit, so remove only newly staged
            // content-addressed files. Existing referenced paths and bytes are
            // never touched on this failure path.
            let uncommittedPaths = GoogleAlbumMediaCleanup.pathsFromUncommittedDownloads(
                records,
                previouslyReferencedPaths: previouslyReferencedPaths
            )
            for path in uncommittedPaths {
                try? fileManager.removeItem(at: mediaRoot.appendingPathComponent(path))
            }
            throw GooglePhotosError.importFailed("Canvas downloaded the Google selection but could not preserve its album record. Check device storage and try again.")
        }
        // Commit metadata atomically before cleaning old paths. A persistence
        // failure therefore leaves every previously referenced file intact.
        for path in removablePaths {
            try? fileManager.removeItem(at: mediaRoot.appendingPathComponent(path))
        }
        return plan
    }

    @discardableResult
    private func saveAlbums() -> Bool {
        guard albumPersistenceError == nil else { return false }
        do {
            try albumsStore.persist(albums)
            return true
        } catch {
            if let persistenceError = error as? GoogleAlbumPersistenceError {
                albumPersistenceError = persistenceError
                state = .failed(persistenceError.localizedDescription)
            }
            return false
        }
    }
    private func removeFiles(for album: GoogleAlbumRecord) {
        for path in album.items.map(\.relativePath) { try? fileManager.removeItem(at: mediaRoot.appendingPathComponent(path)) }
    }

    /// Removes only files in Canvas's private Google-media root that are no
    /// longer reachable from a successfully persisted album document. This is
    /// deliberately separate from Apple Photos cleanup: it never touches a
    /// PHAsset or PHAssetCollection.
    private func removeUnreferencedMediaFiles() {
        guard fileManager.fileExists(atPath: mediaRoot.path) else { return }
        let referencedPaths = Set(albums.flatMap { $0.items.map(\.relativePath) })
        var storedPaths = Set<String>()
        if let enumerator = fileManager.enumerator(
            at: mediaRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let prefix = mediaRoot.path.hasSuffix("/") ? mediaRoot.path : mediaRoot.path + "/"
                guard fileURL.path.hasPrefix(prefix) else { continue }
                storedPaths.insert(String(fileURL.path.dropFirst(prefix.count)))
            }
        }
        let removable = GoogleAlbumMediaCleanup.unreferencedStoredPaths(
            storedRelativePaths: storedPaths,
            referencedPaths: referencedPaths
        )
        for path in removable {
            try? fileManager.removeItem(at: mediaRoot.appendingPathComponent(path))
        }
    }

    private func removeUncommittedFiles(for records: [GoogleMediaRecord]) {
        let referencedPaths = Set(albums.flatMap { $0.items.map(\.relativePath) })
        let removablePaths = GoogleAlbumMediaCleanup.pathsFromUncommittedDownloads(
            records,
            previouslyReferencedPaths: referencedPaths
        )
        for path in removablePaths {
            try? fileManager.removeItem(at: mediaRoot.appendingPathComponent(path))
        }
    }

    private func saveTokens(_ value: OAuthTokens) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        deleteTokens()
        SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: tokenService, kSecAttrAccount: "oauth", kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil)
    }
    private func loadTokens() -> OAuthTokens? {
        let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: tokenService, kSecAttrAccount: "oauth", kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary
        var result: CFTypeRef?
        guard SecItemCopyMatching(query, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(OAuthTokens.self, from: data)
    }
    private func deleteTokens() {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: tokenService, kSecAttrAccount: "oauth"] as CFDictionary)
    }

    private func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }
    private func duration(_ value: String?) -> Double? { value.flatMap { Double($0.dropLast($0.hasSuffix("s") ? 1 : 0)) } }
    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

/// New downloads are content-addressed so refreshing a stable Google media ID
/// can never overwrite the bytes referenced by the last committed album
/// record. Older relative paths remain valid and are cleaned only after a
/// successful additive metadata commit supersedes them.
enum GoogleMediaStoragePathPolicy {
    static func relativePath(
        sanitizedGoogleID: String,
        sanitizedFilename: String,
        contentHash: String
    ) -> String {
        let hash = GoogleApplePhotosMirrorIdentity.canonicalContentHash(contentHash)
        // Keep the 64-character version key in its own component so a valid
        // provider filename cannot become invalid merely because Canvas added
        // its content address in front of it.
        return "\(sanitizedGoogleID)/\(hash)/\(sanitizedFilename)"
    }
}

private extension Data {
    func base64URLEncodedString() -> String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}

private extension String {
    var formEncoded: String { addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? self }
    var safeFilename: String {
        let invalid = CharacterSet(charactersIn: "/\\:\0")
        let cleaned = components(separatedBy: invalid).joined(separator: "_")
        return cleaned.isEmpty ? UUID().uuidString : cleaned
    }
    var normalizedAlbumTitle: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }
}
