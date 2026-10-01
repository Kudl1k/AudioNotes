import Foundation

/// Request-scoped authority for future consumers. Rebuild from a fresh scope snapshot
/// before accepting historical/model references; never parse locations out of prose.
struct RetrievalReferenceIndex: Sendable {
    let scope: RetrievalScope
    private let documents: [UUID: RetrievalDocument]

    init(scope: RetrievalScope, documents: [RetrievalDocument], options: RetrievalOptions = .init()) {
        self.scope = scope
        self.documents = Dictionary(documents.filter { document in
            guard options.includes(document) else { return false }
            switch scope {
            case .recording(let id): return document.recordingID == id
            case .project(let id): return document.projectID == id
            }
        }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func resolve(documentIDs: [String]) -> [ContextEntry] {
        var seen = Set<UUID>()
        return documentIDs.compactMap { raw in
            guard let id = UUID(uuidString: raw), let document = documents[id], seen.insert(id).inserted else { return nil }
            return ContextEntry(document: document, relevance: 0)
        }
    }
}
