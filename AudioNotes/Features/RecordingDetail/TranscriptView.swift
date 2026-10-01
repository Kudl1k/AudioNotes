import SwiftUI

struct TranscriptView: View {
    let transcript: Transcript?
    var revealedSegmentID: UUID? = nil
    let seek: (TimeInterval) -> Void
    @State private var searchText = ""
    @State private var model = TranscriptViewModel()

    var body: some View {
        if let transcript, !transcript.segments.isEmpty {
            VStack(spacing: 0) {
                TextField("Search transcript", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .accessibilityLabel("Search transcript")
                if model.isLoading {
                    ProgressView("Loading transcript…").controlSize(.small).padding(8)
                }
                if !searchText.isEmpty {
                    Text("\(model.visibleSegments.count) matches")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18).padding(.top, 6)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            if transcript.isMock {
                                Label("Sample transcript · Mock provider · Not actual speech recognition", systemImage: "info.circle")
                                    .font(.callout).foregroundStyle(.secondary)
                            } else if let source = transcript.sourceName {
                                Text(source).font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(model.visibleSegments) { segment in
                                segmentRow(segment).id(segment.id)
                            }
                        }
                        .frame(maxWidth: 860, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(20)
                    }
                    .onChange(of: revealedSegmentID) { _, id in
                        searchText = ""
                        if let id { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onChange(of: model.visibleSegments) { _, _ in
                        if let id = revealedSegmentID, searchText.isEmpty { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onAppear {
                        if let id = revealedSegmentID { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
            .task(id: transcript.id) { await model.load(transcript) }
            .task(id: searchText) { await model.search(searchText) }
        } else {
            ContentUnavailableView("No transcript yet", systemImage: "text.alignleft",
                description: Text("Choose Transcribe to create a transcript. Your audio stays in your library."))
        }
    }

    private func segmentRow(_ segment: TranscriptDisplaySegment) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Button(AudioTime.string(segment.startTime)) { seek(segment.startTime) }
                .buttonStyle(.link).monospacedDigit()
                .accessibilityLabel("Seek to \(AudioTime.string(segment.startTime))")
            VStack(alignment: .leading, spacing: 4) {
                if let speaker = segment.speaker { Text(speaker).font(.caption.bold()) }
                Text(segment.text).textSelection(.enabled)
            }
        }
    }
}
