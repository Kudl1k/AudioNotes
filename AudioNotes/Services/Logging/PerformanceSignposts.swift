import OSLog

/// Static operation names only: no source text, filenames, IDs, or credentials.
enum PerformanceSignposts {
    private static let signposter = OSSignposter(subsystem: "cz.kudladev.AudioNotes", category: "Performance")
    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name, id: signposter.makeSignpostID())
    }
    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }
}
