import Foundation
import Testing
@testable import AudioNotes

struct GoogleDriveSharingTests {
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
