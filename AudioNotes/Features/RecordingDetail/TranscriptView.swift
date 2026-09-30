import SwiftUI

struct TranscriptView: View {
    let transcript: Transcript?
    let seek: (TimeInterval) -> Void

    var body: some View {
        if let transcript, !transcript.segments.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(transcript.orderedSegments) { segment in
                        HStack(alignment: .top, spacing: 16) {
                            Button(AudioTime.string(segment.startTime)) {
                                seek(segment.startTime)
                            }
                            .buttonStyle(.link).monospacedDigit()
                            .accessibilityLabel("Seek to \(Int(segment.startTime)) seconds")
                            VStack(alignment: .leading, spacing: 4) {
                                if let speaker = segment.speaker { Text(speaker).font(.caption.bold()) }
                                Text(segment.text).textSelection(.enabled)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        } else {
            ContentUnavailableView("No transcript yet", systemImage: "text.alignleft",
                                   description: Text("Transcription is not available yet. Your audio is saved in your library."))
        }
    }
}
