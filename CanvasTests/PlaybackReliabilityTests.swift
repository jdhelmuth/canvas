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

    func testRotationLoadsNewVisibleCompanionBeforeNextCanSkipIt() async {
        var value = settings
        value.layout = .automatic
        value.repeatEnabled = false
        let items = [item("a"), item("b"), item("c")]
        let model = PlaybackViewModel(settings: value, mediaItems: { _ in items }, imageLoader: { _, _ in UIImage() })
        defer { model.stop() }
        model.updateCanvasSize(CGSize(width: 1024, height: 1366))
        await model.reload()
        XCTAssertEqual(model.layoutAssets.map(\.id), ["a"])

        model.updateCanvasSize(CGSize(width: 1366, height: 1024))
        await waitUntil { model.layoutAssets.map(\.id) == ["a", "b"] }
        XCTAssertEqual(model.currentIndex, 0)
        XCTAssertTrue(model.next())
        await waitUntil { model.currentAsset?.id == "c" }
    }

    func testRotationWhileGatedRefreshesGroupWhenPlaybackBecomesAllowed() async {
        var value = settings
        value.layout = .automatic
        let items = [item("a"), item("b"), item("c")]
        var requests = 0
        let model = PlaybackViewModel(settings: value, mediaItems: { _ in items }, imageLoader: { _, _ in
            requests += 1
            return UIImage()
        })
        defer { model.stop() }
        model.updateCanvasSize(CGSize(width: 1024, height: 1366))
        await model.reload()
        model.togglePlaying()
        model.setPlaybackAllowed(false)
        model.updateCanvasSize(CGSize(width: 1366, height: 1024))
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(requests, 1)
        model.setPlaybackAllowed(true)
        await waitUntil { model.layoutAssets.map(\.id) == ["a", "b"] }
        XCTAssertFalse(model.isPlaying, "Rotation must preserve the person's pause preference")
    }

    func testRotationWhileGatedSurvivesLibraryRefreshBeforeResume() async {
        var value = settings
        value.layout = .automatic
        value.repeatEnabled = false
        let items = [item("a"), item("b"), item("c")]
        var requests: [String] = []
        let model = PlaybackViewModel(settings: value, mediaItems: { _ in items }, imageLoader: { item, _ in
            requests.append(item.id)
            return UIImage()
        })
        defer { model.stop() }
        model.updateCanvasSize(CGSize(width: 1024, height: 1366))
        await model.reload()
        model.togglePlaying()
        model.setPlaybackAllowed(false)
        model.updateCanvasSize(CGSize(width: 1366, height: 1024))

        await model.refreshLibrary()
        XCTAssertEqual(requests, ["a"], "A library notification must not load photos while playback is gated")
        XCTAssertEqual(model.layoutAssets.map(\.id), ["a"])
        model.setPlaybackAllowed(true)
        XCTAssertFalse(model.next(), "Resume must publish the pending pair before navigation can skip its companion")
        await waitUntil { model.layoutAssets.map(\.id) == ["a", "b"] }
        XCTAssertEqual(model.currentIndex, 0)
        XCTAssertFalse(model.isPlaying)
        XCTAssertTrue(model.next())
        await waitUntil { model.currentAsset?.id == "c" }
    }

    func testGatedSettingsReloadSurvivesRefreshAndDoesNotReuseImageAfterRotation() async {
        var value = settings
        value.repeatEnabled = false
        let items = [item("a"), item("b"), item("c")]
        let originalImage = UIImage()
        let refreshedImage = UIImage()
        var primaryImage = originalImage
        var primaryRequests = 0
        let model = PlaybackViewModel(settings: value, mediaItems: { _ in items }, imageLoader: { item, _ in
            if item.id == "a" {
                primaryRequests += 1
                return primaryImage
            }
            return UIImage()
        })
        defer { model.stop() }
        model.updateCanvasSize(CGSize(width: 1024, height: 1366))
        await model.reload()
        model.togglePlaying()
        model.setPlaybackAllowed(false)
        primaryImage = refreshedImage
        value.layout = .automatic
        await model.updateSettings(value)
        await model.refreshLibrary()
        model.updateCanvasSize(CGSize(width: 1366, height: 1024))
        XCTAssertEqual(primaryRequests, 1)
        XCTAssertTrue(model.currentImage === originalImage)

        model.setPlaybackAllowed(true)
        XCTAssertFalse(model.next())
        await waitUntil { model.layoutAssets.map(\.id) == ["a", "b"] }
        XCTAssertTrue(model.currentImage === refreshedImage, "Rotation must not reuse an image invalidated by a full settings reload")
        XCTAssertEqual(primaryRequests, 2)
        XCTAssertFalse(model.isPlaying)
        XCTAssertTrue(model.next())
        await waitUntil { model.currentAsset?.id == "c" }
    }

    func testRotationBlocksImmediateNextUntilNewCompanionIsVisible() async {
        var value = settings
        value.layout = .automatic
        value.repeatEnabled = false
        let items = [item("a"), item("b"), item("c")]
        var companionCompletion: CheckedContinuation<UIImage?, Never>?
        let model = PlaybackViewModel(settings: value, mediaItems: { _ in items }, imageLoader: { item, _ in
            if item.id == "b" {
                return await withCheckedContinuation { companionCompletion = $0 }
            }
            return UIImage()
        })
        defer {
            model.stop()
            companionCompletion?.resume(returning: nil)
        }
        model.updateCanvasSize(CGSize(width: 1024, height: 1366))
        await model.reload()
        let originalFrame = model.displayedFrame?.id

        model.updateCanvasSize(CGSize(width: 1366, height: 1024))
        XCTAssertFalse(model.next(), "A swipe cannot skip a companion that has not appeared yet")
        XCTAssertTrue(model.isPlaying, "Waiting for rotation must not pause the slideshow")
        XCTAssertEqual(model.currentIndex, 0)
        await waitUntil { companionCompletion != nil }
        XCTAssertEqual(model.displayedFrame?.id, originalFrame)
        XCTAssertEqual(model.layoutAssets.map(\.id), ["a"])
        XCTAssertFalse(model.next())

        companionCompletion?.resume(returning: UIImage())
        companionCompletion = nil
        await waitUntil { model.layoutAssets.map(\.id) == ["a", "b"] }
        XCTAssertTrue(model.next())
        await waitUntil { model.currentAsset?.id == "c" }
    }

    func testRotatingBackRejectsLateCompanionAndRestoresNavigation() async {
        var value = settings
        value.layout = .automatic
        value.repeatEnabled = false
        let items = [item("a"), item("b"), item("c")]
        var companionCompletion: CheckedContinuation<UIImage?, Never>?
        var delayCompanion = true
        var companionReturned = false
        let model = PlaybackViewModel(settings: value, mediaItems: { _ in items }, imageLoader: { item, _ in
            if item.id == "b", delayCompanion {
                let image = await withCheckedContinuation { companionCompletion = $0 }
                companionReturned = true
                return image
            }
            return UIImage()
        })
        defer {
            model.stop()
            companionCompletion?.resume(returning: nil)
        }
        model.updateCanvasSize(CGSize(width: 1024, height: 1366))
        await model.reload()
        model.updateCanvasSize(CGSize(width: 1366, height: 1024))
        await waitUntil { companionCompletion != nil }
        guard let pendingCompanion = companionCompletion else { return }

        model.updateCanvasSize(CGSize(width: 1024, height: 1366))
        delayCompanion = false
        companionCompletion = nil
        pendingCompanion.resume(returning: UIImage())
        await waitUntil { companionReturned }
        XCTAssertEqual(model.layoutAssets.map(\.id), ["a"], "A stale landscape load must not add a hidden companion")
        XCTAssertEqual(model.currentIndex, 0)
        XCTAssertTrue(model.isPlaying)
        XCTAssertTrue(model.next(), "Returning to the original layout must clear the pending regroup")
        await waitUntil { model.currentAsset?.id == "b" }
        XCTAssertEqual(model.layoutAssets.map(\.id), ["b"])
    }

    func testRotationAtOddIndexAdvancesPastTheActualVisiblePair() async {
        var value = settings
        value.layout = .automatic
        value.repeatEnabled = false
        let items = [item("a"), item("b"), item("c"), item("d")]
        let model = PlaybackViewModel(settings: value, mediaItems: { _ in items }, imageLoader: { _, _ in UIImage() })
        defer { model.stop() }
        model.updateCanvasSize(CGSize(width: 1024, height: 1366))
        await model.reload()
        XCTAssertTrue(model.next())
        await waitUntil { model.currentAsset?.id == "b" }
        XCTAssertEqual(model.currentIndex, 1)

        model.updateCanvasSize(CGSize(width: 1366, height: 1024))
        await waitUntil { model.layoutAssets.map(\.id) == ["b", "c"] }
        XCTAssertEqual(model.currentIndex, 1, "Rotation must retain the person's current primary photo")
        XCTAssertTrue(model.next())
        await waitUntil { model.currentAsset?.id == "d" }
        XCTAssertEqual(model.currentIndex, 3)
        XCTAssertFalse(model.next())
        XCTAssertFalse(model.isPlaying)
    }

    func testResizeWithUnchangedGroupPreservesFrameWithoutLoadingAgain() async {
        var value = settings
        value.layout = .automatic
        let items = [item("a"), item("b"), item("c")]
        var requests = 0
        let model = PlaybackViewModel(settings: value, mediaItems: { _ in items }, imageLoader: { _, _ in
            requests += 1
            return UIImage()
        })
        defer { model.stop() }
        model.updateCanvasSize(CGSize(width: 1024, height: 1366))
        await model.reload()
        let originalFrame = model.displayedFrame?.id

        model.updateCanvasSize(CGSize(width: 800, height: 1200))
        model.updateCanvasSize(CGSize(width: 900, height: 1300))
        model.updateCanvasSize(CGSize(width: 900, height: 1300))
        model.updateCanvasSize(.zero)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.displayedFrame?.id, originalFrame)
        XCTAssertEqual(model.layoutAssets.map(\.id), ["a"])
        XCTAssertEqual(requests, 1, "Resizing the same visible group should not request its photos again")
        XCTAssertTrue(model.isPlaying)
    }

    func testRotationPreservesElapsedTimeAndProgressWhilePaused() async {
        var value = settings
        value.layout = .automatic
        let items = [item("a"), item("b"), item("c")]
        let model = PlaybackViewModel(settings: value, mediaItems: { _ in items }, imageLoader: { _, _ in UIImage() })
        defer { model.stop() }
        model.updateCanvasSize(CGSize(width: 1024, height: 1366))
        await model.reload()
        await waitUntil { model.elapsed > 0 }
        model.togglePlaying()
        let pausedElapsed = model.elapsed
        let pausedProgress = model.progress

        model.updateCanvasSize(CGSize(width: 1366, height: 1024))
        await waitUntil { model.layoutAssets.map(\.id) == ["a", "b"] }
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.elapsed, pausedElapsed, accuracy: 0.001)
        XCTAssertEqual(model.progress, pausedProgress, accuracy: 0.00001)
        XCTAssertEqual(model.currentAsset?.id, "a")
    }

    func testRotationDuringFirstLoadRejectsStalePrimaryAndPreservesInitialHistory() async {
        var value = settings
        value.layout = .automatic
        value.repeatEnabled = false
        let items = [item("a"), item("b"), item("c")]
        let currentImage = UIImage()
        var primaryRequests = 0
        var firstPrimaryCompletion: CheckedContinuation<UIImage?, Never>?
        let model = PlaybackViewModel(settings: value, mediaItems: { _ in items }, imageLoader: { item, _ in
            if item.id == "a" {
                primaryRequests += 1
                if primaryRequests == 1 {
                    return await withCheckedContinuation { firstPrimaryCompletion = $0 }
                }
                return currentImage
            }
            return UIImage()
        })
        defer {
            model.stop()
            firstPrimaryCompletion?.resume(returning: nil)
        }
        model.updateCanvasSize(CGSize(width: 1024, height: 1366))
        let initialLoad = Task { await model.reload() }
        await waitUntil { firstPrimaryCompletion != nil }
        XCTAssertNil(model.displayedFrame)

        model.updateCanvasSize(CGSize(width: 1366, height: 1024))
        await waitUntil { model.layoutAssets.map(\.id) == ["a", "b"] }
        let rotatedFrame = model.displayedFrame?.id
        XCTAssertTrue(model.currentImage === currentImage)

        // The original provider result deliberately ignores cancellation and
        // arrives after the complete landscape frame has been published.
        firstPrimaryCompletion?.resume(returning: UIImage())
        firstPrimaryCompletion = nil
        await initialLoad.value
        XCTAssertEqual(model.displayedFrame?.id, rotatedFrame)
        XCTAssertTrue(model.currentImage === currentImage)
        XCTAssertEqual(model.layoutAssets.map(\.id), ["a", "b"])
        XCTAssertTrue(model.next())
        await waitUntil { model.currentAsset?.id == "c" }
        XCTAssertTrue(model.previous())
        await waitUntil { model.currentAsset?.id == "a" }
        XCTAssertEqual(model.currentIndex, 0)
        XCTAssertEqual(model.layoutAssets.map(\.id), ["a", "b"])
    }

    func testFailedRotationCompanionDoesNotLoopOrKeepNavigationBlocked() async {
        var value = settings
        value.layout = .automatic
        value.repeatEnabled = false
        let items = [item("a"), item("b"), item("c")]
        var requests: [String] = []
        let model = PlaybackViewModel(settings: value, mediaItems: { _ in items }, imageLoader: { item, _ in
            requests.append(item.id)
            return item.id == "b" ? nil : UIImage()
        })
        defer { model.stop() }
        model.updateCanvasSize(CGSize(width: 1024, height: 1366))
        await model.reload()
        model.updateCanvasSize(CGSize(width: 1366, height: 1024))
        await waitUntil { requests.contains("b") }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.layoutAssets.map(\.id), ["a"])
        XCTAssertFalse(model.isRecovering, "A usable primary remains visible when its companion is unavailable")
        let settledRequests = requests

        model.updateCanvasSize(CGSize(width: 1300, height: 900))
        model.updateCanvasSize(CGSize(width: 1200, height: 800))
        model.setPlaybackAllowed(false)
        model.setPlaybackAllowed(true)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(requests, settledRequests, "A failed companion must not trigger repeated loads for the same group")
        XCTAssertEqual(requests.filter { $0 == "b" }.count, 1)
        XCTAssertTrue(model.isPlaying)
        XCTAssertTrue(model.next(), "A failed companion must release the pending rotation gate")
        await waitUntil { model.currentAsset?.id == "c" }
        XCTAssertFalse(model.isRecovering)
    }

    func testRotationDuringExhaustedReloadKeepsRecoveryUntilFreshImagesLoad() async {
        var value = settings
        value.layout = .automatic
        value.repeatEnabled = false
        let items = [item("a"), item("b"), item("c")]
        let originalImage = UIImage()
        let recoveredImage = UIImage()
        var availableImage: UIImage? = originalImage
        var requests: [String] = []
        let model = PlaybackViewModel(settings: value, mediaItems: { _ in items }, imageLoader: { item, _ in
            requests.append(item.id)
            return availableImage
        })
        defer { model.stop() }
        model.updateCanvasSize(CGSize(width: 1024, height: 1366))
        await model.reload()
        model.togglePlaying()
        let originalFrame = model.displayedFrame?.id
        availableImage = nil
        await model.reload(rebuildQueue: true)
        XCTAssertTrue(model.isRecovering)
        XCTAssertEqual(model.displayedFrame?.id, originalFrame)
        let requestsBeforeRotation = requests.count

        model.updateCanvasSize(CGSize(width: 1366, height: 1024))
        await waitUntil { requests.count >= requestsBeforeRotation + items.count }
        XCTAssertEqual(Array(requests.suffix(items.count)), ["a", "b", "c"])
        XCTAssertTrue(model.isRecovering, "Reusing an old primary during rotation must not count as successful recovery")
        XCTAssertEqual(model.displayedFrame?.id, originalFrame)
        XCTAssertTrue(model.currentImage === originalImage)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isPlaying)

        availableImage = recoveredImage
        model.setPlaybackAllowed(false)
        model.setPlaybackAllowed(true)
        await waitUntil { !model.isRecovering && model.layoutAssets.map(\.id) == ["a", "b"] }
        XCTAssertTrue(model.currentImage === recoveredImage)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isPlaying)
    }

    func testExhaustedRotationLoadReleasesNavigationWhilePaused() async {
        var value = settings
        value.layout = .automatic
        value.repeatEnabled = false
        let items = [item("a"), item("b"), item("c")]
        var firstPendingCompletion: CheckedContinuation<UIImage?, Never>?
        var pendingRequests = 0
        var pendingAvailable = false
        let model = PlaybackViewModel(settings: value, mediaItems: { _ in items }, imageLoader: { item, _ in
            if item.id == "a" { return UIImage() }
            if item.id == "b" {
                pendingRequests += 1
                if pendingRequests == 1 {
                    return await withCheckedContinuation { firstPendingCompletion = $0 }
                }
                return pendingAvailable ? UIImage() : nil
            }
            return nil
        })
        defer {
            model.stop()
            firstPendingCompletion?.resume(returning: nil)
        }
        model.updateCanvasSize(CGSize(width: 1024, height: 1366))
        await model.reload()
        model.togglePlaying()
        XCTAssertTrue(model.next())
        await waitUntil { firstPendingCompletion != nil }

        model.updateCanvasSize(CGSize(width: 1366, height: 1024))
        await waitUntil { model.isRecovering }
        XCTAssertEqual(model.currentAsset?.id, "a")
        XCTAssertEqual(model.currentIndex, 0)
        XCTAssertFalse(model.isPlaying)
        firstPendingCompletion?.resume(returning: nil)
        firstPendingCompletion = nil

        XCTAssertTrue(model.previous(), "An exhausted regroup must not block manual recovery through Back")
        await waitUntil { !model.isRecovering }
        XCTAssertEqual(model.currentAsset?.id, "a")
        pendingAvailable = true
        XCTAssertTrue(model.next(), "Manual Next must work after the rotation load has finished unsuccessfully")
        await waitUntil { model.currentAsset?.id == "b" }
        XCTAssertEqual(model.currentIndex, 1)
        XCTAssertFalse(model.isRecovering)
        XCTAssertFalse(model.isPlaying)
    }

    func testLibraryRefreshRejectsRemovedCompanionFromPendingRotation() async {
        var value = settings
        value.layout = .automatic
        value.repeatEnabled = false
        let a = item("a"), b = item("b"), c = item("c"), d = item("d")
        var items = [a, b, c, d]
        var companionCompletion: CheckedContinuation<UIImage?, Never>?
        var companionReturned = false
        let model = PlaybackViewModel(settings: value, mediaItems: { _ in items }, imageLoader: { item, _ in
            if item.id == "b" {
                let image = await withCheckedContinuation { companionCompletion = $0 }
                companionReturned = true
                return image
            }
            return UIImage()
        })
        defer {
            model.stop()
            companionCompletion?.resume(returning: nil)
        }
        model.updateCanvasSize(CGSize(width: 1024, height: 1366))
        await model.reload()
        model.updateCanvasSize(CGSize(width: 1366, height: 1024))
        await waitUntil { companionCompletion != nil }
        guard let pendingCompanion = companionCompletion else { return }

        items = [a, c, d]
        await model.refreshLibrary()
        await waitUntil { model.layoutAssets.map(\.id) == ["a", "c"] }
        let refreshedFrame = model.displayedFrame?.id
        companionCompletion = nil
        pendingCompanion.resume(returning: UIImage())
        await waitUntil { companionReturned }
        XCTAssertEqual(model.displayedFrame?.id, refreshedFrame)
        XCTAssertEqual(model.layoutAssets.map(\.id), ["a", "c"], "A removed companion must not reappear from an old rotation request")
        XCTAssertEqual(model.queueCount, 3)
        XCTAssertTrue(model.next())
        await waitUntil { model.currentAsset?.id == "d" }
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

@MainActor
final class FullShuffleTests: XCTestCase {
    private var settings: CanvasSettings {
        var value = CanvasSettings()
        value.queueMode = .shuffle
        value.layout = .single
        value.photoDuration = 1000
        value.shuffleEachLoop = true
        return value
    }

    private func items(_ count: Int) -> [CanvasMediaItem] {
        (0..<count).map { index in
            CanvasMediaItem(id: "apple:\(index)", source: .applePhotos, kind: .photo,
                creationDate: nil, filename: "\(index).jpg", isFavorite: false,
                pixelWidth: 100, pixelHeight: 200, albumTitle: "Album \(index % 3)",
                appleAsset: nil, localURL: nil, contentHash: nil, libraryID: "album-\(index % 3)")
        }
    }

    private func settle(_ model: PlaybackViewModel, after frame: UUID?) async {
        for _ in 0..<1000 {
            if model.displayedFrame?.id != frame || model.isRecovering { return }
            await Task.yield()
        }
        XCTFail("Playback failed to settle")
    }

    func testOver1300UniquePhotosAcrossOverlappingAlbumsAndRestart() async throws {
        let suite = "canvas-shuffle-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShuffleCycleStore(defaults: defaults)
        let all = items(1307)
        let overlapping = all + Array(all[100..<900]) + Array(all[800...])
        var value = settings
        var model = PlaybackViewModel(settings: value, mediaItems: { _ in overlapping },
                                      imageLoader: { _, _ in UIImage() }, cycleStore: store)
        defer { model.stop() }
        await model.reload()
        XCTAssertEqual(model.queueCount, 1307)
        var seen = Set<String>()
        for index in 0..<1307 {
            let id = try XCTUnwrap(model.currentAsset?.id)
            XCTAssertTrue(seen.insert(id).inserted, "Repeated \(id) at \(index)")
            if index == 503 {
                model.stop()
                // A new persistence object and model simulate process relaunch.
                model = PlaybackViewModel(settings: value, mediaItems: { _ in overlapping },
                    imageLoader: { _, _ in UIImage() }, cycleStore: ShuffleCycleStore(defaults: defaults))
                await model.reload()
            } else if index < 1306 {
                if index == 201 {
                    value.photoDuration = 2000
                    await model.updateSettings(value)
                    model.setPlaybackAllowed(false)
                    model.setPlaybackAllowed(true)
                    await model.refreshLibrary()
                }
                let old = model.displayedFrame?.id
                XCTAssertTrue(model.next())
                await settle(model, after: old)
            }
        }
        XCTAssertEqual(seen, Set(all.map(\.id)))
        let last = model.currentAsset?.id
        let old = model.displayedFrame?.id
        XCTAssertTrue(model.next())
        await settle(model, after: old)
        XCTAssertNotEqual(model.currentAsset?.id, last)
        XCTAssertEqual(store.load()?.displayedIDs.count, 1)
    }

    func testFailedCloudPhotosRemainPendingAcrossRestartUntilRecovered() async throws {
        let suite = "canvas-shuffle-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let all = items(31)
        let failed = Set(all.prefix(5).map(\.id))
        var available = false
        var model = PlaybackViewModel(settings: settings, mediaItems: { _ in all }, imageLoader: { item, _ in
            available || !failed.contains(item.id) ? UIImage() : nil
        }, cycleStore: ShuffleCycleStore(defaults: defaults))
        defer { model.stop() }
        await model.reload()
        var seen = Set<String>()
        for _ in 0..<26 {
            XCTAssertTrue(seen.insert(try XCTUnwrap(model.currentAsset?.id)).inserted)
            let old = model.displayedFrame?.id
            XCTAssertTrue(model.next())
            await settle(model, after: old)
        }
        XCTAssertTrue(model.isRecovering)
        XCTAssertEqual(seen.count, 26)
        XCTAssertEqual(ShuffleCycleStore(defaults: defaults).load()?.pendingIDs().count, 5)
        model.stop()
        available = true
        model = PlaybackViewModel(settings: settings, mediaItems: { _ in all },
            imageLoader: { _, _ in UIImage() }, cycleStore: ShuffleCycleStore(defaults: defaults))
        await model.reload()
        for index in 0..<5 {
            XCTAssertTrue(seen.insert(try XCTUnwrap(model.currentAsset?.id)).inserted)
            if index < 4 {
                let old = model.displayedFrame?.id
                XCTAssertTrue(model.next())
                await settle(model, after: old)
            }
        }
        XCTAssertEqual(seen, Set(all.map(\.id)))
    }

    func testFailedCompanionIsNotConsumedAndGetsItsOwnTurn() async throws {
        var value = settings
        value.layout = .pairHorizontal
        let all = items(7)
        var requests = 0
        var failedID: String?
        let model = PlaybackViewModel(settings: value, mediaItems: { _ in all }, imageLoader: { item, _ in
            requests += 1
            if requests == 2 { failedID = item.id; return nil }
            return UIImage()
        })
        defer { model.stop() }
        await model.reload()
        XCTAssertEqual(model.layoutAssets.count, 1)
        var seen = Set(model.layoutAssets.map(\.id))
        for _ in 0..<all.count {
            if seen.count >= all.count { break }
            let old = model.displayedFrame?.id
            XCTAssertTrue(model.next())
            await settle(model, after: old)
            for asset in model.layoutAssets { XCTAssertTrue(seen.insert(asset.id).inserted) }
        }
        XCTAssertEqual(seen.count, all.count)
        XCTAssertTrue(seen.contains(try XCTUnwrap(failedID)))
    }

    func testMembershipAndLayoutChangesPreserveSeenPhotos() async throws {
        var value = settings
        var all = items(20)
        let model = PlaybackViewModel(settings: value, mediaItems: { _ in all }, imageLoader: { _, _ in UIImage() })
        defer { model.stop() }
        await model.reload()
        var seen = Set<String>()
        for _ in 0..<8 {
            seen.insert(try XCTUnwrap(model.currentAsset?.id))
            let old = model.displayedFrame?.id
            XCTAssertTrue(model.next())
            await settle(model, after: old)
        }
        seen.formUnion(model.layoutAssets.map(\.id))
        let retained = model.currentAsset?.id
        all = all.filter { seen.contains($0.id) || $0.id != "apple:19" }
        all += Array(items(25).suffix(5))
        value.layout = .pairHorizontal
        value.selectedAlbums = [AlbumReference(id: "changed-selection", title: "Changed album", subtype: 0,
            estimatedCount: all.count, isSmart: false, isShared: false)]
        await model.updateSettings(value)
        XCTAssertEqual(model.currentAsset?.id, retained)
        for asset in model.layoutAssets where asset.id != retained {
            XCTAssertTrue(seen.insert(asset.id).inserted)
        }
        await model.refreshLibrary()
        for _ in 0..<all.count {
            if seen.intersection(Set(all.map(\.id))).count >= all.count { break }
            let old = model.displayedFrame?.id
            XCTAssertTrue(model.next())
            await settle(model, after: old)
            for asset in model.layoutAssets { XCTAssertTrue(seen.insert(asset.id).inserted) }
        }
        XCTAssertEqual(seen.intersection(Set(all.map(\.id))).count, all.count)
    }

    func testFullGroupedCycleAndBoundaryAvoidOutgoingTiles() async throws {
        var value = settings
        value.layout = .gridFour
        let all = items(1308)
        let model = PlaybackViewModel(settings: value, mediaItems: { _ in all }, imageLoader: { _, _ in UIImage() })
        defer { model.stop() }
        await model.reload()
        var seen = Set<String>()
        for _ in 0..<all.count {
            if seen.count >= all.count { break }
            for asset in model.layoutAssets { XCTAssertTrue(seen.insert(asset.id).inserted) }
            if seen.count < all.count {
                let old = model.displayedFrame?.id
                XCTAssertTrue(model.next())
                await settle(model, after: old)
            }
        }
        XCTAssertEqual(seen.count, all.count)
        let outgoing = Set(model.layoutAssets.map(\.id))
        let old = model.displayedFrame?.id
        XCTAssertTrue(model.next())
        await settle(model, after: old)
        XCTAssertTrue(outgoing.isDisjoint(with: model.layoutAssets.map(\.id)))
    }

    func testSuspendedLoadDoesNotConsumeUnpublishedPhoto() async throws {
        let suite = "canvas-shuffle-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShuffleCycleStore(defaults: defaults)
        let all = items(10)
        var completion: CheckedContinuation<UIImage?, Never>?
        var requests = 0
        let model = PlaybackViewModel(settings: settings, mediaItems: { _ in all }, imageLoader: { _, _ in
            requests += 1
            if requests == 1 { return await withCheckedContinuation { completion = $0 } }
            return UIImage()
        }, cycleStore: store)
        defer { model.stop() }
        let initial = Task { await model.reload() }
        for _ in 0..<1000 {
            if completion != nil { break }
            await Task.yield()
        }
        let pending = try XCTUnwrap(completion)
        model.setPlaybackAllowed(false)
        pending.resume(returning: UIImage())
        await initial.value
        XCTAssertNil(model.displayedFrame)
        XCTAssertEqual(store.load()?.displayedIDs.count, 0)
        XCTAssertEqual(store.load()?.pendingIDs().count, 10)
        model.setPlaybackAllowed(true)
        await settle(model, after: nil)
        XCTAssertEqual(store.load()?.displayedIDs.count, 1)
    }

    func testRepeatDisabledStopsAfterCompleteShuffle() async {
        var value = settings
        value.repeatEnabled = false
        let all = items(12)
        let model = PlaybackViewModel(settings: value, mediaItems: { _ in all }, imageLoader: { _, _ in UIImage() })
        defer { model.stop() }
        await model.reload()
        for _ in 1..<all.count {
            let old = model.displayedFrame?.id
            XCTAssertTrue(model.next())
            await settle(model, after: old)
        }
        XCTAssertFalse(model.next())
        XCTAssertFalse(model.isPlaying)
    }

    func testFailedDestinationDoesNotBecomeForwardHistoryAfterBack() async throws {
        let all = items(4)
        var permitted = Set<String>()
        var requests = 0
        let model = PlaybackViewModel(settings: settings, mediaItems: { _ in all }, imageLoader: { item, _ in
            requests += 1
            if permitted.count < 2 { permitted.insert(item.id) }
            return permitted.contains(item.id) ? UIImage() : nil
        })
        defer { model.stop() }
        await model.reload()
        let first = model.currentAsset?.id
        var old = model.displayedFrame?.id
        XCTAssertTrue(model.next())
        await settle(model, after: old)
        let second = model.currentAsset?.id
        XCTAssertNotEqual(first, second)
        old = model.displayedFrame?.id
        XCTAssertTrue(model.next())
        await settle(model, after: old)
        XCTAssertTrue(model.isRecovering)
        old = model.displayedFrame?.id
        XCTAssertTrue(model.previous())
        for _ in 0..<1000 {
            if model.currentAsset?.id == first && !model.isRecovering { break }
            await Task.yield()
        }
        XCTAssertEqual(model.currentAsset?.id, first)
        old = model.displayedFrame?.id
        XCTAssertTrue(model.next())
        await settle(model, after: old)
        XCTAssertEqual(model.currentAsset?.id, second)
        let frameBeforeFailure = model.displayedFrame?.id
        let countBeforeFailure = requests
        XCTAssertTrue(model.next())
        await settle(model, after: frameBeforeFailure)
        XCTAssertTrue(model.isRecovering)
        XCTAssertEqual(model.displayedFrame?.id, frameBeforeFailure)
        XCTAssertEqual(requests - countBeforeFailure, 2, "Retry only the two unseen photos")
    }

    func testCompletedNonRepeatingShuffleRestoresFinalPhotoPaused() async throws {
        let suite = "canvas-shuffle-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let all = items(3)
        let store = ShuffleCycleStore(defaults: defaults)
        var cycle = ShuffleCycle()
        cycle.reconcile(all)
        cycle.recordDisplayed(all.map(\.id))
        cycle.recordDisplayed([all.last!.id])
        store.save(cycle)
        var value = settings
        value.repeatEnabled = false
        let model = PlaybackViewModel(settings: value, mediaItems: { _ in all },
            imageLoader: { _, _ in UIImage() }, cycleStore: store)
        defer { model.stop() }
        await model.reload()
        XCTAssertEqual(model.currentAsset?.id, all.last?.id)
        XCTAssertFalse(model.isPlaying)
        XCTAssertFalse(model.next())
    }

    func testPhotoKitEnumerationHasNoFetchLimit() {
        XCTAssertEqual(PhotoLibraryService.assetFetchOptions(includeHidden: false).fetchLimit, 0)
    }
}

final class PhotoImageRequestTests: XCTestCase {
    func testCancellationBeforeRegistrationResumesAndCancelsLateRequest() async {
        let request = PhotoImageRequest()
        request.finish(.failure(CancellationError()))
        var cancellations = 0
        request.installCancellation { cancellations += 1 }
        do {
            let _: UIImage = try await withCheckedThrowingContinuation { request.install($0) }
            XCTFail("Cancelled request must throw")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(cancellations, 1)
    }

    func testLateCallbacksCannotResumeTwice() async throws {
        let request = PhotoImageRequest()
        let expected = UIImage()
        let image: UIImage = try await withCheckedThrowingContinuation {
            request.install($0)
            request.finish(.success(expected))
            request.finish(.failure(CancellationError()))
            request.finish(.success(UIImage()))
        }
        XCTAssertTrue(image === expected)
    }
}

@MainActor
final class ShuffleCycleStateTests: XCTestCase {
    private func item(_ id: String) -> CanvasMediaItem {
        CanvasMediaItem(id: id, source: .applePhotos, kind: .photo, creationDate: nil,
            filename: id, isFavorite: false, pixelWidth: 100, pixelHeight: 100,
            albumTitle: "Test", appleAsset: nil, localURL: nil, contentHash: nil)
    }

    func testBoundaryAfterRecoveryAvoidsScatteredOutgoingTilesWithoutReshuffling() {
        let all = ["a", "b", "c", "d", "e", "f"].map(item)
        let next = QueueBuilder.buildNextCycle(all, mode: .albumOrder, previousIDs: ["a", "c"])
        XCTAssertEqual(next.map(\.id), ["b", "d", "e", "f", "a", "c"])
    }

    func testRemoveAndReaddDoesNotForgetAlreadyShownIDs() {
        var cycle = ShuffleCycle()
        cycle.reconcile([item("a"), item("b"), item("c")])
        cycle.recordDisplayed(["b"])
        cycle.reconcile([item("c"), item("a"), item("d")])
        cycle.reconcile([item("b"), item("c"), item("a"), item("d")])
        XCTAssertEqual(cycle.pendingIDs(), ["a", "c", "d"])
    }

    func testEmptyProviderRefreshRetainsCoverage() {
        var cycle = ShuffleCycle()
        cycle.reconcile([item("a"), item("b")])
        cycle.recordDisplayed(["a"])
        cycle.reconcile([])
        cycle.reconcile([item("a"), item("b")])
        XCTAssertEqual(cycle.pendingIDs(), ["b"])
    }

    func testRefreshDuringRecoveryNeverReloadsAlreadyShownPhoto() async {
        var value = CanvasSettings()
        value.queueMode = .shuffle
        value.layout = .single
        value.photoDuration = 1000
        let all = [item("a"), item("b")]
        var shown: String?
        var requests: [String] = []
        let model = PlaybackViewModel(settings: value, mediaItems: { _ in all }, imageLoader: { item, _ in
            requests.append(item.id)
            return shown == nil || shown == item.id ? UIImage() : nil
        })
        defer { model.stop() }
        await model.reload()
        shown = model.currentAsset?.id
        XCTAssertTrue(model.next())
        for _ in 0..<1000 {
            if model.isRecovering { break }
            await Task.yield()
        }
        XCTAssertTrue(model.isRecovering)
        requests = []
        await model.refreshLibrary()
        XCTAssertTrue(model.isRecovering)
        XCTAssertFalse(requests.contains(shown!))
    }
}
