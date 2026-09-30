import SwiftUI

struct PlaybackControls: View {
    @Bindable var playback: AudioPlaybackService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Button(action: playback.togglePlayback) {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 24, height: 24)
                }
                .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                .disabled(!playback.isLoaded)
                Text(AudioTime.string(playback.currentTime))
                    .frame(minWidth: 46)
                    .monospacedDigit()
                Slider(value: Binding(get: { playback.currentTime }, set: { playback.seek(to: $0) }),
                       in: 0...max(playback.duration, 0.01))
                    .accessibilityLabel("Playback position")
                    .disabled(!playback.isLoaded)
                Text(AudioTime.string(playback.duration))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            if let error = playback.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }
}
