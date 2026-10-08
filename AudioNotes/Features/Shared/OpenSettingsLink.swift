import SwiftUI

/// An action to open settings, customizable via the environment for platforms or contexts
/// where standard SwiftUI `SettingsLink` is not available or custom navigation is needed.
struct OpenSettingsAction: Sendable {
    private let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @MainActor
    func callAsFunction() {
        action()
    }
}

private struct OpenSettingsActionKey: EnvironmentKey {
    static let defaultValue: OpenSettingsAction? = nil
}

extension EnvironmentValues {
    var openSettingsAction: OpenSettingsAction? {
        get { self[OpenSettingsActionKey.self] }
        set { self[OpenSettingsActionKey.self] = newValue }
    }
}

/// A cross-platform settings link that uses native SwiftUI `SettingsLink` on macOS
/// (or an injected `OpenSettingsAction` if present in the environment),
/// and falls back to a Button triggering `openSettingsAction` on other platforms.
struct OpenSettingsLink<Label: View>: View {
    @Environment(\.openSettingsAction) private var openSettingsAction
    @ViewBuilder let label: () -> Label

    init(@ViewBuilder label: @escaping () -> Label) {
        self.label = label
    }

    var body: some View {
#if os(macOS)
        if let openSettingsAction {
            Button(action: { openSettingsAction() }, label: label)
        } else {
            SettingsLink(label: label)
        }
#else
        Button(action: { openSettingsAction?() }, label: label)
#endif
    }
}
