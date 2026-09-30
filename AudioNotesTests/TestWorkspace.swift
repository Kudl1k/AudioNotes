import AVFoundation
import Foundation
import Testing
@testable import AudioNotes

struct TestWorkspace {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    var storage: LibraryStorage { LibraryStorage(rootURL: root.appending(path: "Library")) }

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func makeAudio(name: String = "Meeting.wav") throws -> URL {
        let url = root.appending(path: name)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = 8_000
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<8_000 { samples[index] = 0 }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    func importedFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: storage.recordingsURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: storage.recordingsURL, includingPropertiesForKeys: nil)
    }
}
