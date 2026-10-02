#if os(iOS)
import UIKit

/// Opens OAuth authorization pages in the user's default browser on iOS.
struct SystemBrowserOpener: BrowserOpening {
    @MainActor func open(_ url: URL) -> Bool {
        guard UIApplication.shared.canOpenURL(url) else { return false }
        UIApplication.shared.open(url)
        return true
    }
}
#endif
