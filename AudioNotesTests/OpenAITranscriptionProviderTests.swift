import Foundation
import SwiftData
import Testing
@testable import AudioNotes

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct OpenAITranscriptionProviderTests {
    @Test func uploadsManagedAudioAndMapsResponseWithIndeterminateProgress() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let fixture = OpenAINetworkFixture(data: OpenAIResponseTests.validJSON)
        defer { fixture.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let recording = try await workspace.makeRecording(in: container.mainContext)
        let provider = OpenAITranscriptionProvider(configuration: .init(), credentials: MockCredentialStore(key: "offline-placeholder"),
                                                   client: OpenAITranscriptionClient(session: fixture.session))
        var progress: [Double?] = []
        let transcript = try await provider.transcribe(audioURL: workspace.storage.recordingURL(fileName: recording.audioFileName)) {
            progress.append($0)
        }
        #expect(progress == [nil])
        #expect(transcript.segments.count == 2)
        #expect(!transcript.isMock)
        let request = try #require(fixture.probe.requests.withLock { $0.first })
        #expect(request.url == OpenAITranscriptionClient.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer offline-placeholder")
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
    }

    @Test func transcribesPartsSequentiallyAndOffsetsSegmentTimestamps() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let audio = try workspace.makeAudio()
        let fixture = OpenAINetworkFixture(data: OpenAIResponseTests.validJSON)
        defer { fixture.cleanUp() }
        let parts = [
            OpenAIAudioPart(url: audio, startTime: 0, duration: 10),
            OpenAIAudioPart(url: audio, startTime: 10, duration: 20)
        ]
        let splitter = FixedAudioPreparing(parts: parts, totalDuration: 30)
        let provider = OpenAITranscriptionProvider(configuration: .init(), credentials: MockCredentialStore(key: "offline-placeholder"),
                                                   client: OpenAITranscriptionClient(session: fixture.session), splitter: splitter)
        var fractions: [Double?] = []
        var statuses: [TranscriptionStatus] = []
        let transcript = try await provider.transcribe(audioURL: audio, progress: { fractions.append($0) },
                                                       status: { statuses.append($0) })
        #expect(fixture.probe.requests.withLock { $0.count } == 2)
        #expect(fractions == [nil, 1.0 / 3.0, 1.0])
        #expect(transcript.orderedSegments.count == 4)
        #expect(transcript.orderedSegments[0].startTime == 0)
        #expect(transcript.orderedSegments[3].startTime == 10.5)
        #expect(transcript.orderedSegments.map(\.position) == [0, 1, 2, 3])
        #expect(statuses.contains { $0.phase == .transcribing && $0.currentPart == 2 && $0.completedParts == 1 })
        #expect(statuses.last?.phase == .merging)
    }

    @Test func missingKeyDoesNotStartNetworkRequest() async throws {
        let fixture = OpenAINetworkFixture(data: Data())
        defer { fixture.cleanUp() }
        let provider = OpenAITranscriptionProvider(configuration: .init(), credentials: MockCredentialStore(),
                                                   client: OpenAITranscriptionClient(session: fixture.session))
        await #expect(throws: OpenAITranscriptionError.missingAPIKey) {
            _ = try await provider.transcribe(audioURL: URL(fileURLWithPath: "/missing.wav")) { _ in }
        }
        #expect(fixture.probe.requests.withLock { $0.isEmpty })
    }

    @Test(arguments: [401, 403, 413, 415, 429, 500, 503, 400])
    func mapsHTTPFailures(status: Int) async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let fixture = OpenAINetworkFixture(status: status, data: Data("untrusted response text must not be displayed".utf8))
        defer { fixture.cleanUp() }
        let provider = OpenAITranscriptionProvider(configuration: .init(), credentials: MockCredentialStore(key: "offline-placeholder"),
                                                   client: OpenAITranscriptionClient(session: fixture.session))
        let expected = OpenAITranscriptionClient.error(for: status, data: Data())
        let url = try workspace.makeAudio()
        do {
            _ = try await provider.transcribe(audioURL: url) { _ in }
            Issue.record("Expected HTTP error")
        } catch let error as OpenAIHTTPError {
            #expect(error.reason == expected)
            #expect(error.status == status)
        }
        #expect(!expected.localizedDescription.contains("untrusted"))
    }

    @Test func mapsQuotaNetworkAndMalformedResponse() async throws {
        #expect(OpenAITranscriptionClient.error(for: 429, data: Data(#"{"error":{"code":"insufficient_quota"}}"#.utf8)) == .quotaExceeded)
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let url = try workspace.makeAudio()
        for networkError in [URLError.Code.notConnectedToInternet, .timedOut] {
            let fixture = OpenAINetworkFixture(data: Data(), error: networkError)
            defer { fixture.cleanUp() }
            let provider = OpenAITranscriptionProvider(configuration: .init(), credentials: MockCredentialStore(key: "offline-placeholder"),
                                                       client: OpenAITranscriptionClient(session: fixture.session))
            await #expect(throws: OpenAITranscriptionError.network(code: networkError.rawValue)) {
                _ = try await provider.transcribe(audioURL: url) { _ in }
            }
        }
        let fixture = OpenAINetworkFixture(data: Data("malformed".utf8))
        defer { fixture.cleanUp() }
        let provider = OpenAITranscriptionProvider(configuration: .init(), credentials: MockCredentialStore(key: "offline-placeholder"),
                                                   client: OpenAITranscriptionClient(session: fixture.session))
        await #expect(throws: OpenAITranscriptionError.invalidResponse) {
            _ = try await provider.transcribe(audioURL: url) { _ in }
        }
    }

    @Test func cancellationStopsURLSessionAndPersistsNothing() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let fixture = OpenAINetworkFixture(data: Data(), suspend: true)
        defer { fixture.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let recording = try await workspace.makeRecording(in: context)
        let provider = OpenAITranscriptionProvider(configuration: .init(), credentials: MockCredentialStore(key: "offline-placeholder"),
                                                   client: OpenAITranscriptionClient(session: fixture.session))
        let model = RecordingViewModel(recording: recording, provider: provider, storage: workspace.storage)
        let task = try #require(model.startTranscription(using: SwiftDataTranscriptRepository(context: context)))
        for await _ in fixture.probe.started { break }
        #expect(model.state == .transcribing)
        #expect(model.progress == nil)
        model.cancelTranscription()
        await task.value
        for await _ in fixture.probe.stopped { break }
        #expect(model.state == .cancelled)
        #expect(model.canTranscribe)
        #expect(recording.transcript == nil)
        #expect(try context.fetchCount(FetchDescriptor<Transcript>()) == 0)
    }

    @Test func retryResolvesChangedProviderWithoutReopeningRecording() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let name = "AudioNotesTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let configuration = TranscriptionConfiguration(defaults: defaults)
        configuration.selectedProvider = .openAI
        let resolver = TranscriptionProviderResolver(configuration: configuration, credentials: MockCredentialStore())
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let recording = try await workspace.makeRecording(in: context)
        let model = RecordingViewModel(recording: recording, resolver: resolver, storage: workspace.storage)
        let repository = SwiftDataTranscriptRepository(context: context)
        await model.startTranscription(using: repository)?.value
        #expect(model.state == .failed(message: OpenAITranscriptionError.missingAPIKey.localizedDescription))
        #expect(recording.transcript == nil)
        configuration.selectedProvider = .mock
        #expect(model.isMockProvider)
        await model.startTranscription(using: repository)?.value
        #expect(model.state == .completed)
        #expect(recording.transcript?.isMock == true)
    }
}

private struct FixedAudioPreparing: OpenAIAudioPreparing {
    let parts: [OpenAIAudioPart]
    let totalDuration: TimeInterval

    func prepare(fileURL: URL) async throws -> OpenAIAudioSplitResult {
        OpenAIAudioSplitResult(directory: nil, parts: parts, totalDuration: totalDuration, wasSplit: true)
    }
}
