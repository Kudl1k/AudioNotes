#if os(macOS)
import AppKit

/// The general pasteboard, used for plain-text Copy actions.
@MainActor
enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
#elseif os(iOS)
import UIKit

@MainActor
enum Clipboard {
    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }
}
#endif
