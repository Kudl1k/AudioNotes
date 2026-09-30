import Foundation
import Observation

@MainActor
@Observable
final class LibraryViewModel {
    var selection: UUID?
    var importError: String?
    private(set) var isImporting = false
    @ObservationIgnored private let importer: any AudioImporting

    init(importer: any AudioImporting = AudioImportService()) {
        self.importer = importer
    }

    func importURLs(_ urls: [URL], into repository: any RecordingStoring) async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        var failures: [String] = []
        for url in urls {
            if Task.isCancelled { break }
            do {
                let audio = try await importer.importFile(at: url)
                do {
                    try Task.checkCancellation()
                    try repository.save(audio)
                    selection = audio.id
                } catch {
                    do { try await importer.discard(audio) }
                    catch { failures.append("Could not remove unused copy: \(error.localizedDescription)") }
                    throw error
                }
            } catch is CancellationError {
                break
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { importError = failures.joined(separator: "\n\n") }
    }
}
