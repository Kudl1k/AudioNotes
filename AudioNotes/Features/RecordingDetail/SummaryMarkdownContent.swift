import Foundation

/// Read-only rendering snapshot. No generation or export side effects.
@MainActor
enum SummaryMarkdownContent {
    static func text(_ summary: Summary) -> String {
        var sections: [String] = []
        if !summary.title.isEmpty { sections.append("# " + summary.title) }
        if !summary.overview.isEmpty { sections.append(summary.overview) }
        func items(_ title: String, _ values: [String]) {
            if !values.isEmpty { sections.append("## \(title)\n\n" + values.map { "- " + $0 }.joined(separator: "\n")) }
        }
        items("Key Points", summary.keyPoints.map(\.text))
        items("Decisions", summary.decisions.map(\.text))
        items("Action Items", summary.actionItems.map { item in
            [item.text, item.assignee.map { "Assignee: " + $0 }, item.dueDate.map { "Due: " + $0 }].compactMap { $0 }.joined(separator: " — ")
        })
        items("Open Questions", summary.openQuestions.map(\.text))
        items("Important Quotes", summary.importantQuotes.map { quote in
            [quote.speaker, quote.text].compactMap { $0 }.joined(separator: ": ")
        })
        for section in summary.additionalSections { items(section.title, section.items) }
        return sections.joined(separator: "\n\n")
    }
}
