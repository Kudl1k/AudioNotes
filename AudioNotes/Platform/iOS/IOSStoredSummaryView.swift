#if os(iOS)
import SwiftUI

struct IOSStoredSummaryView: View {
    let recording: Recording
    @State private var selectedID: UUID?

    private var versions: [Summary] {
        ([recording.summary].compactMap { $0 } + recording.summaryHistory)
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        if let summary = versions.first(where: { $0.id == selectedID }) ?? recording.summary ?? versions.first {
            VStack(spacing: 8) {
                if versions.count > 1 {
                    Picker("Summary version", selection: Binding(get: { selectedID ?? summary.id }, set: { selectedID = $0 })) {
                        ForEach(versions) { version in
                            Text(version.createdAt.formatted(date: .abbreviated, time: .shortened)).tag(version.id)
                        }
                    }.pickerStyle(.menu)
                }
                IOSSummaryMarkdownView(summary: summary).id(summary.id)
            }
        } else {
            ContentUnavailableView("No summary yet", systemImage: "doc.text",
                description: Text("Existing summaries appear here. Summary generation will be available in a future update."))
        }
    }
}

private struct IOSSummaryMarkdownView: View {
    let summary: Summary
    @State private var document = MarkdownDocument("")

    var body: some View {
        ScrollView {
            MarkdownMessageView(document: document).textSelection(.enabled)
                .padding(16).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }
        .task(id: summary.updatedAt) {
            // Read SwiftData on its actor; send only the text snapshot to the parser.
            let text = SummaryMarkdownContent.text(summary)
            let parsed = await Task.detached(priority: .userInitiated) { MarkdownDocument(text) }.value
            guard !Task.isCancelled else { return }
            document = parsed
        }
    }
}
/// Parses only the overview snapshot; structured summary timestamps remain native buttons.
struct IOSSummaryOverviewView: View {
    let text: String
    @State private var document = MarkdownDocument("")
    var body: some View {
        MarkdownMessageView(document: document).textSelection(.enabled)
            .task(id: text) {
                let snapshot = text
                let parsed = await Task.detached(priority: .userInitiated) { MarkdownDocument(snapshot) }.value
                guard !Task.isCancelled else { return }
                document = parsed
            }
    }
}
#endif
