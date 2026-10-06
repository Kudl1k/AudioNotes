import Foundation

struct FormattedChatPrompt: Sendable {
    let systemInstructions: String
    let messages: [LLMChatMessage]
    var images: [LLMImageInput] = []

    init(systemInstructions: String, messages: [LLMChatMessage], images: [LLMImageInput] = []) {
        self.images = images
        self.systemInstructions = systemInstructions
        self.messages = messages
    }
}

struct ChatContextBuilder: Sendable {
    static let maxSupportedTokens = 100_000

    init() {}

    /// Formats the transcript segments into an authoritative, grounded XML-like structure.
    func formatTranscript(_ transcript: Transcript) throws -> String {
        try formatSegments(transcript.segmentSnapshots)
    }

    func formatSegments(_ segments: [TranscriptSegmentSnapshot]) throws -> String {
        guard !segments.isEmpty else {
            throw LLMError.transcriptEmpty
        }

        var lines: [String] = []
        lines.reserveCapacity(segments.count * 6)

        for segment in segments {
            let start = AudioTime.format(segment.startTime)
            let end = AudioTime.format(segment.endTime)
            lines.append("<segment id=\"\(segment.id.uuidString)\">")
            lines.append("start: \(start)")
            lines.append("end: \(end)")
            if let speaker = segment.speaker, !speaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("speaker: \(speaker)")
            }
            lines.append("text:")
            lines.append(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("</segment>")
            lines.append("")
        }

        let formatted = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !formatted.isEmpty else {
            throw LLMError.transcriptEmpty
        }

        let approximateTokens = max(1, formatted.count / 4)
        if approximateTokens > Self.maxSupportedTokens {
            throw LLMError.contextTooLarge(approximateTokens: approximateTokens)
        }

        return formatted
    }

    /// Builds the system instructions and messages payload for chat completion.
    func buildPrompt(
        context: ChatContext,
        history: [LLMChatMessage]
    ) throws -> FormattedChatPrompt {
        if let evidence = context.projectEvidence {
            return ProjectChatPrompt.prompt(evidence: evidence, history: history, settings: context.generationSettings ?? .init())
        }
        if context.sourceChunks != nil { return try RetrievedSourceContextBuilder().prompt(context: context, history: history) }
        let formattedTranscript = try formatSegments(context.retrievedSegments ?? context.transcript.segmentSnapshots)

        var systemLines: [String] = [
            "You are Soniquill Assistant, an intelligent conversational partner helping the user explore and understand this specific audio recording.",
            "",
            "CRITICAL GROUNDING RULES:",
            "1. Authoritative Source: Answer strictly using facts and information stated in the TRANSCRIPT below.",
            "2. No Hallucinations: Do not invent facts, speakers, decisions, dates, or timestamps.",
            "3. Insufficient Information: If the transcript does not contain enough information to answer a question, clearly and honestly state that the recording does not mention it.",
            "4. Distinguish Statements: Clearly distinguish between direct statements made by speakers and tentative interpretations or summaries.",
            "5. Speaker Names: Preserve exact speaker names as indicated in the transcript segments. Never fabricate speakers.",
            "6. Direct Audio: Never claim to have heard or listened to audio directly. You are reasoning solely over the provided transcript text.",
            "Answer body: Use clean Markdown: short paragraphs, headings for sections, numbered lists for procedures, bullets for collections, inline code for identifiers, and fenced blocks for multiline code.",
            "Do not include transcript segment IDs, UUIDs, citation tokens, or timestamps inside the answer Markdown. Return transcript references only through the structured referenceSegmentIDs field.",
            "7. References: When making factual statements, cite the relevant segment IDs using the structured output reference IDs array. Never fabricate segment IDs.",
            "",
            "<recording_metadata>",
            "RECORDING TITLE: \"\(context.recordingTitle)\"",
            "</recording_metadata>",
            ""
        ]

        if let summary = context.summary {
            var summaryParts: [String] = []
            if !summary.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                summaryParts.append(summary.overview.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if !summary.keyPoints.isEmpty {
                summaryParts.append("Key Points:\n" + summary.keyPoints.map { "- \($0.text)" }.joined(separator: "\n"))
            }
            if !summaryParts.isEmpty {
                systemLines.append("<summary>")
                systemLines.append("DERIVATIVE SUMMARY (Supplementary background only; TRANSCRIPT is the primary authority):")
                systemLines.append(summaryParts.joined(separator: "\n\n"))
                systemLines.append("</summary>")
                systemLines.append("")
            }
        }

        systemLines.append("<transcript>")
        systemLines.append(context.retrievalUsed
            ? "RETRIEVED AUTHORITATIVE TRANSCRIPT SEGMENTS (selected by local lexical search; these may not cover the entire recording):"
            : "AUTHORITATIVE TRANSCRIPT:")
        systemLines.append(formattedTranscript)
        systemLines.append("</transcript>")
        systemLines.append("")
        systemLines.append("RESPONSE LENGTH: \(OutputLengthInstructionBuilder.instruction(for: context.generationSettings?.outputLength ?? .medium))")

        let systemInstructions = systemLines.joined(separator: "\n")

        // Include conversation history
        return FormattedChatPrompt(
            systemInstructions: systemInstructions,
            messages: history
        )
    }
}
