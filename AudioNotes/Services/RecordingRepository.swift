import Foundation
import SwiftData

@MainActor
protocol RecordingStoring {
    func save(_ audio: ImportedAudio) throws
}

@MainActor
struct SwiftDataRecordingRepository: RecordingStoring {
    let context: ModelContext

    func save(_ audio: ImportedAudio) throws {
        let recording = Recording(id: audio.id, title: audio.title, audioFileName: audio.fileName,
                                  originalFileName: audio.originalFileName, duration: audio.duration)
        context.insert(recording)
        do {
            try context.save()
        } catch {
            context.delete(recording)
            throw error
        }
    }
}
