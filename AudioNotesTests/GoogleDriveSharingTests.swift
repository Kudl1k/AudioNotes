import Foundation
import Testing
@testable import AudioNotes

struct GoogleDriveSharingTests {
    @Test(arguments: [false, true])
    func recoversAnAccessibleParentOnlyWhenItIsAGeneralSharingFolder(parentIsPublished: Bool) async throws {
        let projectID = UUID()
        let folder = DriveProjectFolder(id: "project", name: "Project", publishedProjectID: projectID)
        let remote = DriveProjectRemote(transport: DriveHTTPTransport(send: { request in
            let id = request.url?.lastPathComponent
            #expect(request.httpMethod == "GET")
            switch id {
            case "project":
                return response(request, 200, body: """
                    {"id":"project","name":"Project","mimeType":"application/vnd.google-apps.folder","ownedByMe":true,
                     "capabilities":{"canAddChildren":true},"parents":["sharing"],"appProperties":{"soniquillKey":"p-\(projectID)"}}
                    """)
            case "sharing":
                let properties = parentIsPublished ? #","appProperties":{"soniquillKey":"p-\#(projectID)"}"# : ""
                return response(request, 200, body: """
                    {"id":"sharing","name":"Team Drive Folder","mimeType":"application/vnd.google-apps.folder","ownedByMe":true,
                     "capabilities":{"canAddChildren":true}\(properties)}
                    """)
            default:
                Issue.record("Unexpected Drive folder lookup")
                return response(request, 404)
            }
        }), checkPrivacy: {}, token: { _ in "injected-token" })

        let parent = try await remote.sharingParent(of: folder)
        #expect(parent == (parentIsPublished ? nil : DriveProjectFolder(id: "sharing", name: "Team Drive Folder")))
    }

    @Test func resumesFromConfirmedBytesAndRecoversCompletedFileWithoutDuplicate() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let length = 8 * 1_048_576 + 32
        let file = workspace.root.appending(path: "Test.soniquill")
        try Data(repeating: 7, count: length).write(to: file)
        let hash = try SourceImportService.hash(file)
        let transport = ResumeTransport(length: length, hash: hash)
        let upload = GoogleDriveUpload(file: file, name: file.lastPathComponent,
            transport: DriveHTTPTransport(send: { try await transport.send($0) }),
            checkPrivacy: {}, token: { _ in "injected-token" })
        await #expect(throws: URLError.self) { try await upload.run { _, _ in } }
        let link = try await upload.run { count, _ in await transport.observe(count) }
        #expect(link.absoluteString == "https://drive.google.com/open?id=test_id")
        #expect(await transport.offsets == [8 * 1_048_576, UInt64(length - 1), UInt64(length)])
        #expect(await transport.step == 7)
        let recovered = try await upload.run { _, _ in }
        #expect(recovered == link)
        #expect(await transport.step == 10)
    }

    @Test func localOnlyAndUntrustedSessionURLPreventNetworkOrByteTransfer() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let file = workspace.root.appending(path: "Test.soniquill")
        try Data([1]).write(to: file)
        let blocked = GoogleDriveUpload(file: file, name: file.lastPathComponent,
            transport: DriveHTTPTransport(send: { _ in
                Issue.record("Local Only must block the transport")
                throw GoogleDriveSharingError.invalidResponse
            }), checkPrivacy: { throw GoogleDriveSharingError.localOnly },
            token: { _ in
                Issue.record("Local Only must block token lookup")
                return ""
            })
        await #expect(throws: GoogleDriveSharingError.localOnly) { try await blocked.run { _, _ in } }
        let fake = GoogleDriveUpload(file: file, name: file.lastPathComponent,
            transport: DriveHTTPTransport(send: { request in
                switch request.httpMethod {
                case "GET": return response(request, 200, body: #"{"ids":["test_id"]}"#)
                case "POST": return response(request, 200, headers: ["Location": "https://example.com/upload/drive/v3/files"])
                default:
                    Issue.record("Unexpected upload to an untrusted origin")
                    throw GoogleDriveSharingError.invalidResponse
                }
            }), checkPrivacy: {}, token: { _ in "injected-token" })
        await #expect(throws: GoogleDriveSharingError.invalidResponse) { try await fake.run { _, _ in } }
    }

    @Test func retriesUnauthorizedRequestWithRefreshedToken() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let file = workspace.root.appending(path: "Test.soniquill")
        try Data([1]).write(to: file)
        let upload = GoogleDriveUpload(file: file, name: file.lastPathComponent,
            transport: DriveHTTPTransport(send: { request in
                if request.httpMethod == "GET" {
                    if request.value(forHTTPHeaderField: "Authorization") == "Bearer new" {
                        return response(request, 200, body: #"{"ids":["test_id"]}"#)
                    }
                    return response(request, 401)
                }
                return response(request, 403)
            }), checkPrivacy: {}, token: { rejection in rejection == "old" ? "new" : "old" })
        await #expect(throws: GoogleDriveSharingError.http(403)) { try await upload.run { _, _ in } }
    }

    @Test func cancelledChunkStopsAndResumeProbesTheSameSession() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let file = workspace.root.appending(path: "Cancel.soniquill")
        try Data([1]).write(to: file)
        let transport = CancellationTransport()
        let upload = GoogleDriveUpload(file: file, name: file.lastPathComponent,
            transport: DriveHTTPTransport(send: { try await transport.send($0) }),
            checkPrivacy: { try Task.checkCancellation() }, token: { _ in "injected-token" })
        let task = Task { try await upload.run { _, _ in } }
        await transport.waitUntilChunkStarts()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await #expect(throws: GoogleDriveSharingError.http(429)) { try await upload.run { _, _ in } }
        #expect(await transport.step == 4)
    }

    // MARK: - Resumable protocol edge cases

    @Test func restartsFromZeroWhenSessionConfirmsNoBytes() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let file = workspace.root.appending(path: "Restart.soniquill")
        try Data([1]).write(to: file)
        let hash = try SourceImportService.hash(file)
        let script = ScriptedTransport { step, request in
            switch step {
            case 1: return response(request, 200, body: #"{"ids":["test_id"]}"#)
            case 2: return response(request, 200, headers: ["Location": uploadSession])
            case 3:
                #expect(request.value(forHTTPHeaderField: "Content-Range") == "bytes 0-0/1")
                return response(request, 308)
            case 4:
                #expect(request.value(forHTTPHeaderField: "Content-Range") == "bytes 0-0/1")
                #expect(request.httpBody?.count == 1)
                return response(request, 200, body: #"{"id":"test_id","size":"1","sha256Checksum":"\#(hash)"}"#)
            default: throw GoogleDriveSharingError.invalidResponse
            }
        }
        let upload = GoogleDriveUpload(file: file, name: file.lastPathComponent, transport: script.transport,
                                       checkPrivacy: {}, retry: .immediate, token: { _ in "injected-token" })
        let link = try await upload.run { _, _ in }
        #expect(link.absoluteString == "https://drive.google.com/open?id=test_id")
        #expect(await script.step == 4)
    }

    @Test func boundsRepeatedRestartsWithoutRange() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let file = workspace.root.appending(path: "Loop.soniquill")
        try Data([1]).write(to: file)
        let script = ScriptedTransport { step, request in
            switch step {
            case 1: return response(request, 200, body: #"{"ids":["test_id"]}"#)
            case 2: return response(request, 200, headers: ["Location": uploadSession])
            default: return response(request, 308)
            }
        }
        let upload = GoogleDriveUpload(file: file, name: file.lastPathComponent, transport: script.transport,
                                       checkPrivacy: {}, retry: .immediate, token: { _ in "injected-token" })
        await #expect(throws: GoogleDriveSharingError.invalidResponse) { try await upload.run { _, _ in } }
        #expect(await script.step == 2 + 4)
    }

    @Test func transientChunkFailureQueriesSessionBeforeResending() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let file = workspace.root.appending(path: "Flaky.soniquill")
        try Data([1]).write(to: file)
        let hash = try SourceImportService.hash(file)
        let script = ScriptedTransport { step, request in
            switch step {
            case 1: return response(request, 200, body: #"{"ids":["test_id"]}"#)
            case 2: return response(request, 200, headers: ["Location": uploadSession])
            case 3: return response(request, 503)
            case 4:
                #expect(request.value(forHTTPHeaderField: "Content-Range") == "bytes */1")
                return response(request, 308)
            case 5:
                #expect(request.value(forHTTPHeaderField: "Content-Range") == "bytes 0-0/1")
                return response(request, 200, body: #"{"id":"test_id","size":"1","sha256Checksum":"\#(hash)"}"#)
            default: throw GoogleDriveSharingError.invalidResponse
            }
        }
        let upload = GoogleDriveUpload(file: file, name: file.lastPathComponent, transport: script.transport,
                                       checkPrivacy: {}, retry: .immediate, token: { _ in "injected-token" })
        _ = try await upload.run { _, _ in }
        #expect(await script.step == 5)
    }

    @Test func knownChecksumSkipsLocalHashing() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let file = workspace.root.appending(path: "Known.soniquill")
        try Data([1]).write(to: file)
        // Deliberately not the file's real hash: success proves the upload trusted the supplied checksum.
        let known = String(repeating: "ab", count: 32)
        let script = ScriptedTransport { step, request in
            switch step {
            case 1: return response(request, 200, body: #"{"ids":["test_id"]}"#)
            case 2: return response(request, 200, headers: ["Location": uploadSession])
            case 3: return response(request, 200, body: #"{"id":"test_id","size":"1","sha256Checksum":"\#(known)"}"#)
            default: throw GoogleDriveSharingError.invalidResponse
            }
        }
        let upload = GoogleDriveUpload(file: file, name: file.lastPathComponent, transport: script.transport,
                                       checkPrivacy: {}, knownChecksum: known, retry: .immediate,
                                       token: { _ in "injected-token" })
        _ = try await upload.run { _, _ in }
        #expect(await script.step == 3)
    }

    // MARK: - Retry/backoff

    @Test func retriesRateLimitThenSucceeds() async throws {
        let sleeps = Recorder<Duration>()
        let script = ScriptedTransport { step, request in
            step == 1 ? response(request, 429) : response(request, 200, body: "ok")
        }
        let transport = script.transport.retrying(.recording(sleeps))
        let (data, result) = try await transport.send(URLRequest(url: driveFile))
        #expect(result.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "ok")
        #expect(await script.step == 2)
        #expect(await sleeps.values == [.milliseconds(500)])
    }

    @Test func honorsCappedRetryAfterAndExponentialBackoff() async throws {
        let sleeps = Recorder<Duration>()
        let script = ScriptedTransport { step, request in
            switch step {
            case 1: return response(request, 503, headers: ["Retry-After": "7"])
            case 2: return response(request, 503, headers: ["Retry-After": "120"])
            default: return response(request, 500)
            }
        }
        let (_, result) = try await script.transport.retrying(.recording(sleeps)).send(URLRequest(url: driveFile))
        #expect(result.statusCode == 500)
        #expect(await script.step == 4)
        #expect(await sleeps.values == [.seconds(7), .seconds(30), .seconds(2)])
    }

    @Test(arguments: [(400, "", 1), (403, #"{"error":{"errors":[{"reason":"insufficientPermissions"}]}}"#, 1),
                      (403, #"{"error":{"errors":[{"reason":"userRateLimitExceeded"}]}}"#, 2)])
    func retriesOnlyTransientStatuses(status: Int, body: String, expectedCalls: Int) async throws {
        let script = ScriptedTransport { step, request in
            step == 1 ? response(request, status, body: body) : response(request, 200)
        }
        _ = try await script.transport.retrying(.immediate).send(URLRequest(url: driveFile))
        #expect(await script.step == expectedCalls)
    }

    @Test func neverReplaysResumableChunkButRetriesStatusProbe() async throws {
        let script = ScriptedTransport { _, request in response(request, 503) }
        let transport = script.transport.retrying(.immediate)
        var chunk = URLRequest(url: URL(string: uploadSession)!)
        chunk.httpMethod = "PUT"
        chunk.setValue("bytes 0-0/1", forHTTPHeaderField: "Content-Range")
        chunk.httpBody = Data([1])
        _ = try await transport.send(chunk)
        #expect(await script.step == 1)
        var probe = chunk
        probe.httpBody = nil
        probe.setValue("bytes */1", forHTTPHeaderField: "Content-Range")
        _ = try await transport.send(probe)
        #expect(await script.step == 1 + 4)
    }

    @Test func cancellationAbortsBackoff() async throws {
        let script = ScriptedTransport { _, request in response(request, 503) }
        var policy = DriveRetryPolicy.standard
        policy.baseDelay = .seconds(60)
        policy.jitter = { 1 }
        let transport = script.transport.retrying(policy)
        let task = Task { try await transport.send(URLRequest(url: driveFile)) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await script.step == 1)
    }

    // MARK: - Connection tokens and local state

    @Test func concurrentTokenCallersShareOneRefresh() async throws {
        let store = MemoryCredentialStore(.init(accessToken: "stale", refreshToken: "refresh",
                                                expiresAt: .distantPast, email: nil))
        let script = ScriptedTransport { _, request in
            #expect(request.url?.path == "/token")
            try await Task.sleep(for: .milliseconds(50))
            return response(request, 200, body: #"{"access_token":"fresh","expires_in":3600}"#)
        }
        let connection = testConnection(store: store, transport: script.transport)
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask { try await connection.uploadToken()(nil) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(tokens == Array(repeating: "fresh", count: 8))
        #expect(await script.step == 1)
        #expect(await store.credential?.accessToken == "fresh")
    }

    @Test func disconnectInvalidatesTokensAndResetsLocalState() async throws {
        let store = MemoryCredentialStore(.init(accessToken: "valid", refreshToken: "refresh",
                                                expiresAt: .distantFuture, email: nil))
        let script = ScriptedTransport { _, request in
            #expect(request.url?.path == "/revoke")
            return response(request, 200)
        }
        let resets = await ResetCounter()
        let connection = testConnection(store: store, transport: script.transport,
                                        resetLocalState: { resets.count += 1 })
        let token = try await connection.uploadToken()
        #expect(try await token(nil) == "valid")
        try await connection.disconnect()
        await #expect(throws: GoogleDriveSharingError.signInRequired) { try await token(nil) }
        #expect(await store.credential == nil)
        #expect(await resets.count == 1)
    }

    @Test func resetRemovesOnlyDriveProjectKeys() throws {
        let suite = "GoogleDriveSharingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let driveKeys = ["drive.project.selection", "drive.project.links", "drive.project.baseline.abc",
                         "drive.project.fileID.p-1", "drive.project.pairing.x", "drive.project.sourceFolder"]
        for key in driveKeys { defaults.set("value", forKey: key) }
        defaults.set(true, forKey: "ai.localOnly")
        defaults.set("keep", forKey: "drive.projectOther")
        defaults.set("keep", forKey: "drive.other")

        DriveSharingLocalState.reset(defaults: defaults)

        for key in driveKeys { #expect(defaults.object(forKey: key) == nil) }
        #expect(defaults.bool(forKey: "ai.localOnly"))
        #expect(defaults.string(forKey: "drive.projectOther") == "keep")
        #expect(defaults.string(forKey: "drive.other") == "keep")
    }

#if os(macOS)
    @Test func authorizationDoesNotBlockTokenReadsAndKeepsRunningUploadsValid() async throws {
        let store = MemoryCredentialStore(.init(accessToken: "valid", refreshToken: "refresh",
                                                expiresAt: .distantFuture, email: nil))
        let script = ScriptedTransport { _, request in
            #expect(request.url?.path == "/token")
            return response(request, 200, body: """
                {"access_token":"reauthorized","refresh_token":"refresh-2","expires_in":3600,
                 "scope":"\(GoogleDriveConnection.scope)"}
                """)
        }
        let browser = BrowserGate()
        let connection = testConnection(store: store, transport: script.transport,
                                        makeListener: { browser }, openBrowser: { await browser.opened($0) })
        let running = try await connection.uploadToken()
        let authorization = Task { try await connection.connect() }
        await browser.waitUntilOpened()

        #expect(try await running(nil) == "valid")
        #expect(try await connection.uploadToken()(nil) == "valid")
        await #expect(throws: GoogleDriveSharingError.busy) { try await connection.chooseFolder() }
        await #expect(throws: GoogleDriveSharingError.busy) { try await connection.disconnect() }

        await browser.complete()
        try await authorization.value
        #expect(await store.credential?.accessToken == "reauthorized")
        #expect(try await running(nil) == "reauthorized")
    }
#endif

    private func testConnection(
        store: MemoryCredentialStore, transport: DriveHTTPTransport,
        resetLocalState: @escaping @MainActor @Sendable () -> Void = {},
        makeListener: @escaping @Sendable () -> any ChatGPTLoopbackListening = { ChatGPTLoopbackListener() },
        openBrowser: @escaping @Sendable (URL) async -> Bool = { _ in false }
    ) -> GoogleDriveConnection {
        GoogleDriveConnection(storage: store, transport: transport,
                              configuration: { .init(clientID: "test.apps.googleusercontent.com", projectID: "test",
                                                     clientSecret: "test-secret", redirectScheme: "com.test") },
                              checkPrivacy: {}, resetLocalState: resetLocalState,
                              makeListener: makeListener, openBrowser: openBrowser)
    }

    private actor CancellationTransport {
        private(set) var step = 0
        private var started: CheckedContinuation<Void, Never>?

        func waitUntilChunkStarts() async {
            guard step < 3 else { return }
            await withCheckedContinuation { started = $0 }
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            step += 1
            switch step {
            case 1:
                return response(request, 200, body: #"{"ids":["test_id"]}"#)
            case 2:
                return response(request, 200, headers: ["Location": "https://www.googleapis.com/upload/drive/v3/files?upload_id=test"])
            case 3:
                started?.resume()
                started = nil
                try await Task.sleep(for: .seconds(2))
                Issue.record("The caller did not cancel the active chunk")
                return response(request, 500)
            case 4:
                #expect(request.value(forHTTPHeaderField: "Content-Range") == "bytes */1")
                return response(request, 429)
            default: throw GoogleDriveSharingError.invalidResponse
            }
        }
    }

    private actor ResumeTransport {
        let length: Int
        let hash: String
        private(set) var step = 0
        private(set) var offsets: [UInt64] = []

        init(length: Int, hash: String) {
            self.length = length
            self.hash = hash
        }
        func observe(_ count: UInt64) { offsets.append(count) }

        func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
            step += 1
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer injected-token")
            let session = "https://www.googleapis.com/upload/drive/v3/files?upload_id=test"
            let result = #"{"id":"test_id","size":"\#(length)","sha256Checksum":"\#(hash)"}"#
            switch step {
            case 1:
                #expect(request.url?.path == "/drive/v3/files/generateIds")
                return response(request, 200, body: #"{"ids":["test_id"]}"#)
            case 2, 9:
                #expect(request.httpMethod == "POST")
                let metadata = try JSONDecoder().decode([String: String].self, from: #require(request.httpBody))
                #expect(metadata == ["id": "test_id", "name": "Test.soniquill", "mimeType": "application/octet-stream"])
                return step == 2 ? response(request, 200, headers: ["Location": session]) : response(request, 409)
            case 3:
                #expect(request.value(forHTTPHeaderField: "Content-Range") == "bytes 0-8388607/\(length)")
                return response(request, 308, headers: ["Range": "bytes=0-8388607"])
            case 4: throw URLError(.timedOut)
            case 5, 8:
                #expect(request.value(forHTTPHeaderField: "Content-Range") == "bytes */\(length)")
                return step == 5 ? response(request, 308, headers: ["Range": "bytes=0-8388607"]) : response(request, 404)
            case 6:
                #expect(request.value(forHTTPHeaderField: "Content-Range") == "bytes 8388608-\(length - 1)/\(length)")
                #expect(request.httpBody?.count == 32)
                return response(request, 308, headers: ["Range": "bytes=0-8388638"])
            case 7:
                #expect(request.httpBody?.count == 1)
                return response(request, 200, body: result)
            case 10:
                #expect(request.url?.path == "/drive/v3/files/test_id")
                return response(request, 200, body: result)
            default: throw GoogleDriveSharingError.invalidResponse
            }
        }
    }
}

private func response(_ request: URLRequest, _ status: Int, headers: [String: String] = [:],
                      body: String = "") -> (Data, HTTPURLResponse) {
    (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
}

private let uploadSession = "https://www.googleapis.com/upload/drive/v3/files?upload_id=test"
private let driveFile = URL(string: "https://www.googleapis.com/drive/v3/files/test_id")!

private extension DriveRetryPolicy {
    static var immediate: Self {
        var policy = Self.standard
        policy.jitter = { 1 }
        policy.sleep = { _ in }
        return policy
    }

    static func recording(_ recorder: Recorder<Duration>) -> Self {
        var policy = immediate
        policy.sleep = { await recorder.append($0) }
        return policy
    }
}

private actor Recorder<Value: Sendable> {
    private(set) var values: [Value] = []
    func append(_ value: Value) { values.append(value) }
}

/// Numbers requests from 1 and answers each through `handler`.
private actor ScriptedTransport {
    private(set) var step = 0
    private let handler: @Sendable (Int, URLRequest) async throws -> (Data, HTTPURLResponse)

    init(_ handler: @escaping @Sendable (Int, URLRequest) async throws -> (Data, HTTPURLResponse)) {
        self.handler = handler
    }

    nonisolated var transport: DriveHTTPTransport {
        DriveHTTPTransport(send: { try await self.send($0) })
    }

    private func next() -> Int {
        step += 1
        return step
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let current = next()
        return try await handler(current, request)
    }
}

private actor MemoryCredentialStore: GoogleOAuthCredentialStoring {
    private(set) var credential: GoogleOAuthCredential?

    init(_ credential: GoogleOAuthCredential?) { self.credential = credential }

    func load() -> GoogleOAuthCredential? { credential }
    func save(_ credential: GoogleOAuthCredential) { self.credential = credential }
    func delete() { credential = nil }
}

#if os(macOS)
/// Stands in for the loopback listener and system browser; holds the flow "in the browser" until completed.
private final class BrowserGate: ChatGPTLoopbackListening, @unchecked Sendable {
    private let state = GateState()

    func start() async throws -> (redirectURI: String, port: UInt16) { ("http://127.0.0.1:9/auth/callback", 9) }

    func waitForCallback(timeout: TimeInterval) async throws -> ChatGPTCallbackResult {
        let oauthState = await state.waitForCompletion()
        return ChatGPTCallbackResult(code: "code", state: oauthState, clientID: nil, error: nil,
                                     errorDescription: nil, scope: nil)
    }

    func cancel() {}

    func opened(_ url: URL) async -> Bool {
        let oauthState = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "state" }?.value
        await state.open(oauthState)
        return true
    }

    func waitUntilOpened() async { await state.waitUntilOpened() }
    func complete() async { await state.complete() }

    private actor GateState {
        private var oauthState: String?
        private var isOpen = false
        private var openWaiters: [CheckedContinuation<Void, Never>] = []
        private var completion: CheckedContinuation<String?, Never>?
        private var completed = false

        func open(_ value: String?) {
            oauthState = value
            isOpen = true
            openWaiters.forEach { $0.resume() }
            openWaiters = []
        }

        func waitUntilOpened() async {
            guard !isOpen else { return }
            await withCheckedContinuation { openWaiters.append($0) }
        }

        func waitForCompletion() async -> String? {
            if completed { return oauthState }
            return await withCheckedContinuation { completion = $0 }
        }

        func complete() {
            completed = true
            completion?.resume(returning: oauthState)
            completion = nil
        }
    }
}
#endif

@MainActor private final class ResetCounter {
    var count = 0
}
