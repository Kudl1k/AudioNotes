import AVFoundation
import Foundation

struct OpenAIMultipartBody: Sendable {
    let data: Data
    let contentType: String
}

/// Bounded file I/O and multipart assembly run off the UI actor.
actor OpenAIAudioUpload {
    // Conservative decimal MB interpretation of the documented 25 MB file limit.
    static let maximumFileBytes = 25_000_000
    static let mimeTypes = ["flac": "audio/flac", "ogg": "audio/ogg", "mp3": "audio/mpeg", "mp4": "audio/mp4", "mpeg": "audio/mpeg",
                            "mpga": "audio/mpeg", "m4a": "audio/mp4", "wav": "audio/wav", "webm": "audio/webm"]

    func prepare(fileURL: URL, configuration: OpenAITranscriptionConfiguration) async throws -> OpenAIMultipartBody {
        try Task.checkCancellation()
        let suffix = fileURL.pathExtension.lowercased()
        guard let mime = Self.mimeTypes[suffix] else { throw OpenAITranscriptionError.unsupportedAudio }
        var uncachedURL = fileURL
        uncachedURL.removeAllCachedResourceValues()
        guard fileURL.isFileURL, FileManager.default.isReadableFile(atPath: fileURL.path),
              let values = try? uncachedURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize else {
            throw OpenAITranscriptionError.audioUnavailable
        }
        guard size > 0 else { throw OpenAITranscriptionError.emptyAudio }
        guard size <= Self.maximumFileBytes else {
            throw OpenAITranscriptionError.fileTooLarge(limit: Self.maximumFileBytes)
        }
        let asset = AVURLAsset(url: fileURL)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let duration = try await asset.load(.duration).seconds
            guard !tracks.isEmpty, duration.isFinite, duration > 0 else { throw OpenAITranscriptionError.emptyAudio }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw OpenAITranscriptionError.emptyAudio
        }
        let boundary = "AudioNotes-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", configuration.model.rawValue)
        if configuration.model.supportsSegmentTimestamps {
            field("response_format", "verbose_json")
            field("timestamp_granularities[]", "segment")
        } else {
            field("response_format", "json")
        }
        if let language = configuration.language.code { field("language", language) }
        // Fixed filename avoids uploading the user's original filename or header injection.
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.\(suffix)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        do {
            let file = try FileHandle(forReadingFrom: fileURL)
            defer { try? file.close() }
            var bytesRead = 0
            while let chunk = try file.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                try Task.checkCancellation()
                bytesRead += chunk.count
                guard bytesRead <= Self.maximumFileBytes else {
                    throw OpenAITranscriptionError.fileTooLarge(limit: Self.maximumFileBytes)
                }
                body.append(chunk)
            }
            guard bytesRead == size else { throw OpenAITranscriptionError.audioUnavailable }
        } catch let error as OpenAITranscriptionError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw OpenAITranscriptionError.audioUnavailable }
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        try Task.checkCancellation()
        return OpenAIMultipartBody(data: body, contentType: "multipart/form-data; boundary=\(boundary)")
    }
}
