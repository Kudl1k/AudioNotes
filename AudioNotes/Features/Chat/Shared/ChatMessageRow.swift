import SwiftUI

/// A presentation snapshot, never a replacement for ChatMessage persistence.
struct ChatMessagePresentation: Identifiable, Equatable {
    let id: UUID
    let role: ChatRole
    let generationID: UUID?
    let interrupted: Bool

    init(_ message: ChatMessage) {
        id = message.id
        role = message.role
        generationID = message.generationID
        interrupted = message.status == .interrupted
    }
}

/// Domain-specific Markdown cleanup and authoritative citations are composed here.
struct ChatMessageRow<Content: View>: View {
    let presentation: ChatMessagePresentation
    let canRegenerate: Bool
    let onCopy: () -> Void
    let onRegenerate: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                // The row's accessibility label already names the speaker.
                Text(presentation.role == .user ? "You" : "AudioNotes").font(.caption.bold()).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                if presentation.role == .assistant { GenerationDetailsButton(generationID: presentation.generationID) }
                if presentation.interrupted { Text("Interrupted").font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
            }
            content()
            HStack(spacing: 12) {
                Button("Copy", systemImage: "doc.on.doc", action: onCopy)
                    .accessibilityLabel("Copy message").accessibilityIdentifier("chat.copy")
                if presentation.role == .assistant && canRegenerate {
                    Button("Regenerate", systemImage: "arrow.clockwise", action: onRegenerate)
                        .accessibilityLabel("Regenerate answer").accessibilityIdentifier("chat.regenerate")
                }
            }.font(.caption).buttonStyle(.borderless).foregroundStyle(.secondary)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(presentation.role == .user ? Color.accentColor.opacity(0.12) : Color.chatCardBackground, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain).accessibilityLabel(presentation.role == .user ? "Your message" : "Assistant message")
            .contextMenu {
                Button("Copy Message", action: onCopy)
                if presentation.role == .assistant && canRegenerate { Button("Regenerate", action: onRegenerate) }
            }
    }
}
