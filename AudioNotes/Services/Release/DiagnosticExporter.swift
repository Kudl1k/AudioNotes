import Foundation

/// Allowlisted snapshot only. No database, defaults, environment, logs or credentials.
struct DiagnosticReport: Codable, Sendable {
    let application: ReleaseIdentity
    let macOS: String
    let architecture: String
    let schema: String
    let updateConfigured: Bool
    let libraryOpenFailed: Bool

    init(application: ReleaseIdentity = ReleaseIdentity(), updateConfigured: Bool, libraryOpenFailed: Bool) {
        self.application = application
        macOS = ProcessInfo.processInfo.operatingSystemVersionString
#if arch(arm64)
        architecture = "arm64"
#else
        architecture = "x86_64"
#endif
        schema = "1.0.0"
        self.updateConfigured = updateConfigured
        self.libraryOpenFailed = libraryOpenFailed
    }

    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

actor DiagnosticExporter {
    func export(_ report: DiagnosticReport, to url: URL) throws {
        let bytes = try report.data()
        try Task.checkCancellation()
        try bytes.write(to: url, options: .atomic)
    }
}
