import Foundation
import SwiftData
import Testing
@testable import AudioNotes

private actor CountingModelsClient: OpenAIModelsFetching {
    private(set) var requests = 0
    func fetchModels(bearerToken: String) async throws -> [OpenAIModelItem] { requests += 1; return [] }
}

@MainActor
struct FinalQATests {
    // MARK: Usage refresh key

    private func generation(status: GenerationStatus = .succeeded, usage: Data? = nil) -> GenerationRecord {
        let record = GenerationRecord(feature: .summary, provider: .openAI, model: "gpt-4o-mini", presetName: nil, outputLength: .detailed,
            settings: nil, authenticationMethod: .apiKey, status: status)
        record.requestUsageData = usage
        return record
    }

    @Test func usageRefreshKeyIsStableForUnchangedRecordsAndTracksRelevantChanges() {
        let records = (0..<50).map { _ in generation() }
        let key = UsageRefreshKey(records)
        #expect(UsageRefreshKey(records) == key)

        records[10].statusRaw = GenerationStatus.failed.rawValue
        #expect(UsageRefreshKey(records) != key)
        records[10].statusRaw = GenerationStatus.succeeded.rawValue
        #expect(UsageRefreshKey(records) == key)

        records[20].requestUsageData = Data([1, 2, 3])
        #expect(UsageRefreshKey(records) != key)
        #expect(UsageRefreshKey(Array(records.dropLast())) != key)
        #expect(UsageRefreshKey([]) == UsageRefreshKey([]))
    }

    // MARK: Settings

    @Test func openingSettingsNeitherRequestsModelListsNorReadsSecrets() async {
        let store = MockCredentialStore(key: "sk-placeholder-not-a-real-key")
        let client = CountingModelsClient()
        let settings = ProviderSettingsViewModel(credentials: store, modelsClient: client)
        await settings.refresh()
        #expect(settings.keyIsConfigured)
        #expect(await client.requests == 0)
        #expect(await store.secretReads == 0)
    }

    // MARK: Transcript accessibility and search state

    @Test func transcriptSegmentIsSpokenAsSpeakerTimeText() {
        #expect(TranscriptView.spokenLabel(speaker: "Alex", time: "1:05", text: "Hello") == "Alex, 1:05, Hello")
        #expect(TranscriptView.spokenLabel(speaker: nil, time: "1:05", text: "Hello") == "1:05, Hello")
        #expect(TranscriptView.spokenLabel(speaker: "", time: "0:00", text: "Hi") == "0:00, Hi")
    }

    @Test func transcriptSearchDistinguishesNoMatchesFromPendingSearch() async throws {
        let transcript = try #require(try PerformanceFixtures.recording(.small).transcript)
        let model = TranscriptViewModel()
        await model.load(transcript)
        #expect(model.searchedQuery == "")
        #expect(model.visibleSegments.count == 50)

        await model.search("zzzzqqqq", debounce: false)
        #expect(model.searchedQuery == "zzzzqqqq")
        #expect(model.visibleSegments.isEmpty)

        await model.search("Segment 7", debounce: false)
        #expect(model.searchedQuery == "Segment 7")
        #expect(!model.visibleSegments.isEmpty)
    }

    @Test func projectHeaderIsSpokenAsNameCountsAndDescription() {
        #expect(ProjectWorkspaceView.headerLabel(name: "Launch", recordings: 2, sources: 1, description: "Plan") == "Launch. 2 recordings, 1 source. Plan")
        #expect(ProjectWorkspaceView.headerLabel(name: "Launch", recordings: 0, sources: 0, description: nil) == "Launch. 0 recordings, 0 sources")
    }

    // MARK: Preview fixtures

    @Test func previewFixturesAreInMemoryDeterministicAndTouchNoFiles() throws {
        let root = PreviewFixtures.storage.rootURL
        #expect(root.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        try? FileManager.default.removeItem(at: root)

        let container = PreviewFixtures.container()
        #expect(container.configurations.allSatisfy { $0.isStoredInMemoryOnly })
        let populated = PreviewFixtures.project(populated: true, in: container.mainContext)
        #expect(populated.recordings.count == 2)
        #expect(populated.sources.count == 3)
        #expect(populated.id == PreviewFixtures.id("project"))
        let emptyContainer = PreviewFixtures.container()
        let empty = PreviewFixtures.project(populated: false, in: emptyContainer.mainContext)
        #expect(empty.recordings.isEmpty && empty.sources.isEmpty)

        #expect(!FileManager.default.fileExists(atPath: root.path))
        // Citation fixtures are valid, readable labels (accessibility text is derived from them).
        #expect(PreviewFixtures.citations.map(\.label) == ["Lecture Slides · p. 23", "Planning meeting · 12:34"])
    }
}
