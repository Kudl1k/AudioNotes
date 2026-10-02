#if os(iOS)
import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import AudioNotes

@MainActor
struct IOSAudioRecordingTests {
    @Test func nativeBatchOwnerReportsResultAndPersistsManagedRecordings() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let context = ModelContext(try workspace.storage.makeContainer())
        let source = try workspace.makeAudio()
        let model = IOSAudioImportModel(importer: AudioImportService(storage: workspace.storage), storage: workspace.storage)
        model.start([source, source], context: context)
        #expect(model.isImporting)
        await model.waitUntilFinished()
        #expect(!model.isImporting)
        #expect(model.currentFile == 2)
        #expect(model.resultMessage == "Imported 2 recordings.")
        let reopened = ModelContext(try workspace.storage.makeContainer())
        #expect(try reopened.fetchCount(FetchDescriptor<Recording>()) == 2)
        #expect(try workspace.importedFiles().count == 2)
    }

    @Test func cancelBeforeBatchWorkCreatesNoRowsOrFiles() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let context = ModelContext(try workspace.storage.makeContainer(inMemory: true))
        let model = IOSAudioImportModel(importer: AudioImportService(storage: workspace.storage), storage: workspace.storage)
        model.start([try workspace.makeAudio()], context: context)
        model.cancel()
        await model.waitUntilFinished()
        #expect(model.resultMessage?.contains("cancelled") == true)
        #expect(try context.fetchCount(FetchDescriptor<Recording>()) == 0)
        #expect(try workspace.importedFiles().isEmpty)
    }

    @Test func missingManagedAudioHasFriendlyError() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let model = IOSRecordingPlaybackModel()
        await model.load(url: workspace.root.appending(path: "missing.wav"))
        #expect(!model.playback.isLoaded)
        #expect(model.playback.errorMessage == "This recording could not be opened. Its managed audio may be missing or damaged.")
    }

    @Test func transcriptSeekAndLifecyclePauseKeepPositionUntilStopped() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let model = IOSRecordingPlaybackModel()
        await model.load(url: try workspace.makeAudio())
        let segment = TranscriptSegment(position: 0, startTime: 0.5, endTime: 0.8, text: "Příliš žluťoučký kůň")
        model.seek(to: segment.startTime)
        #expect(model.playback.currentTime == 0.5)
        model.handleInterruption(Notification(name: AVAudioSession.interruptionNotification,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]))
        #expect(!model.playback.isPlaying)
        #expect(model.playback.currentTime == 0.5)
        model.pause()
        #expect(model.playback.currentTime == 0.5)
        model.stop()
        #expect(!model.playback.isLoaded)
    }
}
#endif
