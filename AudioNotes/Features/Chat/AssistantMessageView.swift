#if os(macOS)
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

struct MarkdownMessageView: View, Equatable {
    let document: MarkdownDocument

    var body: some View { blocksView(document.blocks) }

    private func inline(_ markdown: String) -> AttributedString {
        var value = MarkdownDocument.inline(markdown)
        for run in value.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                value[run.range].font = .system(.callout, design: .monospaced)
                value[run.range].backgroundColor = Color.primary.opacity(0.06)
            }
        }
        return value
    }

    private func blocksView(_ blocks: [MarkdownDocument.Block]) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).font(.callout))
    }

    private func blockView(_ block: MarkdownDocument.Block) -> AnyView {
        switch block {
        case .paragraph(let text):
            return AnyView(Text(inline(text)).fixedSize(horizontal: false, vertical: true))
        case .heading(let level, let text):
            return AnyView(Text(inline(text)).font(level <= 2 ? .headline : .subheadline).fontWeight(.semibold).padding(.top, 4))
        case .list(let items):
            return AnyView(VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text(item.marker).monospacedDigit().frame(minWidth: 24, alignment: .trailing)
                        blocksView(item.blocks)
                    }
                }
            })
        case .code(let language, let text):
            return AnyView(MarkdownCodeBlock(language: language, code: text))
        case .quote(let blocks):
            return AnyView(HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(.secondary.opacity(0.35)).frame(width: 3)
                blocksView(blocks).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true))
        case .table(let header, let rows):
            return AnyView(ScrollView(.horizontal) {
                Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow { ForEach(Array(header.enumerated()), id: \.offset) { _, cell in Text(inline(cell)).fontWeight(.semibold).frame(minWidth: 100, maxWidth: 280, alignment: .leading) } }
                    Divider().gridCellColumns(header.count)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, cell in Text(inline(cell)).frame(minWidth: 100, maxWidth: 280, alignment: .leading).fixedSize(horizontal: false, vertical: true) } }
                    }
                }.padding(10)
            }.background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6)))
        case .separator:
            return AnyView(Divider().padding(.vertical, 4))
        }
    }
}

private struct MarkdownCodeBlock: View {
    let language: String
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(language).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") { copy() }
                    .font(.caption2).buttonStyle(.borderless)
                    .accessibilityLabel(language.isEmpty ? "Copy code" : "Copy \(language) code")
                    .accessibilityIdentifier("chat.code.copy")
            }
            ScrollView(.horizontal) {
                Text(verbatim: code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .contextMenu { Button("Copy Code") { copy() } }
    }

    private func copy() {
        Clipboard.copy(code)
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

#endif
