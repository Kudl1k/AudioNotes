import Foundation

/// Network and decoding errors retain only safe status/code diagnostics, never bodies or headers.
actor OpenAITranscriptionClient {
    static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    private let session: URLSession
    private let uploads = OpenAIAudioUpload()

    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.timeoutIntervalForRequest = 600
            configuration.timeoutIntervalForResource = 1800
            self.session = URLSession(configuration: configuration)
        }
    }

    func transcribe(fileURL: URL, apiKey: String, configuration: OpenAITranscriptionConfiguration) async throws -> OpenAITranscriptionResponse {
        let body = try await uploads.prepare(fileURL: fileURL, configuration: configuration)
        try Task.checkCancellation()
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, from: body.data, delegate: RefuseRedirects())
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw OpenAITranscriptionError.network(code: (error as? URLError)?.errorCode ?? URLError.unknown.rawValue)
        }
        guard let http = response as? HTTPURLResponse else { throw OpenAITranscriptionError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenAIHTTPError(reason: Self.error(for: http.statusCode, data: data), response: http, data: data)
        }
        do { return try JSONDecoder().decode(OpenAITranscriptionResponse.self, from: data) }
        catch { throw OpenAITranscriptionError.invalidResponse }
    }

    static func error(for status: Int, data: Data) -> OpenAITranscriptionError {
        switch status {
        case 401: .invalidAuthentication
        case 403: .accessDenied
        case 413: .fileTooLarge(limit: OpenAIAudioUpload.maximumFileBytes)
        case 415: .unsupportedAudio
        case 429:
            quotaOrRateError(data: data)
        case 500...599: .server(status: status)
        default: .rejected(status: status)
        }
    }

    private static func quotaOrRateError(data: Data) -> OpenAITranscriptionError {
        let details = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data).error
        switch details?.code {
        case "credit_balance_exhausted": return .creditBalanceExhausted
        case "organization_spend_limit_exceeded": return .organizationSpendLimit
        case "project_spend_limit_exceeded": return .projectSpendLimit
        case "organization_usage_limit_exceeded": return .organizationUsageLimit
        case "insufficient_quota": return .quotaExceeded
        default: return details?.type == "insufficient_quota" ? .quotaExceeded : .rateLimited
        }
    }

}

final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
