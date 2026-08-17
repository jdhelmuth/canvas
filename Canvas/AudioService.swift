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

@MainActor
final class AudioService: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    private var players: [AVAudioPlayer] = []
    private var index = 0
    private var settings: CanvasSettings = .init()
    private var interruptionObserver: NSObjectProtocol?

    override init() {
        super.init()
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, let type = AVAudioSession.InterruptionType(rawValue: typeValue), type == .ended else { return }
            Task { @MainActor in if self?.settings.backgroundAudio == .localFiles, self?.settings.videoMuted == false { self?.start() } }
        }
    }
    deinit { if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) } }

    func configure(_ settings: CanvasSettings) {
        stop()
        index = 0
        self.settings = settings
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(settings.backgroundAudio == .localFiles && !settings.videoMuted)
        players = settings.audioFileURLs.compactMap { try? AVAudioPlayer(contentsOf: $0) }
        players.forEach { $0.delegate = self; $0.volume = settings.videoMuted ? 0 : Float(settings.audioVolume); $0.prepareToPlay() }
    }

    /// Applies settings changes while a frame is already playing. In
    /// particular, enabling the global mute switch must stop an already
    /// running background track immediately, not only affect the next launch.
    func update(_ settings: CanvasSettings) {
        let wasAllowed = self.settings.backgroundAudio == .localFiles && !self.settings.videoMuted
        let wasPlaying = isPlaying
        let nowAllowed = settings.backgroundAudio == .localFiles && !settings.videoMuted
        let filesChanged = self.settings.audioFileURLs != settings.audioFileURLs
        if filesChanged {
            configure(settings)
            if nowAllowed && (wasPlaying || !wasAllowed) { start() }
            return
        }
        self.settings = settings
        players.forEach { $0.volume = settings.videoMuted ? 0 : Float(settings.audioVolume) }
        if nowAllowed {
            try? AVAudioSession.sharedInstance().setActive(true)
            // Enabling background audio or unmuting while a frame is active
            // should begin the selected track. Volume-only changes preserve
            // the current player without restarting it.
            if !wasAllowed && !wasPlaying { start() }
        } else {
            stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
    func start() {
        guard settings.backgroundAudio == .localFiles, !settings.videoMuted, !players.isEmpty else { return }
        if settings.audioShuffle { index = Int.random(in: 0..<players.count) }
        else if let safeIndex = AudioPlaybackIndexPolicy.clampedIndex(index, playerCount: players.count) { index = safeIndex }
        players[index].play(); isPlaying = true
    }
    func pause() { players.forEach { $0.pause() }; isPlaying = false }
    func stop() { players.forEach { $0.stop(); $0.currentTime = 0 }; isPlaying = false }
    func setVolume(_ volume: Double) { settings.audioVolume = volume; players.forEach { $0.volume = Float(volume) } }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self, weak player] in
            guard let self, let player else { return }
            self.handleFinished(for: player)
        }
    }

    private func handleFinished(for player: AVAudioPlayer) {
        // A completion can arrive after a settings update replaced the player
        // list. Ignore that stale callback instead of advancing the new list.
        guard players.contains(where: { $0 === player }) else { return }
        guard settings.audioRepeat else { isPlaying = false; return }
        if settings.audioShuffle {
            index = Int.random(in: 0..<players.count)
        } else if let nextIndex = AudioPlaybackIndexPolicy.nextSequentialIndex(after: index, playerCount: players.count) {
            index = nextIndex
        } else {
            isPlaying = false
            return
        }
        players[index].play(); isPlaying = true
    }
}
