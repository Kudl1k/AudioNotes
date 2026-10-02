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
                    .padding(.horizontal, WorkspaceSpacing.majorSection)
                    .padding(.top, WorkspaceSpacing.standard)
                    .accessibilityLabel("Search transcript").accessibilityIdentifier("transcript.search")
                if model.isLoading {
                    ProgressView("Loading transcript…").controlSize(.small).padding(8)
                }
                if !searchText.isEmpty && !model.visibleSegments.isEmpty {
                    Text("\(model.visibleSegments.count) matches")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, WorkspaceSpacing.majorSection).padding(.top, WorkspaceSpacing.compact)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: WorkspaceSpacing.majorSection) {
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
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(WorkspaceSpacing.majorSection)
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
                    // An overlay keeps the scroll view (and its position) alive across searches.
                    .overlay {
                        if !searchText.isEmpty && model.visibleSegments.isEmpty && !model.isLoading && model.searchedQuery == searchText {
                            ContentUnavailableView.search(text: searchText).background(.background)
                        }
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
        let time = AudioTime.string(segment.startTime)
        return HStack(alignment: .top, spacing: 16) {
            Button(time) { seek(segment.startTime) }
                .buttonStyle(.link).monospacedDigit()
            VStack(alignment: .leading, spacing: 4) {
                if let speaker = segment.speaker { Text(speaker).font(.caption.bold()) }
                Text(segment.text).textSelection(.enabled)
            }
        }
        // One element per segment: speaker, timestamp, then text. Activating it plays from the segment.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenLabel(speaker: segment.speaker, time: time, text: segment.text))
        .accessibilityAction(named: "Play from \(time)") { seek(segment.startTime) }
        .accessibilityIdentifier("transcript.segment")
    }

    static func spokenLabel(speaker: String?, time: String, text: String) -> String {
        [speaker, time, text].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", ")
    }
}
