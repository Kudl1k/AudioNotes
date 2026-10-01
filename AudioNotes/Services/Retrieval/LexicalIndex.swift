import Foundation

/// Accent folding supports Czech queries entered without diacritics. Original text is untouched.
enum RetrievalTokenizer {
    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    static func terms(_ text: String) -> [String] {
        normalize(text).split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "/" && $0 != "-" }
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "_/-")) }.filter { !$0.isEmpty }
    }
    /// Conservative down-weighting, no stemming or deletion of technical/quoted words.
    static func queryWeight(_ term: String) -> Double {
        filler.contains(term) ? 0.15 : 1
    }
    private static let filler: Set<String> = ["what", "does", "did", "he", "she", "the", "a", "an", "about", "can", "you", "please", "explain", "say", "said", "kde", "co", "jak", "prosim", "vysvetli", "vysvetloval"]
}

protocol RetrievalBackend: Sendable {
    func search(query: String, options: RetrievalOptions) throws -> [RetrievalMatch]
}

/// Immutable BM25 inverted index. Only postings for query terms are visited during scoring.
struct LexicalIndex: RetrievalBackend {
    private struct Posting: Sendable { let index: Int; let frequency: Int }
    let documents: [RetrievalDocument]
    private let lengths: [Int]
    private let phraseText: [String]
    private let averageLength: Double
    private let postings: [String: [Posting]]
    private let titlePostings: [String: Set<Int>]

    init(documents: [RetrievalDocument]) throws {
        let interval = PerformanceSignposts.begin("Retrieval index build")
        defer { PerformanceSignposts.end("Retrieval index build", interval) }
        self.documents = documents.sorted { $0.id.uuidString < $1.id.uuidString }
        var lengths: [Int] = []
        var phrases: [String] = []
        var postings: [String: [Posting]] = [:]
        var titles: [String: Set<Int>] = [:]
        for (index, document) in self.documents.enumerated() {
            try Task.checkCancellation()
            let terms = RetrievalTokenizer.terms(document.text)
            lengths.append(terms.count)
            phrases.append(" " + terms.joined(separator: " ") + " ")
            let counts = Dictionary(terms.map { ($0, 1) }, uniquingKeysWith: +)
            for (term, frequency) in counts { postings[term, default: []].append(.init(index: index, frequency: frequency)) }
            let metadata = document.title + " " + document.chunk.sourceName
            let metadataTerms = RetrievalTokenizer.terms(metadata) + RetrievalTokenizer.terms(metadata.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "/", with: " "))
            for term in Set(metadataTerms) {
                titles[term, default: []].insert(index)
            }
        }
        self.lengths = lengths
        phraseText = phrases
        averageLength = max(1, Double(lengths.reduce(0, +)) / Double(max(1, lengths.count)))
        self.postings = postings
        titlePostings = titles
    }

    func search(query: String, options: RetrievalOptions = .init()) throws -> [RetrievalMatch] {
        let interval = PerformanceSignposts.begin("Retrieval lexical search")
        defer { PerformanceSignposts.end("Retrieval lexical search", interval) }
        let queryTerms = RetrievalTokenizer.terms(query)
        guard !queryTerms.isEmpty, options.limit > 0 else { return [] }
        var bodyScores: [Int: Double] = [:]
        var titleScores: [Int: Double] = [:]
        for term in Set(queryTerms).sorted() {
            try Task.checkCancellation()
            let hits = postings[term] ?? []
            let idf = log(1 + (Double(documents.count - hits.count) + 0.5) / (Double(hits.count) + 0.5))
            let weight = RetrievalTokenizer.queryWeight(term)
            for hit in hits {
                guard options.includes(documents[hit.index]) else { continue }
                let frequency = Double(hit.frequency)
                let denominator = frequency + 1.2 * (0.25 + 0.75 * Double(lengths[hit.index]) / averageLength)
                bodyScores[hit.index, default: 0] += weight * idf * frequency * 2.2 / denominator
            }
            for index in (titlePostings[term] ?? []).sorted() where options.includes(documents[index]) {
                titleScores[index, default: 0] += 0.12 * weight
            }
        }
        let phrase = queryTerms.joined(separator: " ")
        var matches: [RetrievalMatch] = []
        for index in Set(bodyScores.keys).union(titleScores.keys).sorted() {
            try Task.checkCancellation()
            let document = documents[index]
            let body = bodyScores[index, default: 0]
            let metadata = min(0.4, titleScores[index, default: 0])
            let exact = phraseText[index].contains(" " + phrase + " ")
            let phraseBoost = exact ? min(1, body * 0.25) : 0
            matches.append(.init(document: document, score: body + metadata + phraseBoost,
                                 bodyScore: body, metadataBoost: metadata, phraseBoost: phraseBoost))
        }
        return matches.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.document.id.uuidString < $1.document.id.uuidString
        }
    }
}
