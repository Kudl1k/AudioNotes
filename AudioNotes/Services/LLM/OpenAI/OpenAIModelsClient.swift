import Foundation

public struct OpenAIModelItem: Identifiable, Hashable, Codable, Sendable {
    public var id: String { slug }
    public let slug: String
    public let displayName: String
    public let visibility: String?
    public let priority: Int?

    public init(slug: String, displayName: String, visibility: String? = nil, priority: Int? = nil) {
        self.slug = slug
        self.displayName = displayName
        self.visibility = visibility
        self.priority = priority
    }

    enum CodingKeys: String, CodingKey {
        case slug
        case id
        case displayName = "display_name"
        case visibility
        case priority
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let s = (try? container.decode(String.self, forKey: .slug))
            ?? (try? container.decode(String.self, forKey: .id))
            ?? ""
        self.slug = s
        let d = (try? container.decode(String.self, forKey: .displayName))
            ?? (s.isEmpty ? "Unknown Model" : s)
        self.displayName = d
        self.visibility = try? container.decode(String.self, forKey: .visibility)
        self.priority = try? container.decode(Int.self, forKey: .priority)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(slug, forKey: .slug)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(visibility, forKey: .visibility)
        try container.encodeIfPresent(priority, forKey: .priority)
    }
}

public protocol OpenAIModelsFetching: Sendable {
    func fetchModels(bearerToken: String) async throws -> [OpenAIModelItem]
}

public actor OpenAIModelsClient: OpenAIModelsFetching {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchModels(bearerToken: String) async throws -> [OpenAIModelItem] {
        guard let url = URL(string: "https://api.openai.com/v1/models") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        DebugLogService.shared.info(
            subsystem: "OpenAIModelsClient",
            message: "Requesting GET /v1/models"
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            DebugLogService.shared.error(
                subsystem: "OpenAIModelsClient",
                message: "Network request failed: \(error.localizedDescription)"
            )
            throw LLMError.network(code: (error as? URLError)?.errorCode ?? -1)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.network(code: URLError.badServerResponse.rawValue)
        }

        DebugLogService.shared.info(
            subsystem: "OpenAIModelsClient",
            message: "GET /v1/models returned HTTP \(http.statusCode)"
        )

        guard (200..<300).contains(http.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            DebugLogService.shared.error(
                subsystem: "OpenAIModelsClient",
                message: "GET /v1/models rejected: HTTP \(http.statusCode) - \(errorBody)"
            )
            throw LLMError.rejected(status: http.statusCode, message: errorBody)
        }

        let envelope = try JSONDecoder().decode(OpenAIModelsResponseEnvelope.self, from: data)
        return envelope.models
    }
}

struct OpenAIModelsResponseEnvelope: Decodable {
    let models: [OpenAIModelItem]

    enum CodingKeys: String, CodingKey {
        case models
        case data
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let list = try? container.decode([OpenAIModelItem].self, forKey: .models) {
            self.models = list
        } else if let list = try? container.decode([OpenAIModelItem].self, forKey: .data) {
            self.models = list
        } else {
            self.models = []
        }
    }
}
