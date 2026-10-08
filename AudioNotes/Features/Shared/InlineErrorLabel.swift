import SwiftUI

/// Inline failure text that does not rely on color: an icon, the message, and an "Error" prefix for VoiceOver.
struct InlineErrorLabel: View {
    let message: String
    var font: Font = .caption

    init(_ message: String, font: Font = .caption) {
        self.message = message
        self.font = font
    }

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(font).foregroundStyle(.red).textSelection(.enabled)
            .accessibilityElement(children: .ignore).accessibilityLabel("Error: \(message)")
    }
}
