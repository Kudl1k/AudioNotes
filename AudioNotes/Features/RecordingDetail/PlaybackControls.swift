import SwiftUI

struct PlaybackControls: View {
    @Bindable var playback: AudioPlaybackService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Button {
                        playback.seek(to: playback.currentTime - 15)
                    } label: {
                        Image(systemName: "gobackward.15")
                            .font(.body)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!playback.isLoaded)
                    .help("Skip back 15 seconds")
                    .accessibilityLabel("Skip back 15 seconds")

                    Button(action: playback.togglePlayback) {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.body.weight(.semibold))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                    .accessibilityIdentifier("playback.toggle")
                    .disabled(!playback.isLoaded)

                    Button {
                        playback.seek(to: playback.currentTime + 15)
                    } label: {
                        Image(systemName: "goforward.15")
                            .font(.body)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!playback.isLoaded)
                    .help("Skip forward 15 seconds")
                    .accessibilityLabel("Skip forward 15 seconds")
                }

                Text(AudioTime.string(playback.currentTime))
                    .font(.callout.monospacedDigit())
                    .frame(minWidth: 44, alignment: .trailing)
                    .accessibilityHidden(true)

                Slider(
                    value: Binding(get: { playback.currentTime }, set: { playback.seek(to: $0) }),
                    in: 0...max(playback.duration, 0.01)
                )
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(AudioTime.string(playback.currentTime)) of \(AudioTime.string(playback.duration))")
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityIdentifier("playback.position")
                .disabled(!playback.isLoaded)

                Text(AudioTime.string(playback.duration))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .leading)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if let error = playback.errorMessage {
                InlineErrorLabel(error)
            }
        }
    }
}
