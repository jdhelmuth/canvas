import AVFoundation
import Foundation

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
        players[index].play(); isPlaying = true
    }
    func pause() { players.forEach { $0.pause() }; isPlaying = false }
    func stop() { players.forEach { $0.stop(); $0.currentTime = 0 }; isPlaying = false }
    func setVolume(_ volume: Double) { settings.audioVolume = volume; players.forEach { $0.volume = Float(volume) } }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.handleFinished() }
    }
    private func handleFinished() {
        guard settings.audioRepeat else { isPlaying = false; return }
        index = (index + 1) % max(players.count, 1)
        if settings.audioShuffle { index = Int.random(in: 0..<players.count) }
        players[index].play(); isPlaying = true
    }
}
