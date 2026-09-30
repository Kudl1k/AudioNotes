import Foundation
import SwiftData
import Testing
@testable import AudioNotes

@MainActor
struct LibraryStorageTests {
    @Test func modelGraphPersistsAndCascades() throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let recordingID = UUID()
        do {
            let container = try workspace.storage.makeContainer()
            let context = ModelContext(container)
            let recording = Recording(id: recordingID, title: "Meeting", audioFileName: "audio.wav",
                                      originalFileName: "Meeting.wav", duration: 30)
            let transcript = Transcript(languageCode: "en")
            transcript.segments = [
                TranscriptSegment(position: 1, startTime: 10, endTime: 20, text: "Second"),
                TranscriptSegment(position: 0, startTime: 0, endTime: 10, text: "First", speaker: "Speaker 1")
            ]
            recording.transcript = transcript
            recording.summary = Summary(text: "Meeting notes")
            let session = ChatSession()
            session.messages = [ChatMessage(role: .user, text: "What happened?")]
            recording.chatSessions = [session]
            context.insert(recording)
            try context.save()
        }
        let container = try workspace.storage.makeContainer()
        let context = ModelContext(container)
        let recording = try #require(context.fetch(FetchDescriptor<Recording>()).first)
        #expect(recording.id == recordingID)
        #expect(recording.summary?.text == "Meeting notes")
        #expect(recording.transcript?.orderedSegments.map(\.text) == ["First", "Second"])
        #expect(recording.transcript?.recording?.id == recordingID)
        #expect(recording.chatSessions.first?.messages.first?.role == .user)
        #expect(recording.chatSessions.first?.messages.first?.session?.recording?.id == recordingID)
        context.delete(recording)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Recording>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Transcript>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<TranscriptSegment>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Summary>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ChatSession>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ChatMessage>()) == 0)
    }

    @Test func inMemoryStorageDoesNotCreateLibraryOnDisk() throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Recording>()) == 0)
        #expect(!FileManager.default.fileExists(atPath: workspace.storage.rootURL.path))
    }
}
