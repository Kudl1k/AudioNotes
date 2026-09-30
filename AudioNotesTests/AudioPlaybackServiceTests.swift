import Foundation
import Testing
@testable import AudioNotes

@MainActor
struct AudioPlaybackServiceTests {
    @Test func loadsSeeksAndResets() throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let service = AudioPlaybackService()
        service.load(url: try workspace.makeAudio())
        #expect(service.isLoaded)
        #expect(service.errorMessage == nil)
        #expect(abs(service.duration - 1) < 0.01)
        service.seek(to: 0.5)
        #expect(service.currentTime == 0.5)
        service.seek(to: -10)
        #expect(service.currentTime == 0)
        service.seek(to: 100)
        #expect(service.currentTime == service.duration)
        service.seek(to: .nan)
        #expect(service.currentTime == service.duration)
        service.stop()
        #expect(!service.isLoaded)
        #expect(!service.isPlaying)
        #expect(service.duration == 0)
        #expect(service.currentTime == 0)
    }

    @Test func failedLoadClearsPreviousAudioAndCanRecover() throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let source = try workspace.makeAudio()
        let service = AudioPlaybackService()
        service.load(url: source)
        service.load(url: workspace.root.appending(path: "missing.wav"))
        #expect(!service.isLoaded)
        #expect(service.duration == 0)
        #expect(service.errorMessage != nil)
        service.togglePlayback()
        #expect(!service.isPlaying)
        service.load(url: source)
        #expect(service.isLoaded)
        #expect(service.errorMessage == nil)
        service.stop()
    }
}
