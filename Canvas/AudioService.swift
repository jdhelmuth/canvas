import AVFoundation
import Foundation

enum AudioPlaybackIndexPolicy {
    static func clampedIndex(_ index: Int, playerCount: Int) -> Int? {
        guard playerCount > 0 else { return nil }
        return min(max(index, 0), playerCount - 1)
    }

    static func nextSequentialIndex(after index: Int, playerCount: Int) -> Int? {
        guard playerCount > 0 else { return nil }
        return (index + 1) % playerCount
    }
}

/// The same playback operations serve real audio files and deterministic
/// lifecycle tests without needing to activate the device audio session.
protocol CanvasAudioPlayer: AnyObject {
    var volume: Float { get set }
    var currentTime: TimeInterval { get set }
    @discardableResult func play() -> Bool
    func pause()
    func stop()
}

extension AVAudioPlayer: CanvasAudioPlayer {}

@MainActor
final class AudioService: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    private var players: [any CanvasAudioPlayer] = []
    private var order: [Int] = []
    private var orderPosition = 0
    private var playlistFinished = false
    private var settings: CanvasSettings = .init()
    private var playbackAllowed = false
    private var ownsActiveSession = false
    private var wantsPlayback = false
    private var interrupted = false
    private var resumeAfterInterruption = false
    private let playerFactory: (URL) -> (any CanvasAudioPlayer)?
    private let activateSession: (Bool) -> Void
    private var interruptionObserver: NSObjectProtocol?

    init(
        playerFactory: @escaping (URL) -> (any CanvasAudioPlayer)? = { try? AVAudioPlayer(contentsOf: $0) },
        activateSession: @escaping (Bool) -> Void = { active in
            let session = AVAudioSession.sharedInstance()
            if active { try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers]) }
            try? session.setActive(active, options: active ? [] : .notifyOthersOnDeactivation)
        }
    ) {
        self.playerFactory = playerFactory
        self.activateSession = activateSession
        super.init()
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: value) else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            Task { @MainActor [weak self] in self?.handleInterruption(type, options: options) }
        }
    }

    deinit { if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) } }

    func configure(_ settings: CanvasSettings) {
        stop()
        self.settings = settings
        players = settings.audioFileURLs.compactMap { playerFactory(CanvasAudioFileStore.playbackURL(for: $0)) }
        for player in players {
            if let player = player as? AVAudioPlayer {
                player.delegate = self
                player.prepareToPlay()
            }
            player.volume = settings.videoMuted ? 0 : Float(settings.audioVolume)
        }
        resetOrder()
    }

    func update(_ settings: CanvasSettings) {
        let filesChanged = self.settings.audioFileURLs != settings.audioFileURLs
        let shuffleChanged = self.settings.audioShuffle != settings.audioShuffle
        if filesChanged {
            let requested = wantsPlayback
            let wasInterrupted = interrupted
            let shouldResume = resumeAfterInterruption
            configure(settings)
            wantsPlayback = requested
            interrupted = wasInterrupted
            resumeAfterInterruption = shouldResume
        } else {
            self.settings = settings
            players.forEach { $0.volume = settings.videoMuted ? 0 : Float(settings.audioVolume) }
            if shuffleChanged { resetOrder(preservingCurrent: true) }
        }
        reconcilePlayback()
    }

    /// A presentation, schedule, power limit, or scene may suspend music
    /// without discarding the requested track or allowing interruptions to
    /// resurrect audio after the presentation has closed.
    func setPlaybackAllowed(_ allowed: Bool) {
        playbackAllowed = allowed
        reconcilePlayback()
    }

    func start() {
        if playlistFinished { resetOrder() }
        wantsPlayback = true
        if interrupted { resumeAfterInterruption = true }
        reconcilePlayback()
    }

    func pause() {
        wantsPlayback = false
        resumeAfterInterruption = false
        reconcilePlayback()
    }

    func stop() {
        wantsPlayback = false
        resumeAfterInterruption = false
        players.forEach { $0.stop(); $0.currentTime = 0 }
        isPlaying = false
        setAudioSessionActive(false)
    }

    func setVolume(_ volume: Double) {
        settings.audioVolume = volume
        players.forEach { $0.volume = settings.videoMuted ? 0 : Float(volume) }
    }

    func handleInterruption(_ type: AVAudioSession.InterruptionType, options: AVAudioSession.InterruptionOptions = []) {
        switch type {
        case .began:
            resumeAfterInterruption = wantsPlayback
            interrupted = true
            reconcilePlayback()
        case .ended:
            interrupted = false
            let resume = resumeAfterInterruption && options.contains(.shouldResume)
            resumeAfterInterruption = false
            if !resume { wantsPlayback = false }
            reconcilePlayback()
        @unknown default:
            break
        }
    }

    private var effectivePermission: Bool {
        playbackAllowed && wantsPlayback && !interrupted
            && settings.backgroundAudio == .localFiles && !settings.videoMuted
    }

    private func setAudioSessionActive(_ active: Bool) {
        // Do not repeatedly deactivate a session that belongs to a video or
        // another audio surface when no background track has been started.
        guard ownsActiveSession != active else { return }
        ownsActiveSession = active
        activateSession(active)
    }

    private func reconcilePlayback() {
        guard effectivePermission, order.indices.contains(orderPosition) else {
            players.forEach { $0.pause() }
            isPlaying = false
            setAudioSessionActive(false)
            return
        }
        guard !isPlaying else { return }
        setAudioSessionActive(true)
        isPlaying = players[order[orderPosition]].play()
    }

    private func resetOrder(preservingCurrent: Bool = false) {
        let current = preservingCurrent && order.indices.contains(orderPosition) ? order[orderPosition] : nil
        order = Array(players.indices)
        if settings.audioShuffle { order.shuffle() }
        if let current {
            order.removeAll { $0 == current }
            order.insert(current, at: 0)
        }
        orderPosition = 0
        playlistFinished = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self, weak player] in
            guard let self, let player else { return }
            self.handleFinished(for: player)
        }
    }

    func handleFinished(for player: any CanvasAudioPlayer) {
        // Ignore callbacks from replaced tracks and callbacks arriving after
        // a gate or stop. Repeat controls the whole playlist, not each track.
        guard effectivePermission, isPlaying, order.indices.contains(orderPosition),
              players[order[orderPosition]] === player else { return }
        isPlaying = false
        if orderPosition + 1 < order.count {
            orderPosition += 1
        } else if settings.audioRepeat {
            resetOrder()
        } else {
            wantsPlayback = false
            playlistFinished = true
            setAudioSessionActive(false)
            return
        }
        players[order[orderPosition]].currentTime = 0
        reconcilePlayback()
    }
}
