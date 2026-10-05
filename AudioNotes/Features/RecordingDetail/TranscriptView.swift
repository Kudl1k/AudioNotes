import SwiftUI

struct TranscriptView: View {
    let transcript: Transcript?
    var revealedSegmentID: UUID? = nil
    let seek: (TimeInterval) -> Void
    @State private var searchText = ""
#if os(iOS)
    @FocusState private var searchFocused: Bool
#endif
    @State private var model = TranscriptViewModel()

    var body: some View {
        if let transcript, !transcript.segments.isEmpty {
            VStack(spacing: 0) {
                TextField("Search transcript", text: $searchText)
#if os(iOS)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .onSubmit { searchFocused = false }
#endif
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, contentHorizontalPadding)
                    .padding(.top, searchTopPadding)
                    .accessibilityLabel("Search transcript").accessibilityIdentifier("transcript.search")
                if model.isLoading {
                    ProgressView("Loading transcript…").controlSize(.small).padding(8)
                }
                if !searchText.isEmpty && !model.visibleSegments.isEmpty {
                    Text("\(model.visibleSegments.count) matches")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, contentHorizontalPadding).padding(.top, WorkspaceSpacing.compact)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: segmentSpacing) {
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
                        .padding(.horizontal, contentHorizontalPadding)
                        .padding(.vertical, WorkspaceSpacing.standard)
                    }
#if os(iOS)
                    .scrollDismissesKeyboard(.interactively)
#endif
                    .onChange(of: revealedSegmentID) { _, id in
                        searchText = ""
                        if let id { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onChange(of: model.visibleSegments) { _, _ in
#if os(iOS)
                        if !searchText.isEmpty, let first = model.visibleSegments.first { proxy.scrollTo(first.id, anchor: .top) }
#endif
                        if let id = revealedSegmentID, searchText.isEmpty { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onAppear {
                        if let id = revealedSegmentID { proxy.scrollTo(id, anchor: .center) }
                    }
#if DEBUG && os(iOS)
                    .task(id: model.visibleSegments.last?.id) {
                        guard ProcessInfo.processInfo.arguments.contains("--performance-fixtures"),
                              ProcessInfo.processInfo.arguments.contains("--ios-review-transcript-end"),
                              let last = model.visibleSegments.last else { return }
                        // Lazy rows need to lay out before ScrollViewReader knows the last row's height.
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        proxy.scrollTo(last.id, anchor: .bottom)
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
#endif
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

    private var searchTopPadding: CGFloat {
#if os(iOS)
        WorkspaceSpacing.compact
#else
        WorkspaceSpacing.standard
#endif
    }

    private var contentHorizontalPadding: CGFloat {
#if os(iOS)
        0 // The iOS detail shell owns the reading margin.
#else
        WorkspaceSpacing.majorSection
#endif
    }
    private var segmentSpacing: CGFloat {
#if os(iOS)
        WorkspaceSpacing.section
#else
        WorkspaceSpacing.majorSection
#endif
    }

    private func segmentRow(_ segment: TranscriptDisplaySegment) -> some View {
        let time = AudioTime.string(segment.startTime)
        return Group {
#if os(iOS)
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack { segmentHeading(segment, time: time) }
                VStack(alignment: .leading, spacing: 4) { segmentHeading(segment, time: time, horizontal: false) }
            }
            Text(segment.text).textSelection(.enabled).lineSpacing(3)
        }
#else
        HStack(alignment: .top, spacing: 16) {
            Button(time) { seek(segment.startTime) }
                #if os(macOS)
            .buttonStyle(.link).monospacedDigit()
#else
            .buttonStyle(.plain).foregroundStyle(.tint).monospacedDigit()
            .frame(minWidth: 60, minHeight: 44, alignment: .topLeading)
            .contentShape(Rectangle())
#endif
            VStack(alignment: .leading, spacing: 4) {
                if let speaker = segment.speaker { Text(speaker).font(.caption.bold()) }
                Text(segment.text).textSelection(.enabled)
            }
        }
#endif
        }
        // One element per segment: speaker, timestamp, then text. Activating it plays from the segment.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenLabel(speaker: segment.speaker, time: time, text: segment.text))
        .accessibilityAction(named: "Play from \(time)") { seek(segment.startTime) }
        .accessibilityIdentifier("transcript.segment")
    }

#if os(iOS)
    @ViewBuilder private func segmentHeading(_ segment: TranscriptDisplaySegment, time: String, horizontal: Bool = true) -> some View {
        if let speaker = segment.speaker { Text(speaker).font(.subheadline.weight(.semibold)) }
        if horizontal { Spacer(minLength: 8) }
        Button(time) { seek(segment.startTime) }
            .font(.subheadline.monospacedDigit()).buttonStyle(.plain).foregroundStyle(.tint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.background.secondary, in: Capsule())
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Play from " + time)
    }
#endif

    static func spokenLabel(speaker: String?, time: String, text: String) -> String {
        [speaker, time, text].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", ")
    }
}
