#if os(macOS)
import AppKit

/// Modal alerts for menu commands, which have no SwiftUI view to attach `.alert` to.
@MainActor
enum Alerts {
    static func show(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }
}
#endif
