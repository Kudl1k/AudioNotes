import Foundation

struct OpenAIHTTPError: Error, LocalizedError, TranscriptionDiagnosticError, Sendable {
    let reason: OpenAITranscriptionError
    let status: Int
    let code: String?
    let requestID: String?
    let retryAfterSeconds: Int?

    init(reason: OpenAITranscriptionError, response: HTTPURLResponse, data: Data) {
        self.reason = reason
        status = response.statusCode
        let details = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data).error
        let knownCodes: Set<String> = [
            "insufficient_quota", "credit_balance_exhausted", "organization_spend_limit_exceeded",
            "project_spend_limit_exceeded", "organization_usage_limit_exceeded", "rate_limit_exceeded",
            "slow_down", "server_is_overloaded", "invalid_api_key", "model_not_found"
        ]
        code = details?.code.flatMap { knownCodes.contains($0) ? $0 : nil }
        let id = response.value(forHTTPHeaderField: "x-request-id")
        requestID = id.flatMap { value in
            value.range(of: "^req_[A-Za-z0-9_-]{1,120}$", options: .regularExpression) != nil ? value : nil
        }
        let retry = response.value(forHTTPHeaderField: "Retry-After")
        if let seconds = retry.flatMap(Int.init), seconds >= 0, seconds <= 604_800 {
            retryAfterSeconds = seconds
        } else if let retry {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: retry) {
                let delay = date.timeIntervalSinceNow
                retryAfterSeconds = delay >= 0 && delay <= 604_800 ? Int(ceil(delay)) : nil
            } else { retryAfterSeconds = nil }
        } else { retryAfterSeconds = nil }
    }

    var errorDescription: String? { reason.errorDescription }
    var diagnosticDetails: String {
        var lines = ["HTTP \(status)"]
        if let code { lines.append("Code: \(code)") }
        if let retryAfterSeconds { lines.append("Retry after at least \(retryAfterSeconds) seconds.") }
        if let requestID { lines.append("Request ID: \(requestID)") }
        return lines.joined(separator: "\n")
    }
}

struct OpenAIErrorEnvelope: Decodable {
    let error: Details
    struct Details: Decodable {
        let code: String?
        let type: String?
        let message: String?
        enum CodingKeys: String, CodingKey { case code, type, message }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            code = try? container.decode(String.self, forKey: .code)
            type = try? container.decode(String.self, forKey: .type)
            message = try? container.decode(String.self, forKey: .message)
        }
    }
}
