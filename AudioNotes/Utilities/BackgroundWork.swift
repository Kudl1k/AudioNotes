import Foundation

/// Asks the system for extra time to finish work that is already running when the app leaves the foreground.
@MainActor
protocol BackgroundWorkExtending {
    /// Begins an extension and returns a closure that ends it. `expiration` runs if the system reclaims the time
    /// first; it should cancel the work.
    func extend(_ name: String, expiration: @escaping @MainActor () -> Void) -> @MainActor () -> Void
}

/// macOS keeps running in the background, so there is nothing to request.
struct NoBackgroundWorkExtension: BackgroundWorkExtending {
    func extend(_ name: String, expiration: @escaping @MainActor () -> Void) -> @MainActor () -> Void { {} }
}

enum BackgroundWork {
    @MainActor static var platform: any BackgroundWorkExtending {
#if os(iOS)
        IOSBackgroundTaskExtension()
#else
        NoBackgroundWorkExtension()
#endif
    }
}
