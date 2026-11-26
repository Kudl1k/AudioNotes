#if os(iOS)
import UIKit

/// Wraps `UIApplication.beginBackgroundTask` so a running Drive sync can finish after the app is backgrounded.
struct IOSBackgroundTaskExtension: BackgroundWorkExtending {
    @MainActor
    private final class Assertion {
        var identifier = UIBackgroundTaskIdentifier.invalid

        func end() {
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }

    func extend(_ name: String, expiration: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let assertion = Assertion()
        assertion.identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated {
                expiration()
                assertion.end()
            }
        }
        return { assertion.end() }
    }
}
#endif
