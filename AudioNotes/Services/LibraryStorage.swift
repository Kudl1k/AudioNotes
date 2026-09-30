import Foundation
import SwiftData

struct LibraryStorage: Sendable {
    let rootURL: URL

    init(rootURL: URL = URL.applicationSupportDirectory.appending(path: "AudioNotes", directoryHint: .isDirectory)) {
        self.rootURL = rootURL
    }

    var recordingsURL: URL { rootURL.appending(path: "Recordings", directoryHint: .isDirectory) }

    func recordingURL(fileName: String) -> URL {
        recordingsURL.appendingPathComponent(fileName)
    }

    @MainActor
    func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([
            Recording.self, Transcript.self, TranscriptSegment.self,
            Summary.self, ChatSession.self, ChatMessage.self
        ])
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            configuration = ModelConfiguration(schema: schema, url: rootURL.appending(path: "Library.store"))
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
