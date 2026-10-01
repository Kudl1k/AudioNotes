import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class ReleaseSupportViewModel {
    private(set) var exporting = false
    var errorMessage: String?
    private let exporter = DiagnosticExporter()

    func exportDiagnostics(updateConfigured: Bool, libraryOpenFailed: Bool) async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "AudioNotes-Diagnostics.json"
        panel.message = "Includes app version, macOS, architecture, schema and update availability. Projects, recordings, transcripts, chats, filenames, credentials and logs are excluded."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporting = true
        defer { exporting = false }
        do {
            try await exporter.export(DiagnosticReport(updateConfigured: updateConfigured, libraryOpenFailed: libraryOpenFailed), to: url)
        } catch is CancellationError {
        } catch {
            errorMessage = "The diagnostic file could not be saved. Check the destination and available space, then try again."
        }
    }
}
