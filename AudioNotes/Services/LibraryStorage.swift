import Foundation
import SwiftData

struct LibraryStorage: Sendable {
    let rootURL: URL

    init(rootURL: URL = AppStorageLocations.applicationSupport().appending(path: "AudioNotes", directoryHint: .isDirectory)) {
        self.rootURL = rootURL
    }

    var recordingsURL: URL { rootURL.appending(path: "Recordings", directoryHint: .isDirectory) }

    func recordingURL(fileName: String) -> URL {
        recordingsURL.appendingPathComponent(fileName)
    }

    @MainActor
    func makeContainer(inMemory: Bool = false, databaseURL: URL? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: LibrarySchemaV1.self)
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            let database = databaseURL ?? rootURL.appending(path: "Library.store")
            try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
            try MetadataBackup().prepareBaseline(database: database, backups: rootURL.appending(path: "Backups"))
            configuration = ModelConfiguration(schema: schema, url: database)
        }
        return try ModelContainer(for: schema, migrationPlan: LibraryMigrationPlan.self, configurations: [configuration])
    }
}
