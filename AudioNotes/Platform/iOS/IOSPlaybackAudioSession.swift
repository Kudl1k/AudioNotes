#if os(iOS)
import AVFoundation

/// AVAudioPlayer lacks Sendable annotation. This carrier transfers sole ownership
/// from the preparation actor to the UI actor; the worker never retains or reuses it.
struct PreparedIOSAudio: @unchecked Sendable {
    let player: AVAudioPlayer
}

/// iOS 18-compatible session calls can block; serialize them away from the UI actor.
actor IOSPlaybackAudioSession {
    private var active = false

    func prepare(url: URL) throws -> PreparedIOSAudio {
        let player = try AVAudioPlayer(contentsOf: url)
        guard player.prepareToPlay() else { throw AudioImportError.invalidAudio }
        return PreparedIOSAudio(player: player)
    }

    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        active = true
    }

    func deactivate() {
        guard active else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        active = false
    }
}
#endif
