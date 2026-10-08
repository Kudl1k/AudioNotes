import SwiftUI

/// Persistent rows do not observe token updates from the active response.
struct ChatMessageBubble: View {
    let message: ChatMessage
    let recording: Recording
    let canRegenerate: Bool
    var onSeek: ((TimeInterval) -> Void)?
    var onOpenSource: ((SourceReference) -> Void)?
    let onRegenerate: () -> Void

    var body: some View {
        ChatMessageRow(presentation: ChatMessagePresentation(message), canRegenerate: canRegenerate,
            onCopy: { Clipboard.copy(copyContent(message)) }, onRegenerate: onRegenerate) {
            if message.role == .assistant {
                AssistantMessageView(
                    markdown: ChatContentNormalizer.clean(message.text, references: message.references, internalSegmentIDs: recording.transcript?.segments.map(\.id) ?? []),
                    references: validatedReferences(message.references), onSeek: onSeek)
                SourceReferenceChips(references: SourceReferenceResolver().validate(message.sourceReferences, recording: recording)) { onOpenSource?($0) }
            } else {
                Text(message.text).textSelection(.enabled).font(.callout)
            }
        }
    }

    private func validatedReferences(_ references: [TranscriptReference]) -> [TranscriptReference] {
        guard !references.isEmpty else { return [] }
        return TranscriptReferenceResolver().resolve(
            segmentIDs: references.compactMap { $0.segmentID?.uuidString },
            against: recording.transcript?.segmentSnapshots ?? []
        )
    }

    private func copyContent(_ message: ChatMessage) -> String {
        message.role == .assistant
            ? ChatContentNormalizer.clean(message.text, references: message.references, internalSegmentIDs: recording.transcript?.segments.map(\.id) ?? [])
            : message.text
    }
}
