import AVFoundation
import Foundation

struct OpenAIAudioPart: Sendable {
    let url: URL
    let startTime: TimeInterval
    let duration: TimeInterval
}

struct OpenAIAudioPartRange: Equatable, Sendable {
    let start: TimeInterval
    let duration: TimeInterval
}

struct OpenAIAudioSplitResult: Sendable {
    let directory: URL?
    let parts: [OpenAIAudioPart]
    let totalDuration: TimeInterval
    let wasSplit: Bool
}

protocol OpenAIAudioPreparing: Sendable {
    func prepare(fileURL: URL) async throws -> OpenAIAudioSplitResult
}

struct OpenAIAudioSplitPlan: Equatable, Sendable {
    let ranges: [OpenAIAudioPartRange]

    static func make(duration: TimeInterval, fileSize: Int, maximumBytes: Int = OpenAIAudioUpload.maximumFileBytes,
                     maximumPartDuration: TimeInterval = 600) throws -> OpenAIAudioSplitPlan {
        guard duration.isFinite, duration > 0, fileSize > 0 else { throw OpenAITranscriptionError.emptyAudio }
        guard fileSize > maximumBytes else {
            return OpenAIAudioSplitPlan(ranges: [OpenAIAudioPartRange(start: 0, duration: duration)])
        }
        let safeBytes = Double(maximumBytes) * 0.8
        let sizeBoundedDuration = duration * safeBytes / Double(fileSize)
        let partDuration = min(maximumPartDuration, sizeBoundedDuration)
        guard partDuration.isFinite, partDuration > 0 else {
            throw OpenAITranscriptionError.fileTooLarge(limit: maximumBytes)
        }
        guard duration / partDuration < 100_000 else { throw OpenAITranscriptionError.fileTooLarge(limit: maximumBytes) }
        let count = Int(ceil(duration / partDuration))
        return OpenAIAudioSplitPlan(ranges: (0..<count).map { index in
            let start = Double(index) * partDuration
            return OpenAIAudioPartRange(start: start, duration: min(partDuration, duration - start))
        })
    }
}

/// Produces short, compressed M4A parts in a temporary directory. The owner must
/// keep the returned directory alive through transcription and then remove it.
actor OpenAIAudioSplitter: OpenAIAudioPreparing {
    private let maximumBytes: Int
    private let maximumPartDuration: TimeInterval

    init(maximumBytes: Int = OpenAIAudioUpload.maximumFileBytes, maximumPartDuration: TimeInterval = 600) {
        self.maximumBytes = maximumBytes
        self.maximumPartDuration = maximumPartDuration
    }

    func prepare(fileURL: URL) async throws -> OpenAIAudioSplitResult {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: fileURL)
        let tracks: [AVAssetTrack]
        let assetDuration: CMTime
        let duration: TimeInterval
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
            assetDuration = try await asset.load(.duration)
            duration = assetDuration.seconds
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw OpenAITranscriptionError.emptyAudio
        }
        guard !tracks.isEmpty, duration.isFinite, duration > 0 else { throw OpenAITranscriptionError.emptyAudio }
        var resourceURL = fileURL
        resourceURL.removeAllCachedResourceValues()
        guard let size = try? resourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
            throw OpenAITranscriptionError.audioUnavailable
        }
        let plan = try OpenAIAudioSplitPlan.make(duration: duration, fileSize: size, maximumBytes: maximumBytes,
                                                 maximumPartDuration: maximumPartDuration)
        if plan.ranges.count == 1 {
            return OpenAIAudioSplitResult(directory: nil, parts: [OpenAIAudioPart(url: fileURL, startTime: 0, duration: duration)],
                          totalDuration: duration, wasSplit: false)
        }

        let directory = FileManager.default.temporaryDirectory.appending(path: "AudioNotes-Transcription-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            var parts: [OpenAIAudioPart] = []
            for (index, range) in plan.ranges.enumerated() {
                try Task.checkCancellation()
                let url = directory.appending(path: String(format: "part-%04d.m4a", index + 1))
                guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                    throw OpenAITranscriptionError.unsupportedAudio
                }
                let scale = assetDuration.timescale > 0 ? assetDuration.timescale : 600
                exporter.timeRange = CMTimeRange(start: CMTime(seconds: range.start, preferredTimescale: scale),
                                                 duration: CMTime(seconds: range.duration, preferredTimescale: scale))
                try await exporter.export(to: url, as: .m4a)
                try Task.checkCancellation()
                let actualSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
                guard actualSize <= maximumBytes else { throw OpenAITranscriptionError.fileTooLarge(limit: maximumBytes) }
                parts.append(OpenAIAudioPart(url: url, startTime: range.start, duration: range.duration))
            }
            return OpenAIAudioSplitResult(directory: directory, parts: parts, totalDuration: duration, wasSplit: true)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
}
