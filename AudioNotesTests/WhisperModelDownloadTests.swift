import Foundation
import Testing
@testable import AudioNotes

@Suite(.serialized)
@MainActor struct WhisperModelDownloadTests {
    private func fixture() throws -> (URL, WhisperModelDescriptor) {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let descriptor = WhisperModelDescriptor(id: "tiny-test", title: "Tiny test", files: [
            .init(path: "weights/data", url: URL(string: "https://huggingface.co/trusted/resolve/pinned/weights")!, size: 3,
                  sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")])
        return (root, descriptor)
    }
    private func settings(store: WhisperModelStore, model: WhisperModelDescriptor) -> LocalAISettingsViewModel {
        let defaults = UserDefaults(suiteName: "WhisperSettings-" + UUID().uuidString)!
        return LocalAISettingsViewModel(configuration: LocalAIConfiguration(defaults: defaults), store: store, models: [model])
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        // A busy hosted runner can delay MainActor progress publication beyond
        // 15 seconds. Keep a bounded wait without requiring desktop throughput.
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "Timed out waiting for Whisper settings state after 60 seconds")
    }

    @Test func settingsRefreshPreservesActiveDownloadAndPreventsDuplicateOperations() async throws {
        let (root, descriptor) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let downloader = PausedModelDownloader()
        let store = WhisperModelStore(root: root, downloader: downloader)
        let model = settings(store: store, model: descriptor)
        defer { model.cancelDownload() }
        model.download(descriptor)
        try await waitUntil { model.progress?.completedBytes == 1 }

        // Returning to Local AI refreshes installed models on the shared view model.
        await model.refreshInstalled()
        #expect(model.downloadModelID == descriptor.id)
        #expect(model.progress?.completedBytes == 1)
        #expect(!model.installed.contains(descriptor.id))
        model.download(descriptor)
        #expect(await downloader.calls == 1)
        #expect(model.error == nil)

        await downloader.finish()
        try await waitUntil { model.downloadModelID == nil }
        #expect(model.progress == nil)
        #expect(model.installed.contains(descriptor.id))
        #expect(model.error == nil)
    }

    @Test func settingsCanCancelDownloadAfterReturningAndRetry() async throws {
        let (root, descriptor) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let downloader = PausedModelDownloader()
        let store = WhisperModelStore(root: root, downloader: downloader)
        let model = settings(store: store, model: descriptor)
        defer { model.cancelDownload() }
        model.download(descriptor)
        try await waitUntil { model.progress?.completedBytes == 1 }
        await model.refreshInstalled()
        model.cancelDownload()
        try await waitUntil { model.downloadModelID == nil }
        #expect(model.progress == nil)
        #expect(model.error == nil)
        #expect(await store.isReady(descriptor) == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)

        await downloader.finish()
        model.download(descriptor)
        try await waitUntil { model.downloadModelID == nil }
        #expect(model.installed.contains(descriptor.id))
        #expect(await downloader.calls == 2)
    }

    @Test func settingsRetainFailureForReturnToLocalAI() async throws {
        let (root, descriptor) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WhisperModelStore(root: root, downloader: FakeModelDownloader(bytes: Data("xyz".utf8)))
        let model = settings(store: store, model: descriptor)
        model.download(descriptor)
        try await waitUntil { model.downloadModelID == nil }
        await model.refreshInstalled()
        #expect(model.error != nil)
        #expect(model.progress == nil)
        #expect(!model.installed.contains(descriptor.id))
        try await store.acquire(); await store.release()
    }

    @Test func successfulInstallVerifiesHashAndPublishesReadyAtomically() async throws {
        let (root, model) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WhisperModelStore(root: root, downloader: FakeModelDownloader(bytes: Data("abc".utf8)))
        try await store.install(model) { _ in }
        #expect(await store.isReady(model))
        let directory = await store.folder(model)
        #expect(try Data(contentsOf: directory.appendingPathComponent("weights/data")) == Data("abc".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["tiny-test"])
    }
    @Test func corruptedDownloadCleansStagingAndNeverMarksReady() async throws {
        let (root, model) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WhisperModelStore(root: root, downloader: FakeModelDownloader(bytes: Data("xyz".utf8)))
        await #expect(throws: LocalAIError.self) { try await store.install(model) { _ in } }
        #expect(await store.isReady(model) == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        try await store.acquire(); await store.release()
    }
    @Test func insufficientDiskSpaceFailsBeforeNetwork() async throws {
        let (root, model) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let download = FakeModelDownloader(bytes: Data("abc".utf8))
        let store = WhisperModelStore(root: root, downloader: download, capacity: { _ in 1 })
        await #expect(throws: LocalAIError.insufficientDiskSpace) { try await store.install(model) { _ in } }
        #expect(await download.calls == 0)
    }
    @Test func cancelledDownloadCleansAndReleasesModelLease() async throws {
        let (root, model) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WhisperModelStore(root: root, downloader: FakeModelDownloader(bytes: Data(), cancel: true))
        await #expect(throws: CancellationError.self) { try await store.install(model) { _ in } }
        #expect(await store.isReady(model) == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        try await store.acquire(); await store.release()
    }
}

private actor FakeModelDownloader: WhisperModelFileDownloading {
    let bytes: Data
    let cancel: Bool
    var calls = 0
    init(bytes: Data, cancel: Bool = false) { self.bytes = bytes; self.cancel = cancel }
    func download(url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        calls += 1
        if cancel { throw CancellationError() }
        let file = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: file)
        progress(Int64(bytes.count))
        return file
    }
}

private actor PausedModelDownloader: WhisperModelFileDownloading {
    var calls = 0
    private var finished = false

    func finish() { finished = true }

    func download(url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        calls += 1
        progress(1)
        while !finished { try await Task.sleep(for: .milliseconds(10)) }
        try Task.checkCancellation()
        let file = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("abc".utf8).write(to: file)
        progress(3)
        return file
    }
}
