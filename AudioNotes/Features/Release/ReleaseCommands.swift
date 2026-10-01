import SwiftUI
import AppKit

struct ReleaseCommands: Commands {
    @ObservedObject var updates: UpdateService
    let startup: LibraryStartup
    @State private var support = ReleaseSupportViewModel()

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updates.checkForUpdates() }.disabled(!updates.canCheckForUpdates)
        }
        CommandGroup(replacing: .help) {
            Button("AudioNotes Help") { openInformation(.help) }
            Button("Privacy") { openInformation(.privacy) }
            Button("Third-Party Licenses") { openInformation(.licenses) }
            Divider()
            Button("Export Diagnostics…") {
                Task { await support.exportDiagnostics(updateConfigured: updates.isConfigured, libraryOpenFailed: startup.failed)
                    if let message = support.errorMessage { let alert = NSAlert(); alert.messageText = message; alert.runModal() }
                }
            }.disabled(support.exporting)
            Button("Reveal Data Folder") { NSWorkspace.shared.open(startup.support) }
        }
    }

    private func openInformation(_ page: ReleaseInformationView.Page) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = page.rawValue
        window.contentView = NSHostingView(rootView: ReleaseInformationView(page: page, onDone: { [weak window] in window?.close() }))
        window.isReleasedWhenClosed = false
        // Window controller retains each local support window until it closes.
        ReleaseInformationWindow.show(window)
    }
}

@MainActor
private final class ReleaseInformationWindow: NSWindowController, NSWindowDelegate {
    private static var windows: [ReleaseInformationWindow] = []
    static func show(_ window: NSWindow) {
        let controller = ReleaseInformationWindow(window: window)
        windows.append(controller)
        window.delegate = controller
        window.center()
        controller.showWindow(nil)
    }
    func windowWillClose(_ notification: Notification) { Self.windows.removeAll { $0 === self } }
}
