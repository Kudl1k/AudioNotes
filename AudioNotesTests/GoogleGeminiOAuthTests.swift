import Foundation
import Testing
@testable import AudioNotes

@Suite(.serialized)
struct GoogleGeminiOAuthTests {
    private static let configuration = GoogleOAuthConfiguration(clientID: "desktop-client", projectID: "audio-notes-project", clientSecret: "file-secret")

    @Test func loadsDesktopClientFromFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"installed":{"client_id":" desktop-client ","project_id":" project ","client_secret":" file-secret "}}"#.utf8).write(to: url)
        let client = try GoogleOAuthConfiguration.load(from: url)
        #expect(client.clientID == "desktop-client")
        #expect(client.projectID == "project")
        #expect(client.clientSecret == "file-secret")
    }

    @Test func rejectsMalformedWebAndIncompleteConfigurationWithoutExposingSecrets() {
        for json in ["invalid", #"{"web":{"client_id":"client","project_id":"project"}}"#, #"{"installed":{"client_id":" ","project_id":"project","client_secret":"private-value"}}"#] {
            #expect(throws: GoogleOAuthConfigurationError.invalidFile) {
                try GoogleOAuthConfiguration.parse(Data(json.utf8))
            }
        }
        #expect(throws: GoogleOAuthConfigurationError.unreadableFile) {
            try GoogleOAuthConfiguration.load(from: URL(fileURLWithPath: "/missing-\(UUID().uuidString).json"))
        }
    }

    @Test func missingConfigurationBlocksEvenCachedAccessToken() async {
        let store = OAuthCredentialMemoryStore(GoogleOAuthCredential(accessToken: "access", refreshToken: "refresh", expiresAt: .distantFuture, email: nil))
        let service = GoogleGeminiOAuthService(configuration: { throw GoogleOAuthConfigurationError.missingFile }, store: store)
        await #expect(throws: GoogleOAuthConfigurationError.missingFile) {
            try await service.validAccessToken()
        }
        await #expect(throws: GoogleOAuthConfigurationError.missingFile) {
            try await service.connect()
        }
    }

    @Test func fileWithoutSecretRemovesLegacyUserSecret() async throws {
        let store = OAuthCredentialMemoryStore(GoogleOAuthCredential(accessToken: "access", refreshToken: "refresh", expiresAt: .distantFuture, email: nil), clientSecret: "legacy-secret")
        let client = try GoogleOAuthConfiguration.parse(Data(#"{"installed":{"client_id":"client","project_id":"project"}}"#.utf8))
        let service = GoogleGeminiOAuthService(configuration: { client }, store: store)
        _ = try await service.validAccessToken()
        #expect(await store.loadClientSecret() == nil)
    }

    @Test func authorizationURLUsesLoopbackPKCEAndState() throws {
        let url = try GoogleGeminiOAuthService.authorizationURL(
            clientID: "desktop-client.apps.googleusercontent.com",
            redirectURI: "http://127.0.0.1:49152",
            state: "random-state",
            challenge: "s256-challenge",
            scopes: ["openid", "email", "https://www.googleapis.com/auth/generative-language.retriever"]
        )
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(url.host == "accounts.google.com")
        #expect(items["client_id"] == "desktop-client.apps.googleusercontent.com")
        #expect(items["redirect_uri"] == "http://127.0.0.1:49152")
        #expect(items["response_type"] == "code")
        #expect(items["state"] == "random-state")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["code_challenge"] == "s256-challenge")
        #expect(items["access_type"] == "offline")
        #expect(items["scope"]?.contains("generative-language.retriever") == true)
    }

    @Test func callbackStateMustMatchExactly() {
        #expect(GoogleGeminiOAuthService.callbackMatchesState("expected", expected: "expected"))
        #expect(!GoogleGeminiOAuthService.callbackMatchesState("attacker", expected: "expected"))
        #expect(!GoogleGeminiOAuthService.callbackMatchesState(nil, expected: "expected"))
    }

    @Test func validUnexpiredCredentialAvoidsRefreshRequest() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = OAuthCredentialMemoryStore(GoogleOAuthCredential(accessToken: "access", refreshToken: "refresh", expiresAt: now.addingTimeInterval(3600), email: "user@example.com"))
        let service = GoogleGeminiOAuthService(configuration: { Self.configuration }, store: store, now: { now })
        #expect(try await service.validAccessToken() == "access")
        #expect(await service.account()?.email == "user@example.com")
        #expect(try await service.requestHeaders()["x-goog-user-project"] == "audio-notes-project")
    }

    @Test func disconnectClearsOAuthCredentialOnly() async throws {
        let store = OAuthCredentialMemoryStore(GoogleOAuthCredential(accessToken: "access", refreshToken: "refresh", expiresAt: .distantFuture, email: nil))
        let service = GoogleGeminiOAuthService(configuration: { Self.configuration }, store: store)
        try await service.disconnect()
        #expect(await store.load() == nil)
    }

    @Test func expiredAccessTokenRefreshesAndPersistsRotatedTokens() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = OAuthCredentialMemoryStore(GoogleOAuthCredential(accessToken: "old-access", refreshToken: "old-refresh", expiresAt: now.addingTimeInterval(-1), email: "user@example.com"))
        let session = Self.session(stub: (200, Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#.utf8)))
        let service = GoogleGeminiOAuthService(configuration: { Self.configuration }, store: store, session: session, now: { now })

        #expect(try await service.validAccessToken() == "new-access")
        #expect(await store.load()?.refreshToken == "new-refresh")
        #expect(await store.loadClientSecret() == "file-secret")
        let body = String(data: URLProtocolStub.lastBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("client_secret=file-secret"))
        #expect(body.contains("client_id=desktop-client"))
    }

    @Test func revokedRefreshTokenRequiresReauthenticationAndDeletesTokens() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = OAuthCredentialMemoryStore(GoogleOAuthCredential(accessToken: "old-access", refreshToken: "revoked", expiresAt: now.addingTimeInterval(-1), email: nil))
        let session = Self.session(stub: (400, Data(#"{"error":"invalid_grant"}"#.utf8)))
        let service = GoogleGeminiOAuthService(configuration: { Self.configuration }, store: store, session: session, now: { now })

        await #expect(throws: GoogleGeminiOAuthError.reauthenticationRequired) {
            _ = try await service.validAccessToken()
        }
        #expect(await store.load() == nil)
    }

    @Test func optionalClientSecretIsAddedOnlyWhenConfigured() {
        let base = ["grant_type": "authorization_code", "client_id": "client"]
        #expect(GoogleGeminiOAuthService.tokenParameters(base, clientSecret: "desktop-secret")["client_secret"] == "desktop-secret")
        #expect(GoogleGeminiOAuthService.tokenParameters(base, clientSecret: nil)["client_secret"] == nil)
    }

    @Test func tokenErrorDisplaysSanitizedGoogleDescription() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = OAuthCredentialMemoryStore(GoogleOAuthCredential(accessToken: "old", refreshToken: "refresh", expiresAt: now.addingTimeInterval(-1), email: nil))
        let body = Data(#"{"error":"invalid_request","error_description":"Missing required parameter: client_secret"}"#.utf8)
        let service = GoogleGeminiOAuthService(configuration: { Self.configuration }, store: store, session: Self.session(stub: (400, body)), now: { now })
        var message = ""
        do { _ = try await service.validAccessToken() }
        catch { message = error.localizedDescription }
        #expect(message.contains("HTTP 400, invalid_request"))
        #expect(!message.contains("Missing required parameter: client_secret"))
    }

    private static func session(stub: (Int, Data)) -> URLSession {
        URLProtocolStub.stub = stub
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }
}

private actor OAuthCredentialMemoryStore: GoogleOAuthCredentialStoring, GoogleOAuthClientSecretStoring {
    private var credential: GoogleOAuthCredential?
    private var clientSecret: String?
    init(_ credential: GoogleOAuthCredential?, clientSecret: String? = nil) { self.credential = credential; self.clientSecret = clientSecret }
    func load() -> GoogleOAuthCredential? { credential }
    func save(_ credential: GoogleOAuthCredential) { self.credential = credential }
    func delete() { credential = nil }
    func loadClientSecret() -> String? { clientSecret }
    func saveClientSecret(_ secret: String) { clientSecret = secret }
    func deleteClientSecret() { clientSecret = nil }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var stub: (Int, Data) = (200, Data())
    nonisolated(unsafe) static var lastBody: Data?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.stub
        if let body = request.httpBody {
            Self.lastBody = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            Self.lastBody = body
        } else {
            Self.lastBody = nil
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
