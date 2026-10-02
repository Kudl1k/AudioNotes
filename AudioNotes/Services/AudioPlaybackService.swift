import AVFoundation
import Observation

@MainActor
protocol AudioPlaybackEngine: AnyObject {
    var currentTime: TimeInterval { get set }
    var duration: TimeInterval { get }
    var isPlaying: Bool { get }
    func prepareToPlay() -> Bool
    func play() -> Bool
    func pause()
    func stop()
}

extension AVAudioPlayer: AudioPlaybackEngine {}

@MainActor
@Observable
final class AudioPlaybackService {
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var errorMessage: String?
    private(set) var isLoaded = false
    @ObservationIgnored private var player: (any AudioPlaybackEngine)?
    @ObservationIgnored private var progressTask: Task<Void, Never>?

    @ObservationIgnored private let updateInterval: Duration

    @ObservationIgnored private let makePlayer: (URL) throws -> any AudioPlaybackEngine

    init(updateInterval: Duration = .milliseconds(100),
         makePlayer: @escaping (URL) throws -> any AudioPlaybackEngine = { try AVAudioPlayer(contentsOf: $0) }) {
        self.updateInterval = updateInterval
        self.makePlayer = makePlayer
    }

    func load(url: URL) {
        let interval = PerformanceSignposts.begin("Audio playback load")
        defer { PerformanceSignposts.end("Audio playback load", interval) }
        stop()
        errorMessage = nil
        do {
            let audioPlayer = try makePlayer(url)
            guard audioPlayer.prepareToPlay() else { throw AudioImportError.invalidAudio }
            player = audioPlayer
            duration = audioPlayer.duration
            isLoaded = true
        } catch {
            errorMessage = "Could not open this recording: \(error.localizedDescription)"
        }
    }

    /// Accepts an engine prepared by a platform worker, without doing file I/O again.
    func loadPrepared(_ prepared: any AudioPlaybackEngine) {
        stop()
        errorMessage = nil
        player = prepared
        duration = prepared.duration
        isLoaded = true
    }

    func reportLoadFailure() {
        stop()
        errorMessage = "This recording could not be opened. Its managed audio may be missing or damaged."
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
                    do { try await Task.sleep(for: self?.updateInterval ?? .milliseconds(100)) }
                    catch { return }
                    guard let self else { return }
                    self.refreshProgress()
                    if !self.isPlaying { return }
                }
            }
        }
    }

    /// Polls factual engine state; no timer writes persistence or observes the library.
    func refreshProgress() {
        guard isPlaying, let player else { return }
        currentTime = player.currentTime
        if !player.isPlaying {
            currentTime = duration
            isPlaying = false
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
