import Foundation

struct StructuredChatResponse: Codable, Sendable {
    let answer: String
    let referenceSegmentIDs: [String]

    init(answer: String, referenceSegmentIDs: [String] = []) {
        self.answer = answer
        self.referenceSegmentIDs = referenceSegmentIDs
    }

    enum CodingKeys: String, CodingKey {
        case answer
        case referenceSegmentIDs = "referenceSegmentIDs"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.answer = try container.decode(String.self, forKey: .answer)
        self.referenceSegmentIDs = (try? container.decode([String].self, forKey: .referenceSegmentIDs)) ?? []
    }
}

/// Incrementally parses an OpenAI JSON stream with `{ "answer": "...", "referenceSegmentIDs": [...] }`
/// emitting unescaped text deltas for the `answer` string as they arrive.
final class StreamingJSONAnswerParser: @unchecked Sendable {
    private enum State {
        case seekingAnswerKey
        case insideAnswerString
        case finishedAnswer
        case plainTextMode
    }

    private var state: State = .seekingAnswerKey
    private var rawBuffer: String = ""
    private(set) var accumulatedAnswer: String = ""
    private var isEscaping: Bool = false
    private var unicodeEscapeBuffer: String = ""
    private var isCollectingUnicode: Bool = false

    init() {}

    static func chatSchema() -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "answer": [
                    "type": "string",
                    "description": "Clean Markdown answer grounded strictly in the transcript. No segment IDs, UUIDs, citation markers, or timestamps in the answer body."
                ],
                "referenceSegmentIDs": [
                    "type": "array",
                    "items": [
                        "type": "string"
                    ],
                    "description": "Array of transcript segment IDs that directly support the statements in your answer."
                ]
            ],
            "required": ["answer", "referenceSegmentIDs"],
            "additionalProperties": false
        ]
    }

    /// Appends a new delta chunk from the network stream and returns any newly parsed answer text delta.
    func append(chunk: String) -> String? {
        rawBuffer.append(chunk)

        switch state {
        case .seekingAnswerKey:
            // Check if this is plain text (does not start with '{' after trimming leading whitespace)
            let trimmed = rawBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.hasPrefix("{") {
                state = .plainTextMode
                accumulatedAnswer.append(rawBuffer)
                let text = rawBuffer
                rawBuffer = ""
                return text
            }

            // Look for "answer" : "
            if let range = rawBuffer.range(of: "\"answer\"") {
                let remainder = rawBuffer[range.upperBound...]
                // Look for the colon followed by opening quote
                if let quoteIndex = findOpeningQuote(in: remainder) {
                    state = .insideAnswerString
                    let textAfterQuote = String(remainder[remainder.index(after: quoteIndex)...])
                    return processAnswerCharacters(textAfterQuote)
                }
            }
            return nil

        case .insideAnswerString:
            return processAnswerCharacters(chunk)

        case .finishedAnswer:
            return nil

        case .plainTextMode:
            accumulatedAnswer.append(chunk)
            return chunk
        }
    }

    private func findOpeningQuote(in substring: Substring) -> Substring.Index? {
        var passedColon = false
        var index = substring.startIndex
        while index < substring.endIndex {
            let char = substring[index]
            if char == ":" && !passedColon {
                passedColon = true
            } else if passedColon {
                if char == "\"" {
                    return index
                } else if !char.isWhitespace {
                    // Unexpected token before quote
                    return nil
                }
            }
            index = substring.index(after: index)
        }
        return nil
    }

    private func processAnswerCharacters(_ string: String) -> String? {
        var output = ""

        for char in string {
            if isCollectingUnicode {
                unicodeEscapeBuffer.append(char)
                if unicodeEscapeBuffer.count == 4 {
                    if let codePoint = UInt32(unicodeEscapeBuffer, radix: 16),
                       let scalar = UnicodeScalar(codePoint) {
                        output.append(Character(scalar))
                    }
                    isCollectingUnicode = false
                    unicodeEscapeBuffer = ""
                }
                continue
            }

            if isEscaping {
                isEscaping = false
                switch char {
                case "\"": output.append("\"")
                case "\\": output.append("\\")
                case "/": output.append("/")
                case "n": output.append("\n")
                case "r": output.append("\r")
                case "t": output.append("\t")
                case "b": output.append("\u{0008}")
                case "f": output.append("\u{000C}")
                case "u":
                    isCollectingUnicode = true
                    unicodeEscapeBuffer = ""
                default:
                    output.append(char)
                }
                continue
            }

            if char == "\\" {
                isEscaping = true
                continue
            }

            if char == "\"" {
                // Closing quote for the answer string!
                state = .finishedAnswer
                break
            }

            output.append(char)
        }

        if !output.isEmpty {
            accumulatedAnswer.append(output)
            return output
        }
        return nil
    }

    /// Attempts to decode the complete DTO from the accumulated raw text or fallback text.
    func finish() -> OpenAIChatResponseDTO {
        if let data = rawBuffer.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(OpenAIChatResponseDTO.self, from: data) {
            return decoded
        }
        return OpenAIChatResponseDTO(answer: accumulatedAnswer, referenceSegmentIDs: [])
    }
}

// Compatibility name for existing transport and fixtures.
typealias OpenAIChatResponseDTO = StructuredChatResponse
