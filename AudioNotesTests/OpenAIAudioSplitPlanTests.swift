import AVFoundation
import Foundation
import Testing
@testable import AudioNotes

struct OpenAIAudioSplitPlanTests {
    @Test func smallUploadStaysAsOneOriginalPart() throws {
        let plan = try OpenAIAudioSplitPlan.make(duration: 3_600, fileSize: 20_000_000)
        #expect(plan.ranges == [OpenAIAudioPartRange(start: 0, duration: 3_600)])
    }

    @Test func oversizedAudioSplitsIntoContiguousBoundedRanges() throws {
        let plan = try OpenAIAudioSplitPlan.make(duration: 3_600, fileSize: 90_000_000)
        #expect(plan.ranges.count > 1)
        #expect(plan.ranges.allSatisfy { $0.duration <= 600 })
        #expect(abs(plan.ranges.reduce(0) { $0 + $1.duration } - 3_600) < 0.001)
        for pair in zip(plan.ranges, plan.ranges.dropFirst()) {
            #expect(abs(pair.0.start + pair.0.duration - pair.1.start) < 0.001)
        }
    }

    @Test func oversizedWaveIsExportedAsCompressedPartsBelowLimit() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let input = workspace.root.appending(path: "long.wav")
        do {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
            let file = try AVAudioFile(forWriting: input, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000 * 10))
            buffer.frameLength = buffer.frameCapacity
            try file.write(from: buffer)
            try file.write(from: buffer)
            try file.write(from: buffer)
        }

        let splitter = OpenAIAudioSplitter(maximumBytes: 1_000_000, maximumPartDuration: 10)
        let result = try await splitter.prepare(fileURL: input)
        defer { if let directory = result.directory { try? FileManager.default.removeItem(at: directory) } }
        #expect(result.wasSplit)
        #expect(result.parts.count > 1)
        #expect(abs(result.parts.reduce(0) { $0 + $1.duration } - result.totalDuration) < 0.01)
        for part in result.parts {
            let size = try #require(part.url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            #expect(size <= 1_000_000)
            #expect(part.url.pathExtension == "m4a")
        }
    }
}
