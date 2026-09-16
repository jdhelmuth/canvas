import XCTest
import UIKit
import AVFoundation
@testable import Canvas

@MainActor
final class PlaybackReliabilityTests: XCTestCase {
    private func item(_ id: String) -> CanvasMediaItem {
        CanvasMediaItem(id: id, source: .applePhotos, kind: .photo, creationDate: nil,
                        filename: "\(id).jpg", isFavorite: false, pixelWidth: 100, pixelHeight: 200,
                        albumTitle: "Test", appleAsset: nil, localURL: nil, contentHash: nil)
    }

    private var settings: CanvasSettings {
        var value = CanvasSettings()
        value.queueMode = .albumOrder
        value.layout = .single
        value.photoDuration = 100
        value.repeatEnabled = true
        value.shuffleEachLoop = false
        return value
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for playback", file: file, line: line)
    }

    func testUnavailablePrimaryImagesAreSkippedToNextPlayableItem() async {
        let items = [item("missing-a"), item("missing-b"), item("good")]
        var requests: [String] = []
        let model = PlaybackViewModel(settings: settings, mediaItems: { _ in items }, imageLoader: { item, _ in
            requests.append(item.id)
            return item.id == "good" ? UIImage() : nil
        })
        await model.reload()
        XCTAssertEqual(requests, ["missing-a", "missing-b", "good"])
        XCTAssertEqual(model.currentAsset?.id, "good")
        XCTAssertEqual(model.currentIndex, 2)
        XCTAssertFalse(model.isRecovering)
        XCTAssertNil(model.errorMessage)
        model.stop()
    }

    func testAllFailedPassIsBoundedAndKeepsLastGoodFrame() async {
        let items = [item("a"), item("b"), item("c")]
        var available = true
        var requests = 0
        let model = PlaybackViewModel(settings: settings, mediaItems: { _ in items }, imageLoader: { _, _ in
            requests += 1
            return available ? UIImage() : nil
        }, recoveryDelay: .seconds(60))
        await model.reload()
        let goodFrame = model.displayedFrame?.id
        available = false
        XCTAssertTrue(model.next())
        await waitUntil { model.isRecovering }
        XCTAssertEqual(requests, 4, "One initial load plus one visit per item, never an endless wrap")
        XCTAssertEqual(model.displayedFrame?.id, goodFrame)
        XCTAssertEqual(model.currentIndex, 0)
        XCTAssertNotNil(model.errorMessage)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(requests, 4)
        model.stop()
    }

    func testRecoveryRetriesWithoutUserNavigationAndRespectsGate() async {
        let items = [item("cloud")]
        var available = false
        var requests = 0
        let model = PlaybackViewModel(settings: settings, mediaItems: { _ in items }, imageLoader: { _, _ in
            requests += 1
            return available ? UIImage() : nil
        }, recoveryDelay: .milliseconds(30))
        await model.reload()
        XCTAssertTrue(model.isRecovering)
        XCTAssertNil(model.displayedFrame)
        model.setPlaybackAllowed(false)
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(requests, 1, "No retries while blocked by schedule/power")
        model.setPlaybackAllowed(true)
        await waitUntil { requests >= 2 }
        available = true
        await waitUntil { model.currentAsset?.id == "cloud" }
        XCTAssertFalse(model.isRecovering)
        XCTAssertNil(model.errorMessage)
        model.stop()
    }

    func testNonRepeatingRecoveryRetriesFailedDestinationWithoutReplayingPriorPhoto() async {
        let items = [item("shown"), item("pending")]
        var value = settings
        value.repeatEnabled = false
        var pendingAvailable = false
        var requests: [String] = []
        let model = PlaybackViewModel(settings: value, mediaItems: { _ in items }, imageLoader: { item, _ in
            requests.append(item.id)
            return item.id == "shown" || pendingAvailable ? UIImage() : nil
        }, recoveryDelay: .milliseconds(30))
        await model.reload()
        XCTAssertTrue(model.next())
        await waitUntil { requests.count >= 3 }
        XCTAssertEqual(requests.filter { $0 == "shown" }.count, 1)
        XCTAssertEqual(model.currentAsset?.id, "shown")
        pendingAvailable = true
        await waitUntil { model.currentAsset?.id == "pending" }
        XCTAssertFalse(model.isRecovering)
        model.stop()
    }

    func testStopInvalidatesInFlightProviderResultAndCannotRestart() async {
        let items = [item("slow")]
        var completion: CheckedContinuation<UIImage?, Never>?
        var requests = 0
        let model = PlaybackViewModel(settings: settings, mediaItems: { _ in items }, imageLoader: { _, _ in
            requests += 1
            return await withCheckedContinuation { completion = $0 }
        })
        let load = Task { await model.reload() }
        await waitUntil { completion != nil }
        model.stop()
        completion?.resume(returning: UIImage())
        await load.value
        model.setPlaybackAllowed(true)
        model.togglePlaying()
        await model.reload()
        XCTAssertNil(model.displayedFrame)
        XCTAssertEqual(model.queueCount, 0)
        XCTAssertEqual(requests, 1)
    }

    func testStoppedModelReleasesAndDoesNotAdvanceAfterDismissal() async {
        let items = [item("a"), item("b")]
        var shortSettings = settings
        shortSettings.photoDuration = 1
        var requests = 0
        var model: PlaybackViewModel? = PlaybackViewModel(settings: shortSettings, mediaItems: { _ in items }, imageLoader: { _, _ in
            requests += 1
            return UIImage()
        })
        await model?.reload()
        // Let the timer enter its first suspension before ending the session.
        await Task.yield()
        weak var released = model
        model?.stop()
        model = nil
        await waitUntil { released == nil }
        try? await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(requests, 1)
    }

    func testTimerDoesNotOwnModelAcrossItsSleep() async {
        let items = [item("a")]
        var model: PlaybackViewModel? = PlaybackViewModel(settings: settings, mediaItems: { _ in items }, imageLoader: { _, _ in UIImage() })
        await model?.reload()
        try? await Task.sleep(for: .milliseconds(10))
        weak var released = model
        model = nil
        await waitUntil { released == nil }
    }

    func testNonRepeatingStillSlideshowFinishesInPausedState() async {
        var value = settings
        value.repeatEnabled = false
        let items = [item("last")]
        let model = PlaybackViewModel(settings: value, mediaItems: { _ in items }, imageLoader: { _, _ in UIImage() })
        await model.reload()
        XCTAssertFalse(model.next())
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.currentAsset?.id, "last")
        model.stop()
    }

    func testOptimizedGroupsKeepBoundariesAndNeighborSemantics() {
        let portrait = CGSize(width: 100, height: 200)
        let landscape = CGSize(width: 200, height: 100)
        let sizes = [portrait, portrait, landscape, portrait, portrait, portrait, portrait]
        let canvas = CGSize(width: 1366, height: 1024)
        let singles: Set<Int> = [4]
        XCTAssertEqual(PlaybackGroupResolver.groupStarts(imageSizes: sizes, layout: .automatic, canvasSize: canvas, singleMediaIndices: singles), [0, 2, 3, 4, 5])
        for (current, expected) in [(0, 2), (1, 2), (2, 3), (3, 4), (4, 5), (5, 0), (6, 0)] {
            XCTAssertEqual(PlaybackGroupResolver.nextGroupIndex(imageSizes: sizes, currentIndex: current, direction: 1, layout: .automatic, canvasSize: canvas, repeatEnabled: true, singleMediaIndices: singles), expected)
        }
        XCTAssertEqual(PlaybackGroupResolver.nextGroupIndex(imageSizes: sizes, currentIndex: 6, direction: -1, layout: .automatic, canvasSize: canvas, repeatEnabled: false, singleMediaIndices: singles), 4)
    }
}

private final class TestAudioPlayer: CanvasAudioPlayer {
    var volume: Float = 0
    var currentTime: TimeInterval = 0
    var starts = 0
    var pauses = 0
    func play() -> Bool { starts += 1; return true }
    func pause() { pauses += 1 }
    func stop() {}
}

@MainActor
final class AudioReliabilityTests: XCTestCase {
    private func service(players: [TestAudioPlayer], shuffle: Bool = false, repeatEnabled: Bool = true) -> AudioService {
        var next = 0
        let service = AudioService(playerFactory: { _ in
            defer { next += 1 }
            return players[next]
        }, activateSession: { _ in })
        var settings = CanvasSettings()
        settings.backgroundAudio = .localFiles
        settings.videoMuted = false
        settings.audioShuffle = shuffle
        settings.audioRepeat = repeatEnabled
        settings.audioFileURLs = players.indices.map { URL(fileURLWithPath: "/tmp/track-\($0).wav") }
        service.configure(settings)
        return service
    }

    func testGateBlocksStartAndResumesTheSameTrack() {
        let players = [TestAudioPlayer(), TestAudioPlayer()]
        let audio = service(players: players)
        audio.start()
        XCTAssertFalse(audio.isPlaying)
        XCTAssertEqual(players[0].starts, 0)
        audio.setPlaybackAllowed(true)
        XCTAssertTrue(audio.isPlaying)
        XCTAssertEqual(players[0].starts, 1)
        players[0].currentTime = 12
        audio.setPlaybackAllowed(false)
        XCTAssertFalse(audio.isPlaying)
        audio.setPlaybackAllowed(true)
        XCTAssertEqual(players[0].starts, 2)
        XCTAssertEqual(players[0].currentTime, 12)
        XCTAssertEqual(players[1].starts, 0)
        audio.stop()
    }

    func testInterruptionCannotResumeAfterCloseOrBypassSchedule() {
        let player = TestAudioPlayer()
        let audio = service(players: [player])
        audio.setPlaybackAllowed(true)
        audio.start()
        audio.handleInterruption(.began)
        audio.setPlaybackAllowed(false)
        audio.handleInterruption(.ended, options: .shouldResume)
        XCTAssertFalse(audio.isPlaying)
        XCTAssertEqual(player.starts, 1)
        audio.setPlaybackAllowed(true)
        XCTAssertEqual(player.starts, 2)
        audio.handleInterruption(.began)
        audio.stop()
        audio.handleInterruption(.ended, options: .shouldResume)
        XCTAssertFalse(audio.isPlaying)
        XCTAssertEqual(player.starts, 2)
    }

    func testInterruptionRequiresSystemResumePermission() {
        let player = TestAudioPlayer()
        let audio = service(players: [player])
        audio.setPlaybackAllowed(true)
        audio.start()
        audio.handleInterruption(.began)
        audio.handleInterruption(.ended)
        XCTAssertFalse(audio.isPlaying)
        XCTAssertEqual(player.starts, 1)
    }

    func testRepeatOffPlaysEntirePlaylistExactlyOnce() {
        let players = [TestAudioPlayer(), TestAudioPlayer(), TestAudioPlayer()]
        let audio = service(players: players, repeatEnabled: false)
        audio.setPlaybackAllowed(true)
        audio.start()
        for player in players {
            XCTAssertTrue(audio.isPlaying)
            XCTAssertEqual(player.starts, 1)
            audio.handleFinished(for: player)
        }
        XCTAssertFalse(audio.isPlaying)
        XCTAssertEqual(players.map(\.starts), [1, 1, 1])
        // A stale callback and later gate reopening cannot restart a completed playlist.
        audio.handleFinished(for: players[0])
        audio.setPlaybackAllowed(false)
        audio.setPlaybackAllowed(true)
        XCTAssertEqual(players.map(\.starts), [1, 1, 1])
    }

    func testShuffleWithoutRepeatStillVisitsEveryTrackOnce() {
        let players = (0..<8).map { _ in TestAudioPlayer() }
        let audio = service(players: players, shuffle: true, repeatEnabled: false)
        audio.setPlaybackAllowed(true)
        audio.start()
        var completed = Set<Int>()
        for _ in players.indices {
            guard let playing = players.indices.first(where: { players[$0].starts == 1 && !completed.contains($0) }) else {
                return XCTFail("Shuffle repeated or skipped a track")
            }
            completed.insert(playing)
            audio.handleFinished(for: players[playing])
        }
        XCTAssertEqual(completed.count, players.count)
        XCTAssertEqual(players.map(\.starts), Array(repeating: 1, count: players.count))
        XCTAssertFalse(audio.isPlaying)
    }
}
