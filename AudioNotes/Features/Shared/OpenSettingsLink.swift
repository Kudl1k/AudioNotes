import SwiftUI

enum SettingsSection: Hashable, Sendable {
    case transcription
    case summary
    case chat
    case presets
    case openAI
    case gemini
    case localAI
    case usage
    case privacy
}

/// An action to open settings, customizable via the environment for platforms or contexts
/// where standard SwiftUI `SettingsLink` is not available or custom navigation is needed.
struct OpenSettingsAction: Sendable {
    private let action: @MainActor (SettingsSection?) -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = { _ in action() }
    }

    init(action: @escaping @MainActor (SettingsSection?) -> Void) {
        self.action = action
    }

    @MainActor
    func callAsFunction(_ section: SettingsSection? = nil) {
        action(section)
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
    let section: SettingsSection?
    @ViewBuilder let label: () -> Label

    init(section: SettingsSection? = nil, @ViewBuilder label: @escaping () -> Label) {
        self.section = section
        self.label = label
    }

    var body: some View {
#if os(macOS)
        if let openSettingsAction {
            Button(action: { openSettingsAction(section) }, label: label)
        } else {
            SettingsLink(label: label)
        }
#else
        Button(action: { openSettingsAction?(section) }, label: label)
#endif
    }
}
