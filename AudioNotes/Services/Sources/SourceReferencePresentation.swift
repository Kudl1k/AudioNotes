import Foundation

struct SourceReferenceGroup: Identifiable {
    let id: String
    var references: [SourceReference]
    var primary: SourceReference { references[0] }
    var label: String { primary.label }
    var excerpt: String { references.map(\.excerpt).filter { !$0.isEmpty }.prefix(3).joined(separator: "\n") }
}

/// Display grouping only: retain all authoritative region/chunk references in persistence.
struct SourceReferencePresentation {
    static func groups(_ references: [SourceReference]) -> [SourceReferenceGroup] {
        var results: [SourceReferenceGroup] = []
        var indexes: [String: Int] = [:]
        var seen = Set<UUID>()
        for reference in references where seen.insert(reference.chunkID).inserted {
            let location: String
            switch reference.locator {
            case .image: location = "image"
            case .pdf(let page): location = "page-\(page)"
            case .document(let section, _, _): location = "section-\(section)"
            case .audio(_, let start, _): location = "audio-\(start)"
            }
            let key = reference.sourceID.uuidString + "-" + location
            if let index = indexes[key] { results[index].references.append(reference) }
            else {
                indexes[key] = results.count
                results.append(.init(id: key, references: [reference]))
            }
        }
        return results
    }
    static func labels(_ references: [SourceReference]) -> [String] { groups(references).map(\.label) }
}
