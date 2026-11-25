#if os(macOS)
import SwiftUI

struct FullWidthDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation { configuration.isExpanded.toggle() }
        } label: {
            HStack {
                configuration.label
                Spacer()
                Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isExpanded ? Text("Expanded") : Text("Collapsed"))

        if configuration.isExpanded {
            configuration.content
        }
    }
}
#endif
