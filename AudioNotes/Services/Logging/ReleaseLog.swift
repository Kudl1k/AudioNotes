import OSLog

/// Only static event strings/status codes may reach these loggers. Never content/errors/paths.
enum ReleaseLog {
    static let app = Logger(subsystem: "cz.stepankudlacek.audionotes", category: "app")
    static let persistence = Logger(subsystem: "cz.stepankudlacek.audionotes", category: "persistence")
    static let updater = Logger(subsystem: "cz.stepankudlacek.audionotes", category: "updater")
}
