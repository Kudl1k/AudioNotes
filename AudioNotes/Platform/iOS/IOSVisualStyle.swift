#if os(iOS)
import SwiftUI

/// Controls share the public system glass rendering; content never uses this modifier.
struct IOSControlSurface: ViewModifier {
    var cornerRadius: CGFloat = 24
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased || IOSVisualReview.forceOpaqueControls {
            content.background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(.primary, lineWidth: 1))
        } else if #available(iOS 26, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

struct IOSPrimaryAction: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26, *), !reduceTransparency, contrast != .increased, !IOSVisualReview.forceOpaqueControls {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

/// Group nearby control surfaces without applying glass to their content or container.
struct IOSGlassControls<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 8, content: content)
        } else {
            content()
        }
    }
}

/// A compact, scrollable action group instead of ContentUnavailableView's generous layout.
struct IOSCreationPrompt<Actions: View>: View {
    let title: String
    let symbol: String
    let description: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 32)).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text(description).font(.subheadline).foregroundStyle(.secondary)
            }
            actions()
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}
/// Explicit DEBUG review of the opaque fallback without changing system accessibility settings.
private enum IOSVisualReview {
    static var forceOpaqueControls: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--performance-fixtures") &&
            ProcessInfo.processInfo.arguments.contains("--ios-review-reduce-transparency")
#else
        false
#endif
    }
}
#endif
