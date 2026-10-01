import Foundation

struct ClaudeCLIModel: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    var description: String? = nil
    var resolvedModel: String? = nil

    enum CodingKeys: String, CodingKey {
        case id = "value"
        case displayName, description, resolvedModel
    }

    /// Keep existing aliases/full IDs selected even when the CLI stops listing them.
    /// Refreshing discovery must never silently change the model used for generation.
    static func options(_ models: [Self], preserving selection: String) -> [Self] {
        guard !models.contains(where: { $0.id == selection }) else { return models }
        let title = models.first(where: { $0.resolvedModel == selection })?.displayName ?? selection
        return [Self(id: selection, displayName: "\(title) (saved selection)")] + models
    }
}

protocol ClaudeCLIModelsFetching: Sendable {
    func fetchModels(executable: String) async throws -> [ClaudeCLIModel]
}

struct ClaudeCLIModelsClient: ClaudeCLIModelsFetching {
    let runner: any ClaudeCLIRunning
    init(runner: any ClaudeCLIRunning = ClaudeCLIRunner(timeout: .seconds(30))) { self.runner = runner }
    func fetchModels(executable: String) async throws -> [ClaudeCLIModel] {
        try await ClaudeCLIClient(executable: executable, runner: runner).models()
    }
}
