import Foundation
import Observation

@MainActor @Observable final class LocalAISettingsViewModel {
    let configuration: LocalAIConfiguration
    let models: [WhisperModelDescriptor]
    let store: WhisperModelStore
    let client: OllamaClient
    private(set) var connectionState: ProviderConnectionState = .disconnected
    private(set) var connection = "Not checked"
    private(set) var checking = false
    private(set) var storageBytes: Int64?
    private(set) var failedModelID: String?
    private(set) var installed: Set<String> = []
    private(set) var downloadModelID: String?
    private(set) var downloadStartedAt: Date?
    private(set) var progress: LocalModelDownloadProgress?
    private(set) var error: String?
    @ObservationIgnored private var downloadOperationID: UUID?
    @ObservationIgnored private var task: Task<Void, Never>?
    static var languages: [String] { LocalWhisperRuntimeCapabilities.languageCodes.sorted { (Locale.current.localizedString(forLanguageCode: $0) ?? $0) < (Locale.current.localizedString(forLanguageCode: $1) ?? $1) } }
    static var supportsWhisper: Bool { LocalWhisperRuntimeCapabilities.isSupported }
    init(configuration: LocalAIConfiguration, store: WhisperModelStore, client: OllamaClient = OllamaClient(),
         models: [WhisperModelDescriptor] = WhisperModelDescriptor.selectable) {
        self.configuration = configuration; self.store = store; self.client = client; self.models = models
    }
    func refresh() async {
        await refreshInstalled()
        await refreshOllama()
    }
    func refreshInstalled() async {
        var ready = Set<String>()
        for model in models where await store.isReady(model) { ready.insert(model.id) }
        installed = ready
        storageBytes = try? await store.diskUsage()
    }
    func refreshOllama() async {
        guard !checking else { return }
        checking = true; connectionState = .connecting; connection = "Checking…"
        defer { checking = false }
        do {
            let endpoint = try OllamaEndpoint(configuration.ollamaAddress)
            try configuration.policy.validate(endpoint.executionLocation)
            let discovered = try await client.models(endpoint: endpoint)
            try Task.checkCancellation()
            connectionState = .connected
            configuration.models = discovered
            connection = endpoint.executionLocation == .local ? "Connected · Running on this Mac" : "Connected · Remote Ollama server"
            if discovered.isEmpty { connection += " · No usable installed chat models; install or repair a model in Ollama." }
        } catch {
            connectionState = .failed
            configuration.models = []
            connection = error.localizedDescription
        }
    }
    func download(_ model: WhisperModelDescriptor) {
        guard task == nil else { return }
        error = nil; failedModelID = nil; downloadModelID = model.id; downloadStartedAt = .now
        progress = .init(completedBytes: 0, totalBytes: model.downloadBytes)
        let operationID = UUID()
        downloadOperationID = operationID
        task = Task { [self] in
            defer { downloadOperationID = nil; downloadModelID = nil; downloadStartedAt = nil; progress = nil; task = nil }
            do {
                try await store.install(model) { [self] update in Task { @MainActor [self] in if downloadOperationID == operationID { progress = update } } }
                await refreshInstalled()
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription; self.failedModelID = model.id }
            }
        }
    }
#if DEBUG
    func prepareIOSReviewState(_ state: String) {
        guard let model = models.first else { return }
        error = nil; failedModelID = nil; installed = []; progress = nil; downloadModelID = nil
        switch state {
        case "ready": installed = [model.id]; storageBytes = model.downloadBytes
        case "downloading":
            downloadModelID = model.id
            progress = .init(completedBytes: model.downloadBytes / 3, totalBytes: model.downloadBytes)
        case "failed": failedModelID = model.id; error = "Download interrupted. Check your connection and retry."
        default: break
        }
    }
#endif
    func cancelDownload() { task?.cancel() }
    func remove(_ model: WhisperModelDescriptor) async {
        error = nil
        do { try await store.remove(model); await refreshInstalled() }
        catch { self.error = error.localizedDescription }
    }
}
