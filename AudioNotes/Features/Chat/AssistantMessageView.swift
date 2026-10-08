import SwiftUI

struct AssistantMessageView: View {
    let markdown: String
    let references: [TranscriptReference]
    var onSeek: ((TimeInterval) -> Void)?
    @State private var document = MarkdownDocument("")

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MarkdownMessageView(document: document).equatable()
            if !references.isEmpty {
                ChatSourcesView(references: references, onSeek: onSeek)
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
        .textSelection(.enabled)
        .task(id: markdown) {
            let text = markdown
            let worker = Task.detached(priority: .userInitiated) {
                let interval = PerformanceSignposts.begin("Markdown block parse")
                defer { PerformanceSignposts.end("Markdown block parse", interval) }
                return MarkdownDocument(text)
            }
            let parsed = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            document = parsed
        }
    }
}

private struct ChatSourcesView: View {
    let references: [TranscriptReference]
    var onSeek: ((TimeInterval) -> Void)?
    @State private var expanded = false

    var body: some View {
        let groups = ChatSourcePresentation.groups(references)
        VStack(alignment: .leading, spacing: 6) {
            Text("Sources").font(.caption2).foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(expanded ? groups : Array(groups.prefix(5))) { group in
                    Button { onSeek?(group.startTime) } label: {
                        Label(TimestampFormatter.string(group.startTime), systemImage: "play.circle")
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(group.references.compactMap(\.excerpt).joined(separator: "\n"))
                    .accessibilityLabel("Open citation, recording at \(TimestampFormatter.string(group.startTime))")
                }
                if !expanded && groups.count > 5 {
                    Button("+\(groups.count - 5)") { expanded = true }
                        .font(.caption).buttonStyle(.borderless)
                        .accessibilityLabel("Show \(groups.count - 5) more sources")
                }
            }
        }
    }
}
