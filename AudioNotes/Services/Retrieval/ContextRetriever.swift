import Foundation
import SwiftData

/// Derived, bounded, disposable indexes. Actor isolation keeps publication/search atomic.
actor ContextRetriever {
    private struct CachedSource: Sendable {
        let input: RetrievalSnapshot.Source
        let documents: [RetrievalDocument]
    }
    private struct CachedScope: Sendable {
        let sources: [UUID: CachedSource]
        let index: LexicalIndex
        let semanticIndex: SemanticIndex?
        var lastUse: UInt64
        let textBytes: Int
    }
    private var caches: [RetrievalScope: CachedScope] = [:]
    private var sequence: UInt64 = 0
    let maximumCachedScopes: Int
    let maximumCachedTextBytes: Int
    private let embeddingProvider: (any EmbeddingProvider)?

    init(maximumCachedScopes: Int = 3, maximumCachedTextBytes: Int = 48 * 1024 * 1024,
         embeddingProvider: (any EmbeddingProvider)? = nil) {
        self.maximumCachedScopes = max(0, maximumCachedScopes)
        self.maximumCachedTextBytes = max(0, maximumCachedTextBytes)
        self.embeddingProvider = embeddingProvider
    }

    func retrieve(query: String, snapshot: RetrievalSnapshot, options: RetrievalOptions = .init()) async throws -> RetrievalResult {
        try Task.checkCancellation()
        let clock = ContinuousClock()
        let start = clock.now
        let previous = caches[snapshot.scope]
        var sources: [UUID: CachedSource] = [:]
        var changed = previous == nil
        for source in snapshot.sources.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            try Task.checkCancellation()
            if let cached = previous?.sources[source.id], cached.input == source { sources[source.id] = cached }
            else {
                changed = true
                sources[source.id] = .init(input: source, documents: try RetrievalDocumentBuilder().documents(source: source))
            }
        }
        if previous?.sources.count != sources.count { changed = true }
        let index: LexicalIndex
        if !changed, let previous { index = previous.index }
        else { index = try LexicalIndex(documents: sources.values.flatMap(\.documents)) }
        let documents = index.documents
        var semanticIndex = previous?.semanticIndex
        if let provider = embeddingProvider, provider.isLocal,
           (changed || semanticIndex?.providerID != provider.identifier || semanticIndex?.modelVersion != provider.modelVersion) {
            semanticIndex = nil
            do {
                if !documents.isEmpty {
                    let vectors = try await provider.embed(documents.map(\.text))
                    try Task.checkCancellation()
                    semanticIndex = try SemanticIndex(provider: provider, documents: documents, vectors: vectors)
                }
            } catch {
                // Semantic retrieval is an optional enhancement; preserve lexical service on every failure.
                if error is CancellationError { throw error }
                semanticIndex = nil
            }
        }
        let built = start.duration(to: clock.now)
        let queryStart = clock.now
        let assembler = ContextAssembler()
        let candidateLimit = max(30, options.limit * 2)
        var candidateOptions = options; candidateOptions.limit = candidateLimit
        let lexical = try index.search(query: query, options: candidateOptions)
        let ranked: [RetrievalMatch]
        if let semanticIndex, let provider = embeddingProvider, provider.isLocal {
            do {
                let vectors = try await provider.embed([query])
                guard let vector = vectors.first else { throw SemanticRetrievalError.invalidIndex }
                let semantic = try semanticIndex.search(queryVector: vector, options: candidateOptions)
                ranked = RetrievalRankFusion.fuse(lexical: lexical, semantic: semantic, limit: candidateLimit)
            } catch {
                if error is CancellationError { throw error }
                ranked = lexical
            }
        } else { ranked = lexical }
        let matches = try assembler.diversify(ranked, options: options)
        let context = try assembler.assemble(query: query, scope: snapshot.scope, matches: matches,
                                             documents: documents, options: options)
        try Task.checkCancellation()
        sequence &+= 1
        let bytes = snapshot.sources.reduce(0) { total, source in
            total + source.segments.reduce(0) { $0 + $1.text.utf8.count } + source.units.reduce(0) { $0 + $1.text.utf8.count }
        }
        caches[snapshot.scope] = .init(sources: sources, index: index, semanticIndex: semanticIndex, lastUse: sequence, textBytes: bytes)
        evict()
        return .init(query: query, scope: snapshot.scope, matches: matches, coverage: snapshot.coverage, recordings: snapshot.recordings,
            statistics: .init(documentCount: index.documents.count, rebuiltIndex: changed,
                              indexBuildDuration: built, queryDuration: queryStart.duration(to: clock.now)), context: context)
    }

    func remove(_ scope: RetrievalScope) { caches.removeValue(forKey: scope) }
    func removeAll() { caches.removeAll() }
    var cachedScopeCount: Int { caches.count }

    private func evict() {
        while caches.count > maximumCachedScopes || caches.values.reduce(0, { $0 + $1.textBytes }) > maximumCachedTextBytes {
            guard let oldest = caches.min(by: { $0.value.lastUse < $1.value.lastUse })?.key else { break }
            caches.removeValue(forKey: oldest)
        }
    }
}

/// Library/window lifetime, independent of ProjectView. Snapshot on the owning actor,
/// indexing/scoring on the retrieval actor, cancellation propagated into worker passes.
@MainActor
final class RetrievalService {
    private let retriever: ContextRetriever
    private var tasks: [RetrievalScope: Task<RetrievalResult, Error>] = [:]
    private var requests: [RetrievalScope: UUID] = [:]
    private var deleting = Set<RetrievalScope>()

    init(retriever: ContextRetriever = ContextRetriever()) { self.retriever = retriever }

    func retrieve(query: String, scope: RetrievalScope, context: ModelContext,
                  options: RetrievalOptions = .init()) async throws -> RetrievalResult {
        try Task.checkCancellation()
        guard !deleting.contains(scope) else { throw RetrievalError.scopeMissing }
        tasks[scope]?.cancel()
        let request = UUID()
        requests[scope] = request
        let snapshot: RetrievalSnapshot
        do { snapshot = try RetrievalSnapshot.capture(scope: scope, context: context) }
        catch {
            tasks.removeValue(forKey: scope)
            requests.removeValue(forKey: scope)
            await retriever.remove(scope)
            throw error
        }
        let retriever = retriever
        let worker = Task.detached(priority: .userInitiated) {
            try await retriever.retrieve(query: query, snapshot: snapshot, options: options)
        }
        tasks[scope] = worker
        defer {
            if requests[scope] == request { tasks.removeValue(forKey: scope); requests.removeValue(forKey: scope) }
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            guard requests[scope] == request, !deleting.contains(scope) else { throw CancellationError() }
            return result
        } onCancel: { worker.cancel() }
    }

    func isRetrieving(_ scope: RetrievalScope) -> Bool { tasks[scope] != nil }

    /// Block new queries, cancel/await work, then discard derived state before metadata deletion.
    func beginDeletion(_ scope: RetrievalScope) async {
        deleting.insert(scope)
        requests.removeValue(forKey: scope)
        let task = tasks.removeValue(forKey: scope)
        task?.cancel()
        _ = try? await task?.value
        await retriever.remove(scope)
    }
    func endDeletion(_ scope: RetrievalScope) { deleting.remove(scope) }
}
