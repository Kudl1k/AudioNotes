import AppKit

/// Finder and default-application integration.
@MainActor
enum Workspace {
    static func revealInFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @discardableResult
    static func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

/// Opens OAuth authorization pages in the user's default browser.
struct SystemBrowserOpener: BrowserOpening {
    @MainActor func open(_ url: URL) -> Bool {
        Workspace.open(url)
    }
}
