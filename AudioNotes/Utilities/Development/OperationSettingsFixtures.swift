#if DEBUG
import CryptoKit
import Foundation
import SwiftUI

/// The real Local Settings surface with isolated preferences, a temporary store,
/// and byte-writing mock I/O. It cannot contact a server or install a real model.
struct OperationSettingsFixtureView: View {
    @State private var model: LocalAISettingsViewModel

    init() {
        let defaults = UserDefaults(suiteName: "AudioNotes-M14.3-Settings-Fixture")!
        defaults.removePersistentDomain(forName: "AudioNotes-M14.3-Settings-Fixture")
        let configuration = LocalAIConfiguration(defaults: defaults)
        configuration.localOnly = true
        // Privacy validation rejects this external endpoint before any request.
        configuration.ollamaAddress = "https://offline-fixture.invalid"
        let root = LibraryStorage().rootURL.appending(path: "M14.3-Download-Fixture")
        let files = [false, true].map { failure in
            WhisperModelDescriptor(id: failure ? "fixture-failure" : "fixture-success",
                title: failure ? "Offline failure fixture · not a model" : "Offline download fixture · not a model",
                files: [.init(path: "fixture.bin", url: URL(string: "https://huggingface.co/offline-fixture/\(failure ? "failure" : "success")")!,
                    size: Int64(FixtureModelDownloader.bytes.count),
                    sha256: SHA256.hash(data: FixtureModelDownloader.bytes).map { String(format: "%02x", $0) }.joined())])
        }
        _model = State(initialValue: LocalAISettingsViewModel(configuration: configuration,
            store: WhisperModelStore(root: root, downloader: FixtureModelDownloader(root: root)), models: files))
    }

    var body: some View {
        Form {
            Section {
                Text("Offline Settings fixture").font(.headline)
                Text("Synthetic bytes only. No server requests, credentials, real models or metered AI.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LocalAISettingsView(model: model)
        }.formStyle(.grouped).padding(WorkspaceSpacing.majorSection)
    }
}

private struct FixtureModelDownloader: WhisperModelFileDownloading {
    static let bytes = Data(repeating: 0x42, count: 16_384)
    let root: URL

    func download(url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let temporary = root.appending(path: UUID().uuidString + ".tmp")
        try Data().write(to: temporary)
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: temporary) } }
        let file = try FileHandle(forWritingTo: temporary)
        defer { try? file.close() }
        for offset in stride(from: 0, to: Self.bytes.count, by: 4096) {
            try await Task.sleep(for: .seconds(2))
            try Task.checkCancellation()
            if url.lastPathComponent == "failure" { throw LocalAIError.invalidResponse }
            try file.write(contentsOf: Self.bytes[offset..<offset + 4096])
            progress(Int64(offset + 4096))
        }
        succeeded = true
        return temporary
    }
}
#endif
