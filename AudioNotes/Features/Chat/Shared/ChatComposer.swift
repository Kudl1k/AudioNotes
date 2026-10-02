import SwiftUI

struct ChatComposer: View {
    @State private var isComposing = false
    @Binding var text: String
    @Binding var focusRequest: Int
    let placeholder: String
    let canSend: Bool
    let isGenerating: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    private func send() {
        guard canSend, !isComposing, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onSend()
        focusRequest += 1
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ChatTextEditorRepresentable(text: $text, isComposing: $isComposing, canSend: canSend, focusRequest: focusRequest, placeholder: placeholder, onSend: send, onCancel: isGenerating ? onStop : nil)
                .fixedSize(horizontal: false, vertical: true)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder).font(.callout).foregroundStyle(.tertiary)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            if isGenerating {
                Button("Stop", systemImage: "stop.circle.fill", action: onStop)
                    .labelStyle(.iconOnly).font(.title2).foregroundStyle(.red).buttonStyle(.plain)
                    .help("Stop generating (Escape while typing)")
                    .accessibilityLabel("Stop generating").accessibilityIdentifier("chat.stop")
            } else {
                Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                    .labelStyle(.iconOnly).font(.title2).buttonStyle(.plain).disabled(!canSend || isComposing)
                    .help("Send message (Return)").accessibilityLabel("Send message").accessibilityIdentifier("chat.send")
            }
        }
    }
}
