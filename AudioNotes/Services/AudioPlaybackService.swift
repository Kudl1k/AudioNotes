import AVFoundation
import Observation

@MainActor
@Observable
final class AudioPlaybackService {
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var errorMessage: String?
    private(set) var isLoaded = false
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var progressTask: Task<Void, Never>?

    func load(url: URL) {
        let interval = PerformanceSignposts.begin("Audio playback load")
        defer { PerformanceSignposts.end("Audio playback load", interval) }
        stop()
        errorMessage = nil
        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: url)
            guard audioPlayer.prepareToPlay() else { throw AudioImportError.invalidAudio }
            player = audioPlayer
            duration = audioPlayer.duration
            isLoaded = true
        } catch {
            errorMessage = "Could not open this recording: \(error.localizedDescription)"
        }
    }

    func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            progressTask?.cancel()
        } else {
            if currentTime >= duration { player.currentTime = 0 }
            guard player.play() else {
                errorMessage = "Audio playback could not start."
                return
            }
            isPlaying = true
            progressTask?.cancel()
            progressTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) }
                    catch { return }
                    guard let self, let player = self.player else { return }
                    self.currentTime = player.currentTime
                    if !player.isPlaying {
                        self.currentTime = self.duration
                        self.isPlaying = false
                        return
                    }
                }
            }
        }
    }

    func seek(to time: TimeInterval) {
        guard time.isFinite, let player else { return }
        currentTime = min(max(0, time), duration)
        player.currentTime = currentTime
    }

    func stop() {
        progressTask?.cancel()
        progressTask = nil
        player?.stop()
        player = nil
        isPlaying = false
        isLoaded = false
        currentTime = 0
        duration = 0
    }
}
