import Foundation
import OSLog
import Observation
import SwiftData

@MainActor
@Observable
final class LibraryStartup {
    private(set) var container: ModelContainer?
    private(set) var failed = false
    let support: URL
    var backups: URL { support.appending(path: "AudioNotes/Backups") }

    init(support: URL = AppStorageLocations.applicationSupport()) {
        self.support = support
        retry()
    }

    func retry() {
        do {
#if DEBUG
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                || NSClassFromString("XCTestCase") != nil
                || ProcessInfo.processInfo.arguments.contains("--performance-fixtures")
                || ProcessInfo.processInfo.arguments.contains("--performance-empty-library") {
                container = try LibraryStorage().makeContainer(inMemory: true)
                failed = false
                return
            }
#endif
            try ManagedFileDeletion(root: support.appending(path: "AudioNotes")).recover()
            let opened = try LibraryStorage(rootURL: support.appending(path: "AudioNotes"))
                .makeContainer(databaseURL: support.appending(path: "default.store"))
            let context = ModelContext(opened)
            try UsageRepository().markInterruptedOperations(context: context)
            try SourceCompatibilityMigration().backfill(context: context)
            let interrupted = try context.fetch(FetchDescriptor<RecordingSource>(predicate: #Predicate { $0.statusRaw == "processing" }))
            for source in interrupted {
                source.status = .failed
                source.processingError = "Processing was interrupted. Retry to extract this source again."
            }
            if !interrupted.isEmpty { try context.save() }
            container = opened
            failed = false
        } catch {
            container = nil
            failed = true
            ReleaseLog.persistence.error("Library open failed; originals retained.")
        }
    }
}
