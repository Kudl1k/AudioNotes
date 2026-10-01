import Foundation
import Testing
@testable import AudioNotes

struct OpenAIAudioUploadTests {
    @Test func multipartContainsDocumentedFieldsAndOriginalAudioBytes() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let file = try workspace.makeAudio()
        let body = try await OpenAIAudioUpload().prepare(fileURL: file, configuration: .init(language: .czech))
        let text = String(decoding: body.data, as: UTF8.self)
        #expect(text.contains("name=\"model\"\r\n\r\nwhisper-1\r\n"))
        #expect(text.contains("name=\"response_format\"\r\n\r\nverbose_json\r\n"))
        #expect(text.contains("name=\"timestamp_granularities[]\"\r\n\r\nsegment\r\n"))
        #expect(text.contains("name=\"language\"\r\n\r\ncs\r\n"))
        #expect(text.contains("filename=\"recording.wav\""))
        #expect(!text.contains("Meeting.wav"))
        #expect(body.data.range(of: try Data(contentsOf: file)) != nil)
        let boundary = String(body.contentType.split(separator: "=").last ?? "")
        #expect(text.hasSuffix("\r\n--\(boundary)--\r\n"))
        let automatic = try await OpenAIAudioUpload().prepare(fileURL: file, configuration: .init())
        #expect(!String(decoding: automatic.data, as: UTF8.self).contains("name=\"language\""))
    }

    @Test func rejectsMissingUnsupportedEmptyCorruptAndOversizeFiles() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let uploader = OpenAIAudioUpload()
        await #expect(throws: OpenAITranscriptionError.audioUnavailable) {
            try await uploader.prepare(fileURL: workspace.root.appending(path: "missing.wav"), configuration: .init())
        }
        let unsupported = workspace.root.appending(path: "recording.aiff")
        try Data([1]).write(to: unsupported)
        await #expect(throws: OpenAITranscriptionError.unsupportedAudio) {
            try await uploader.prepare(fileURL: unsupported, configuration: .init())
        }
        let wav = workspace.root.appending(path: "empty.wav")
        try Data().write(to: wav)
        await #expect(throws: OpenAITranscriptionError.emptyAudio) {
            try await uploader.prepare(fileURL: wav, configuration: .init())
        }
        try Data("broken audio".utf8).write(to: wav)
        await #expect(throws: OpenAITranscriptionError.emptyAudio) {
            try await uploader.prepare(fileURL: wav, configuration: .init())
        }
        let handle = try FileHandle(forWritingTo: wav)
        try handle.truncate(atOffset: UInt64(OpenAIAudioUpload.maximumFileBytes + 1))
        try handle.close()
        await #expect(throws: OpenAITranscriptionError.fileTooLarge(limit: OpenAIAudioUpload.maximumFileBytes)) {
            try await uploader.prepare(fileURL: wav, configuration: .init())
        }
    }
}
