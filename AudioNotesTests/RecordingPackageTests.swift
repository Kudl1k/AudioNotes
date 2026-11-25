import Foundation
import SwiftData
import Testing
@testable import AudioNotes

@MainActor
struct RecordingPackageTests {
    @Test func restoresManagedFilesAndFinishedTranscriptWithoutGeneration() async throws {
        let sender = try TestWorkspace(); defer { sender.cleanUp() }
        let recipient = try TestWorkspace(); defer { recipient.cleanUp() }
        let fixture = try makeRecording(sender)
        let codec = RecordingPackageCodec()
        let url = sender.root.appending(path: "example.soniquill")
        let snapshot = try RecordingPackageSnapshot(recording: fixture.recording, selected: [fixture.attachment.id],
                                                    storage: sender.storage)
        try await codec.export(snapshot, to: url)
        let staged = try await codec.stage(url, under: recipient.storage.rootURL)
        let container = try recipient.storage.makeContainer(inMemory: true)
        let id = try RecordingPackageImport.commit(staged, storage: recipient.storage, container: container)
        let recording = try #require(container.mainContext.fetch(FetchDescriptor<Recording>()).first)
        let segment = try #require(recording.transcript?.orderedSegments.first)
        #expect(recording.id == id)
        #expect(recording.title == fixture.recording.title)
        #expect(segment.id == fixture.segment.id)
        #expect(segment.startTime == 0.25)
        #expect(segment.endTime == 0.75)
        #expect(segment.text == "Ahoj, světe.")
        #expect(segment.speaker == "Eva")
        #expect(recording.duration == 1)
        #expect(recording.sources.count == 2)
        let primarySource = recording.sources.first(where: \.isPrimaryAudio)
        let primary = try #require(primarySource)
        #expect(primary.isContextReady)
        let audioURL = recipient.storage.recordingURL(fileName: recording.audioFileName)
        #expect(try Data(contentsOf: audioURL) == Data(contentsOf: snapshot.files[0].url))
        let playback = AudioPlaybackService()
        playback.load(url: audioURL)
        playback.seek(to: segment.startTime)
        #expect(abs(playback.currentTime - 0.25) < 0.01)
        let attachment = try #require(recording.sources.first(where: { !$0.isPrimaryAudio }))
        #expect(try Data(contentsOf: recipient.storage.sourceURL(attachment)) == Data("notes".utf8))
        #expect(try container.mainContext.fetchCount(FetchDescriptor<GenerationRecord>()) == 0)
        let duplicate = try await codec.stage(url, under: recipient.storage.rootURL)
        #expect(throws: RecordingPackageError.duplicate) {
            try RecordingPackageImport.commit(duplicate, storage: recipient.storage, container: container)
        }
        #expect(try recipient.importedFiles().count == 1)
        #expect(!FileManager.default.fileExists(atPath: duplicate.directory.path))
    }

    @Test func rejectsCorruptionTruncationAndUnsupportedVersionWithoutStagingResidue() async throws {
        let sender = try TestWorkspace(); defer { sender.cleanUp() }
        let recipient = try TestWorkspace(); defer { recipient.cleanUp() }
        let fixture = try makeRecording(sender)
        let codec = RecordingPackageCodec()
        let url = sender.root.appending(path: "valid.soniquill")
        let snapshot = try RecordingPackageSnapshot(recording: fixture.recording, selected: [], storage: sender.storage)
        try await codec.export(snapshot, to: url)
        let clean = try Data(contentsOf: url)
        for (name, payload) in [
            ("corrupt", clean.dropLast() + Data([clean.last! ^ 0xff])),
            ("truncated", Data(clean.dropLast())),
            ("trailing", clean + Data([0]))
        ] {
            let bad = sender.root.appending(path: "\(name).soniquill")
            try payload.write(to: bad)
            await #expect(throws: RecordingPackageError.invalid) {
                try await codec.stage(bad, under: recipient.storage.rootURL)
            }
        }
        var unsupported = clean
        let version = try #require(unsupported.range(of: Data("\"version\":1".utf8)))
        unsupported[version.upperBound - 1] = 57
        let badVersion = sender.root.appending(path: "version.soniquill")
        try unsupported.write(to: badVersion)
        await #expect(throws: RecordingPackageError.unsupportedVersion) {
            try await codec.stage(badVersion, under: recipient.storage.rootURL)
        }
        var malformed = clean
        let extensionField = try #require(malformed.range(of: Data("\"ext\":\"wav\"".utf8)))
        malformed.replaceSubrange((extensionField.upperBound - 4)..<(extensionField.upperBound - 1), with: Data("../".utf8))
        let badExtension = sender.root.appending(path: "extension.soniquill")
        try malformed.write(to: badExtension)
        await #expect(throws: RecordingPackageError.invalid) {
            try await codec.stage(badExtension, under: recipient.storage.rootURL)
        }
        let residue = try FileManager.default.contentsOfDirectory(atPath: recipient.storage.rootURL.path)
        #expect(residue.isEmpty)
    }

    @Test func missingAttachmentDoesNotProduceAnExportAndFailedCommitRollsBackFiles() async throws {
        let sender = try TestWorkspace(); defer { sender.cleanUp() }
        let recipient = try TestWorkspace(); defer { recipient.cleanUp() }
        let fixture = try makeRecording(sender)
        let snapshot = try RecordingPackageSnapshot(recording: fixture.recording, selected: [fixture.attachment.id],
                                                    storage: sender.storage)
        let codec = RecordingPackageCodec()
        let url = sender.root.appending(path: "example.soniquill")
        try await codec.export(snapshot, to: url)
        let staged = try await codec.stage(url, under: recipient.storage.rootURL)
        try FileManager.default.removeItem(at: staged.urls[1])
        let container = try recipient.storage.makeContainer(inMemory: true)
        #expect(throws: (any Error).self) {
            try RecordingPackageImport.commit(staged, storage: recipient.storage, container: container)
        }
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Recording>()) == 0)
        #expect(try recipient.importedFiles().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: staged.directory.path))
        try FileManager.default.removeItem(at: snapshot.files[1].url)
        let missing = sender.root.appending(path: "missing.soniquill")
        await #expect(throws: (any Error).self) { try await codec.export(snapshot, to: missing) }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func recoveryRemovesAbandonedPublicationButKeepsCommittedFiles() throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let storage = workspace.storage
        let container = try storage.makeContainer(inMemory: true)
        let context = container.mainContext
        let fm = FileManager.default
        try fm.createDirectory(at: storage.recordingsURL, withIntermediateDirectories: true)
        for committed in [false, true] {
            let id = UUID()
            let source = UUID()
            let filename = "\(UUID()).wav"
            let audio = storage.recordingURL(fileName: filename)
            let folder = storage.rootURL.appending(path: "SharingImport-\(UUID())")
            let directory = storage.sourceDirectory(id: source)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([0]).write(to: audio)
            let journal = ["recordingID": id.uuidString, "audioName": filename, "sourceIDs": [source.uuidString]] as [String: Any]
            try JSONSerialization.data(withJSONObject: journal).write(to: folder.appending(path: "publication.json"))
            if committed {
                context.insert(Recording(id: id, title: "Committed", audioFileName: filename,
                                         originalFileName: "Audio.wav", duration: 1))
                try context.save()
            }
            try RecordingPackageImport.recover(storage: storage, context: context)
            #expect(fm.fileExists(atPath: audio.path) == committed)
            #expect(fm.fileExists(atPath: directory.path) == committed)
            #expect(!fm.fileExists(atPath: folder.path))
        }
    }

    private func makeRecording(_ workspace: TestWorkspace) throws -> (
        recording: Recording, segment: TranscriptSegment, attachment: RecordingSource
    ) {
        let audio = try workspace.makeAudio()
        let storage = workspace.storage
        try FileManager.default.createDirectory(at: storage.recordingsURL, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: audio, to: storage.recordingURL(fileName: audio.lastPathComponent))
        let recording = Recording(title: "Rozhovor", audioFileName: audio.lastPathComponent,
                                  originalFileName: "Rozhovor.wav", duration: 1)
        let transcript = Transcript(languageCode: "cs")
        let segment = TranscriptSegment(position: 0, startTime: 0.25, endTime: 0.75,
                                        text: "Ahoj, světe.", speaker: "Eva")
        transcript.segments = [segment]
        recording.transcript = transcript
        let attachment = RecordingSource(type: .document, displayName: "Notes", originalFilename: "notes.txt",
                                         localFileReference: "original.txt")
        let excluded = RecordingSource(type: .document, displayName: "Private", originalFilename: "private.txt",
                                       localFileReference: "original.txt")
        try FileManager.default.createDirectory(at: storage.sourceDirectory(id: attachment.id), withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: storage.sourceURL(attachment))
        recording.sources = [attachment, excluded]
        return (recording, segment, attachment)
    }
}
