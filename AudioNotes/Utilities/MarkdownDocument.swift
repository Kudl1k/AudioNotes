import Foundation

/// A small block parser; Foundation handles inline Markdown. No HTML interpretation.
struct MarkdownDocument: Equatable, Sendable {
    indirect enum Block: Equatable, Sendable {
        case paragraph(String)
        case heading(Int, String)
        case list([ListItem])
        case code(language: String, text: String)
        case quote([Block])
        case table(header: [String], rows: [[String]])
        case separator
    }
    struct ListItem: Equatable, Sendable {
        var marker: String
        var blocks: [Block]
    }
    var blocks: [Block]

    init(_ markdown: String) {
        blocks = Self.parse(markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n"))
    }

    static func inline(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(markdown)
    }

    private static let listRegex = try! NSRegularExpression(pattern: "^( *)([-+*]|[0-9]+[.)])\\s+(.*)$")

    private static func listPrefix(_ line: String) -> (indent: Int, marker: String, text: String)? {
        guard let match = listRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let indent = Range(match.range(at: 1), in: line),
              let marker = Range(match.range(at: 2), in: line),
              let text = Range(match.range(at: 3), in: line) else { return nil }
        return (line[indent].count, String(line[marker]), String(line[text]))
    }

    private static func tableCells(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        // Escaped pipes and pipes inside inline code remain cell content.
        var cells: [String] = [], cell = "", escaped = false, code = false
        for character in value {
            if escaped { cell.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; cell.append(character); continue }
            if character == "`" { code.toggle() }
            if character == "|" && !code { cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" }
            else { cell.append(character) }
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }
    private static func tableDelimiter(_ line: String, columns: Int) -> Bool {
        let cells = tableCells(line)
        return cells.count == columns && cells.allSatisfy { cell in
            let value = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return value.count >= 3 && value.allSatisfy { $0 == "-" }
        }
    }

    private static func parse(_ lines: [String]) -> [Block] {
        var blocks: [Block] = []
        var index = 0
        func trimmed(_ line: String) -> String { line.trimmingCharacters(in: .whitespaces) }
        func startsBlock(_ line: String) -> Bool {
            let text = trimmed(line)
            return text.isEmpty || text.hasPrefix("#") || text.hasPrefix("```") || text.hasPrefix("~~~") || text.hasPrefix(">") || listPrefix(line) != nil || ["---", "***", "___"].contains(text)
        }
        while index < lines.count {
            let text = trimmed(lines[index])
            if text.isEmpty { index += 1; continue }
            if index + 1 < lines.count, text.contains("|"), tableDelimiter(lines[index + 1], columns: tableCells(text).count) {
                let header = tableCells(text)
                index += 2
                var rows: [[String]] = []
                while index < lines.count, lines[index].contains("|"), !trimmed(lines[index]).isEmpty {
                    let cells = tableCells(lines[index])
                    rows.append(Array((cells + Array(repeating: "", count: header.count)).prefix(header.count)))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
            } else if text.hasPrefix("```") || text.hasPrefix("~~~") {
                let character = text.first!
                let fence = String(text.prefix(while: { $0 == character }))
                let language = String(text.dropFirst(fence.count))
                index += 1
                var code: [String] = []
                while index < lines.count && !trimmed(lines[index]).hasPrefix(fence) {
                    code.append(lines[index]); index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.code(language: language, text: code.joined(separator: "\n")))
            } else if text.hasPrefix("#"), let space = text.firstIndex(of: " "), text[..<space].allSatisfy({ $0 == "#" }), text.distance(from: text.startIndex, to: space) <= 6 {
                blocks.append(.heading(text.distance(from: text.startIndex, to: space), String(text[text.index(after: space)...])))
                index += 1
            } else if ["---", "***", "___"].contains(text) {
                blocks.append(.separator); index += 1
            } else if text.hasPrefix(">") {
                var quote: [String] = []
                while index < lines.count && trimmed(lines[index]).hasPrefix(">") {
                    let remainder = trimmed(lines[index]).dropFirst()
                    quote.append(remainder.hasPrefix(" ") ? String(remainder.dropFirst()) : String(remainder))
                    index += 1
                }
                blocks.append(.quote(parse(quote)))
            } else if let first = listPrefix(lines[index]) {
                var items: [ListItem] = []
                while index < lines.count, let item = listPrefix(lines[index]), item.indent == first.indent {
                    var body = [item.text]
                    let contentIndent = item.indent + item.marker.count + 1
                    index += 1
                    while index < lines.count {
                        let line = lines[index]
                        if let next = listPrefix(line), next.indent <= first.indent { break }
                        if trimmed(line).isEmpty {
                            var next = index + 1
                            while next < lines.count && trimmed(lines[next]).isEmpty { next += 1 }
                            if next >= lines.count || lines[next].prefix(while: { $0 == " " }).count <= first.indent { break }
                            body.append(""); index += 1; continue
                        }
                        let indentation = line.prefix(while: { $0 == " " }).count
                        if indentation <= first.indent { break }
                        body.append(String(line.dropFirst(min(indentation, contentIndent))))
                        index += 1
                    }
                    items.append(ListItem(marker: item.marker.first?.isNumber == true ? item.marker : "•", blocks: parse(body)))
                    while index < lines.count && trimmed(lines[index]).isEmpty { index += 1 }
                }
                blocks.append(.list(items))
            } else {
                var paragraph = [lines[index]]
                index += 1
                while index < lines.count && !startsBlock(lines[index]) {
                    if index + 1 < lines.count, lines[index].contains("|"), tableDelimiter(lines[index + 1], columns: tableCells(lines[index]).count) { break }
                    paragraph.append(lines[index]); index += 1
                }
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            }
        }
        return blocks
    }
}
