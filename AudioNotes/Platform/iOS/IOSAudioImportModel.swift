#if os(iOS)
import Foundation
import Observation
import SwiftData

/// Library-owned batch task. Reuses the existing copy/save/rollback transaction.
@MainActor
@Observable
final class IOSAudioImportModel {
    let library: LibraryViewModel
    @ObservationIgnored private let storage: LibraryStorage
    private(set) var isCancelling = false
    private(set) var currentFile = 0
    private(set) var totalFiles = 0
    private(set) var startedAt: Date?
    var resultMessage: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(importer: any AudioImporting = AudioImportService(), storage: LibraryStorage = LibraryStorage()) {
        self.storage = storage
        library = LibraryViewModel(importer: importer)
    }

    var isImporting: Bool { task != nil }

    func start(_ urls: [URL], context: ModelContext) {
        guard task == nil, !urls.isEmpty else { return }
        resultMessage = nil
        library.error = nil
        isCancelling = false
        currentFile = 0
        totalFiles = urls.count
        startedAt = .now
        task = Task {
            let result = await library.importURLs(urls, into: SwiftDataRecordingRepository(context: context, storage: storage), failureMessage: Self.failureMessage, progress: {
                self.currentFile = $0
            })
            let noun = result.importedCount == 1 ? "recording" : "recordings"
            var message = "Imported \(result.importedCount) \(noun)."
            if result.cancelled { message += " Import cancelled; completed recordings were kept." }
            if !result.failures.isEmpty {
                message += "\n\(result.failures.count) file(s) could not be imported.\n\n" + result.failures.joined(separator: "\n\n")
            }
            resultMessage = message
            isCancelling = false
            task = nil
            startedAt = nil
        }
    }

    func cancel() { isCancelling = true; task?.cancel() }

    func waitUntilFinished() async { await task?.value }

    private static func failureMessage(_ error: Error) -> String {
        if let error = error as? AudioImportError { return error.localizedDescription }
        if let error = error as? CocoaError, error.code == .fileWriteOutOfSpace {
            return "There is not enough free storage to import this recording."
        }
        return "This file could not be imported. Check that it is downloaded in Files and that your device has free storage, then try again."
    }

    func pickerFailed() {
        resultMessage = "The selected files could not be opened. Try downloading them in Files, then import again."
    }
}
#endif
