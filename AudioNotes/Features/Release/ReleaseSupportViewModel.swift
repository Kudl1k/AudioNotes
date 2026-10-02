import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class ReleaseSupportViewModel {
    static let diagnosticsFileName = "AudioNotes-Diagnostics.json"
    static let diagnosticsTypes: [UTType] = [.json]
    static let diagnosticsDisclosure = "Includes app version, macOS, architecture, schema and update availability. Projects, recordings, transcripts, chats, filenames, credentials and logs are excluded."

    private(set) var exporting = false
    var errorMessage: String?
    private let exporter = DiagnosticExporter()

    func exportDiagnostics(to url: URL, updateConfigured: Bool, libraryOpenFailed: Bool) async {
        exporting = true
        errorMessage = nil
        defer { exporting = false }
        do {
            try await exporter.export(DiagnosticReport(updateConfigured: updateConfigured, libraryOpenFailed: libraryOpenFailed), to: url)
        } catch is CancellationError {
        } catch {
            errorMessage = "The diagnostic file could not be saved. Check the destination and available space, then try again."
        }
    }
}
