#if os(iOS)
import AVFoundation
import Observation

/// iOS session policy surrounds the same local-file playback engine as macOS.
@MainActor
@Observable
final class IOSRecordingPlaybackModel {
    let playback = AudioPlaybackService(updateInterval: .milliseconds(250))
    private(set) var isActivating = false
    var sessionError: String?
    @ObservationIgnored private let session = IOSPlaybackAudioSession()
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private var revision = UUID()

    func load(url: URL) async {
        stop()
        let request = revision
        await sessionTask?.value
        do {
            try Task.checkCancellation()
            let prepared = try await session.prepare(url: url)
            try Task.checkCancellation()
            guard revision == request else { return }
            playback.loadPrepared(prepared.player)
        } catch is CancellationError {
            // A cancelled/superseded detail must never install an old player.
        } catch {
            guard revision == request else { return }
            playback.reportLoadFailure()
        }
    }

    func togglePlayback() {
        if playback.isPlaying || isActivating {
            pause()
            return
        }
        guard playback.isLoaded else { return }
        let request = UUID()
        revision = request
        let previous = sessionTask
        isActivating = true
        sessionTask = Task {
            await previous?.value
            do {
                try Task.checkCancellation()
                try await session.activate()
                try Task.checkCancellation()
                guard revision == request, playback.isLoaded else { return }
                sessionError = nil
                playback.togglePlayback()
            } catch is CancellationError {
                // The queued pause owns deactivation after this activation finishes.
            } catch {
                await session.deactivate()
                guard revision == request else { return }
                sessionError = "Audio playback is unavailable right now. Try again when the interruption ends."
            }
            if revision == request { isActivating = false; sessionTask = nil }
        }
    }

    func seek(to time: TimeInterval) { playback.seek(to: time) }

    func pause() {
        if playback.isPlaying { playback.togglePlayback() }
        revision = UUID()
        isActivating = false
        let previous = sessionTask
        previous?.cancel()
        let request = revision
        sessionTask = Task {
            await previous?.value
            await session.deactivate()
            if revision == request { sessionTask = nil }
        }
    }

    func stop() {
        pause()
        playback.stop()
    }

    func handleInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        pause()
    }

    func handleRouteChange(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        pause()
    }
}
#endif
