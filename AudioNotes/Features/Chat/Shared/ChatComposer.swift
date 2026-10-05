#if os(macOS)
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
#elseif os(iOS)
import SwiftUI

struct ChatComposer: View {
    @Binding var text: String
    @Binding var focusRequest: Int
    let placeholder: String
    let canSend: Bool
    let isGenerating: Bool
    let onSend: () -> Void
    let onStop: () -> Void
    var providerTitle: String? = nil
    var onSettings: () -> Void = {}
    var onClear: () -> Void = {}
    @FocusState private var isFocused: Bool

    private func send() {
        guard canSend, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onSend()
        focusRequest += 1
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            if let providerTitle {
                Menu {
                    Section(providerTitle) {
                        Button("AI Defaults", systemImage: "slider.horizontal.3", action: onSettings)
                        Button("Clear Chat", systemImage: "trash", role: .destructive, action: onClear)
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Chat options, " + providerTitle)
                .accessibilityIdentifier("chat.options")
            }
            TextField(placeholder, text: $text, axis: .vertical)
                .focused($isFocused)
                .lineLimit(1...5)
                .padding(.leading, providerTitle == nil ? 12 : 0)
                .padding(.vertical, 10)
                .accessibilityIdentifier("chat.input")

            if isGenerating {
                Button("Stop", systemImage: "stop.circle.fill", action: onStop)
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .frame(minWidth: 44, minHeight: 44)
                    .foregroundStyle(.red)
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop generating")
                    .accessibilityIdentifier("chat.stop")
            } else {
                Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .frame(minWidth: 44, minHeight: 44)
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .accessibilityLabel("Send message")
                    .accessibilityIdentifier("chat.send")
            }
        }
        .padding(.trailing, 4)
        .modifier(IOSControlSurface())
        .onChange(of: focusRequest) { _, _ in
            isFocused = true
        }
    }
}
#endif
