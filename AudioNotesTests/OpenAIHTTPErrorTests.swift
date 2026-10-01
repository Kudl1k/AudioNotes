import Foundation
import Testing
@testable import AudioNotes

struct OpenAIHTTPErrorTests {
    @Test(arguments: [
        ("credit_balance_exhausted", OpenAITranscriptionError.creditBalanceExhausted),
        ("organization_spend_limit_exceeded", .organizationSpendLimit),
        ("project_spend_limit_exceeded", .projectSpendLimit),
        ("organization_usage_limit_exceeded", .organizationUsageLimit),
        ("insufficient_quota", .quotaExceeded), ("slow_down", .rateLimited), ("rate_limit_exceeded", .rateLimited)
    ])
    func distinguishesBillingFromTemporaryRateLimits(code: String, expected: OpenAITranscriptionError) {
        let data = Data("{\"error\":{\"code\":\"\(code)\"}}".utf8)
        #expect(OpenAITranscriptionClient.error(for: 429, data: data) == expected)
    }

    @Test func handlesQuotaTypeWithMissingOrNonStringCode() {
        for json in [#"{"error":{"type":"insufficient_quota","code":null}}"#,
                     #"{"error":{"type":"insufficient_quota","code":123}}"#] {
            #expect(OpenAITranscriptionClient.error(for: 429, data: Data(json.utf8)) == .quotaExceeded)
        }
    }

    @Test func diagnosticsContainOnlySafeAllowlistedFields() throws {
        let response = try #require(HTTPURLResponse(url: URL(string: "https://api.openai.com")!, statusCode: 429,
                                                    httpVersion: nil, headerFields: ["x-request-id": "req_example", "Retry-After": "30"]))
        let data = Data(#"{"error":{"code":"credit_balance_exhausted","message":"untrusted sensitive body"}}"#.utf8)
        let error = OpenAIHTTPError(reason: .creditBalanceExhausted, response: response, data: data)
        #expect(error.diagnosticDetails.contains("HTTP 429"))
        #expect(error.diagnosticDetails.contains("credit_balance_exhausted"))
        #expect(error.diagnosticDetails.contains("req_example"))
        #expect(error.retryAfterSeconds == 30)
        #expect(!error.diagnosticDetails.contains("untrusted"))
        let malicious = try #require(HTTPURLResponse(url: response.url!, statusCode: 429, httpVersion: nil,
                                                     headerFields: ["x-request-id": "untrusted value", "Retry-After": "untrusted delay"]))
        let filtered = OpenAIHTTPError(reason: .rateLimited, response: malicious,
                                      data: Data(#"{"error":{"code":"untrusted code"}}"#.utf8))
        #expect(filtered.diagnosticDetails == "HTTP 429")
    }
}
