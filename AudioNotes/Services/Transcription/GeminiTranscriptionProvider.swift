import Foundation
import AVFoundation

/// Gemini's official Files API + Interactions transcription flow. Uploaded files are
/// explicitly deleted on every exit path; Google also expires them after 48 hours.
@MainActor
struct GeminiTranscriptionProvider: TranscriptionProvider {
    let model: String
    let oauth: GoogleGeminiOAuthService
    var displayName: String { "Gemini · \(model)" }
    var providerID: String? { "gemini" }
    var modelID: String? { model }
    var modelDisplayName: String? { "Gemini 3.5 Transcribe" }
    var capabilities: TranscriptionProviderCapabilities {
        .init(maxDirectUploadSize: nil, maxProviderFileUploadSize: 2_000_000_000, supportsProviderFileUpload: true, supportsTimestamps: true,
              supportsDiarization: true, maximumDuration: 1_800, requiresChunking: false)
    }
    var authenticationMethod: ProviderAuthenticationMethod? { .oauth }

    func transcribe(audioURL: URL, progress: @escaping TranscriptionProgress) async throws -> Transcript {
        try await transcribe(audioURL: audioURL, progress: progress, status: { _ in })
    }

    func transcribe(audioURL: URL, progress: @escaping TranscriptionProgress,
                    status: @escaping TranscriptionStatusReporter) async throws -> Transcript {
        try await transcribe(audioURL: audioURL, progress: progress, status: status, usage: { _ in })
    }

    func transcribe(audioURL: URL, progress: @escaping TranscriptionProgress,
                    status: @escaping TranscriptionStatusReporter,
                    usage: @escaping @MainActor (TranscriptionRequestEvent) -> Void) async throws -> Transcript {
        try Task.checkCancellation()
        let duration = try await Self.duration(of: audioURL)
        // This provider always requests word timestamps and speaker attribution.
        // Google's documented limit with either feature enabled is 30 minutes.
        guard duration > 0, duration <= 1_800 else { throw GeminiTranscriptionError.durationLimit }
        guard let mime = Self.mimeType(for: audioURL) else { throw GeminiTranscriptionError.unsupportedAudio }
        guard let size = try audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              Int64(size) <= (capabilities.maxProviderFileUploadSize ?? 0) else { throw GeminiTranscriptionError.fileTooLarge }
        status(.init(phase: .preparing, currentPart: nil, totalParts: nil, completedParts: 0,
                     processedAudioDuration: 0, totalAudioDuration: duration))
        progress(nil)
        let client = GeminiTranscriptionHTTPClient(oauth: oauth)
        status(.init(phase: .uploading, currentPart: nil, totalParts: nil, completedParts: 0,
                     processedAudioDuration: 0, totalAudioDuration: duration))
        let uploaded = try await client.upload(fileURL: audioURL, mimeType: mime)
        defer { Task { await client.delete(fileName: uploaded.name) } }
        try Task.checkCancellation()
        status(.init(phase: .processing, currentPart: nil, totalParts: nil, completedParts: 0,
                     processedAudioDuration: 0, totalAudioDuration: duration))
        let requestID = UUID()
        usage(.began(requestID))
        do {
            let data = try await client.transcribe(uri: uploaded.uri, mimeType: uploaded.mimeType, model: model)
            try Task.checkCancellation()
            let transcript = try GeminiTranscriptMapper.makeTranscript(from: data, model: model, duration: duration)
            usage(.finished(requestID, TranscriptionUsage(recordingDuration: Decimal(string: String(duration)),
                processedDuration: Decimal(string: String(duration))), true))
            status(.init(phase: .merging, currentPart: nil, totalParts: 1, completedParts: 1,
                         processedAudioDuration: duration, totalAudioDuration: duration))
            progress(1)
            return transcript
        } catch {
            usage(.finished(requestID, nil, false))
            throw error
        }
    }

    private static func duration(of url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let value = try await asset.load(.duration).seconds
        guard value.isFinite else { throw GeminiTranscriptionError.invalidAudio }
        return value
    }

    nonisolated static func mimeType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "wav": "audio/wav"
        case "mp3": "audio/mp3"
        case "aiff", "aif": "audio/aiff"
        case "aac": "audio/aac"
        case "ogg": "audio/ogg"
        case "flac": "audio/flac"
        case "m4a": "audio/mp4"
        case "opus": "audio/opus"
        default: nil
        }
    }
}

enum GeminiTranscriptionError: LocalizedError {
    case durationLimit, unsupportedAudio, invalidAudio, invalidResponse, uploadFailed, fileTooLarge, requestFailed(Int)
    var errorDescription: String? {
        switch self {
        case .durationLimit: "Gemini timestamped transcription supports recordings up to 30 minutes. Choose another transcription provider for longer audio."
        case .unsupportedAudio: "Gemini does not support this audio format. Convert it to WAV, MP3, AAC, FLAC, OGG, AIFF, M4A, or Opus."
        case .invalidAudio: "The selected audio file has an invalid duration."
        case .invalidResponse: "Gemini returned an invalid transcription response."
        case .uploadFailed: "Gemini could not upload the audio file. Try again."
        case .fileTooLarge: "Gemini Files API supports files up to 2 GB. Choose another transcription provider for this file."
        case .requestFailed(let status): "Gemini transcription failed (HTTP \(status)). Check Google Cloud project access and billing."
        }
    }
}

enum GeminiTranscriptMapper {
    static func makeTranscript(from data: Data, model: String = "gemini-3.5-transcribe", duration: TimeInterval) throws -> Transcript {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? String == "completed",
              let steps = root["steps"] as? [[String: Any]] else { throw GeminiTranscriptionError.invalidResponse }
        var words: [(start: Double, end: Double, text: String, speaker: String?)] = []
        var fallbackText = ""
        for step in steps where step["type"] as? String == "model_output" {
            for content in step["content"] as? [[String: Any]] ?? [] {
                if let text = content["text"] as? String { fallbackText += text }
                for annotation in content["annotations"] as? [[String: Any]] ?? [] where annotation["type"] as? String == "word_info" {
                    guard let text = annotation["text"] as? String,
                          let start = seconds(annotation["start_offset"]), let end = seconds(annotation["end_offset"]),
                          start >= 0, end >= start, start <= duration else { continue }
                    let rawSpeaker = annotation["speaker"] as? String
                    let speaker = rawSpeaker.flatMap { value -> String? in
                        guard value.hasPrefix("spk_"), let number = Int(value.dropFirst(4)), number > 0 else { return nil }
                        return "Speaker \(number)"
                    }
                    words.append((start, min(duration, end), text, speaker))
                }
            }
        }
        let transcript = Transcript(sourceName: "Gemini · \(model)")
        if !words.isEmpty {
            transcript.segments = words.enumerated().map { index, word in
                TranscriptSegment(position: index, startTime: word.start, endTime: word.end,
                                  text: word.text, speaker: word.speaker)
            }
        } else {
            let trimmed = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw GeminiTranscriptionError.invalidResponse }
            transcript.segments = [TranscriptSegment(position: 0, startTime: 0, endTime: duration, text: trimmed)]
        }
        return transcript
    }

    private static func seconds(_ value: Any?) -> Double? {
        guard let value = value as? String, value.hasSuffix("s"),
              let seconds = Double(value.dropLast()), seconds.isFinite else { return nil }
        return seconds
    }
}

enum GeminiTranscriptionRequestBuilder {
    static func body(model: String, uri: String, mimeType: String) -> [String: Any] {
        [
            "model": model,
            "input": [["type": "audio", "uri": uri, "mime_type": mimeType]],
            "store": false,
            "generation_config": ["transcription_config": ["mode": [
                "type": "verbatim",
                "diarization_mode": "speaker",
                "timestamp_granularities": ["word"]
            ]]]
        ]
    }
}

private actor GeminiTranscriptionHTTPClient {
    struct UploadedFile { let name: String; let uri: String; let mimeType: String }
    let oauth: GoogleGeminiOAuthService
    init(oauth: GoogleGeminiOAuthService) { self.oauth = oauth }
    let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 600; config.timeoutIntervalForResource = 1800
        return URLSession(configuration: config)
    }()

    func upload(fileURL: URL, mimeType: String) async throws -> UploadedFile {
        let headers = try await oauth.requestHeaders()
        var start = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/upload/v1beta/files")!)
        start.httpMethod = "POST"
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        start.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        start.setValue(String(fileSize), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { start.setValue(value, forHTTPHeaderField: key) }
        start.httpBody = try JSONSerialization.data(withJSONObject: ["file": ["display_name": "Soniquill audio upload"]])
        let (_, response) = try await session.data(for: start)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let uploadURLText = http.value(forHTTPHeaderField: "X-Goog-Upload-URL"),
              let uploadURL = Self.validatedUploadURL(uploadURLText) else {
            throw GeminiTranscriptionError.uploadFailed
        }
        try Task.checkCancellation()
        var finish = URLRequest(url: uploadURL)
        finish.httpMethod = "POST"
        finish.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        finish.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        finish.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { finish.setValue(value, forHTTPHeaderField: key) }
        let data: Data
        let finalResponse: URLResponse
        do {
            (data, finalResponse) = try await session.upload(for: finish, fromFile: fileURL, delegate: RefuseRedirects())
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw error
        }
        guard let finalHTTP = finalResponse as? HTTPURLResponse, (200..<300).contains(finalHTTP.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let file = root["file"] as? [String: Any], let name = file["name"] as? String,
              let uri = file["uri"] as? String else { throw GeminiTranscriptionError.uploadFailed }
        return UploadedFile(name: name, uri: uri, mimeType: file["mimeType"] as? String ?? mimeType)
    }

    private static func validatedUploadURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https",
              url.host == "generativelanguage.googleapis.com", url.user == nil, url.password == nil else { return nil }
        return url
    }

    func transcribe(uri: String, mimeType: String, model: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in try await oauth.requestHeaders() { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: GeminiTranscriptionRequestBuilder.body(model: model, uri: uri, mimeType: mimeType))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GeminiTranscriptionError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw GeminiTranscriptionError.requestFailed(http.statusCode) }
        return data
    }

    func delete(fileName: String) async {
        guard let name = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/\(name)") else { return }
        var request = URLRequest(url: url); request.httpMethod = "DELETE"
        guard let headers = try? await oauth.requestHeaders() else { return }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        _ = try? await session.data(for: request)
    }
}
