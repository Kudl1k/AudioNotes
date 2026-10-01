import Foundation

struct ContextAssembler: Sendable {
    func assemble(query: String, scope: RetrievalScope, matches: [RetrievalMatch],
                  documents: [RetrievalDocument], options: RetrievalOptions) throws -> ContextPackage {
        let interval = PerformanceSignposts.begin("Retrieval context assembly")
        defer { PerformanceSignposts.end("Retrieval context assembly", interval) }
        var entries: [ContextEntry] = []
        var used = 0
        var seen = Set<UUID>()
        func add(_ document: RetrievalDocument, relevance: Double) throws {
            guard options.includes(document), !seen.contains(document.id) else { return }
            let entry = ContextEntry(document: document, relevance: relevance)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            // Budget the actual JSON payload including labels, provenance and escaping, plus separators.
            let tokens = TranscriptTokenEstimator.estimate(String(decoding: try encoder.encode(entry), as: UTF8.self)) + 2
            guard tokens <= max(0, options.maximumTokens) - used else { return }
            seen.insert(document.id); entries.append(entry); used += tokens
        }
        for match in matches.prefix(max(0, options.limit)) {
            try Task.checkCancellation()
            try add(match.document, relevance: match.score)
        }
        if options.includeTranscriptNeighbors {
            // Ranked evidence gets budget first. At most one adjacent window per selected audio match.
            let audio = documents.filter { $0.contentType == .transcript && options.includes($0) }
            for match in matches.prefix(max(0, options.limit)) where seen.contains(match.document.id) && match.document.contentType == .transcript {
                try Task.checkCancellation()
                guard case .audio(_, _, let end) = match.document.chunk.locator else { continue }
                let neighbor = audio.filter { candidate in
                    guard candidate.sourceID == match.document.sourceID, !seen.contains(candidate.id),
                          case .audio(_, let start, let nextEnd) = candidate.chunk.locator else { return false }
                    return start >= end - 15 && start <= end + 15 && nextEnd > end
                }.sorted { $0.id.uuidString < $1.id.uuidString }.first
                if let neighbor { try add(neighbor, relevance: match.score * 0.5) }
            }
        }
        // Retain relevance on each entry, group source excerpts, then use authoritative chronological/page order.
        entries.sort {
            if $0.document.sourceID != $1.document.sourceID { return $0.document.sourceID.uuidString < $1.document.sourceID.uuidString }
            switch ($0.document.chunk.locator, $1.document.chunk.locator) {
            case (.audio(_, let left, _), .audio(_, let right, _)) where left != right: return left < right
            case (.pdf(let left), .pdf(let right)) where left != right: return left < right
            case (.document(_, let left, _), .document(_, let right, _)) where left != right: return left < right
            default: return $0.document.id.uuidString < $1.document.id.uuidString
            }
        }
        return .init(query: query, scope: scope, entries: entries, estimatedTokenCount: used)
    }

    func diversify(_ ranked: [RetrievalMatch], options: RetrievalOptions) throws -> [RetrievalMatch] {
        let interval = PerformanceSignposts.begin("Retrieval diversification")
        defer { PerformanceSignposts.end("Retrieval diversification", interval) }
        var remaining = ranked
        var chosen: [RetrievalMatch] = []
        var counts: [UUID: Int] = [:]
        while !remaining.isEmpty && chosen.count < max(0, options.limit) {
            try Task.checkCancellation()
            var best = 0
            if options.diversify {
                // At most 10% penalty per repeated source, capped at 20%; relevance stays primary.
                for index in remaining.indices {
                    let candidate = remaining[index]
                    let current = remaining[best]
                    let value = candidate.score * (1 - min(0.2, Double(counts[candidate.document.sourceID, default: 0]) * 0.1))
                    let bestValue = current.score * (1 - min(0.2, Double(counts[current.document.sourceID, default: 0]) * 0.1))
                    if value > bestValue { best = index }
                }
            }
            let match = remaining.remove(at: best)
            if chosen.contains(where: { Self.nearDuplicate($0.document, match.document) }) { continue }
            chosen.append(match); counts[match.document.sourceID, default: 0] += 1
        }
        return chosen
    }

    private static func nearDuplicate(_ left: RetrievalDocument, _ right: RetrievalDocument) -> Bool {
        guard left.sourceID == right.sourceID else { return false }
        if left.id == right.id { return true }
        guard case .audio(_, let a, let b) = left.chunk.locator,
              case .audio(_, let c, let d) = right.chunk.locator else { return left.text == right.text && left.chunk.locator == right.chunk.locator }
        // Distinct bounded slices of an oversized segment share its locator but contain different text.
        if left.chunk.locator == right.chunk.locator { return left.text == right.text }
        let overlap = max(0, min(b, d) - max(a, c))
        return overlap / max(1, min(b - a, d - c)) >= 0.6 && left.text != "" && right.text != ""
    }
}
