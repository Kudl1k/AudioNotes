import Foundation

public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case markdown = "Markdown (.md)"
    case pdf = "PDF Document (.pdf)"

    public var id: String { rawValue }
    public var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .pdf: return "pdf"
        }
    }
    public var uti: String {
        switch self {
        case .markdown: return "net.daringfireball.markdown"
        case .pdf: return "com.adobe.pdf"
        }
    }
}

public struct ExportOptions: Sendable {
    public var format: ExportFormat
    public var includeSources: Bool = true
    public var includeAIGenerationMetadata: Bool = false
    public var includeMetadata: Bool
    public var includeSummary: Bool
    public var includeTranscript: Bool
    public var includeChat: Bool
    public var includeTimestamps: Bool
    public var includeSpeakers: Bool
    public var markdownFrontMatter: Bool

    public init(
        format: ExportFormat = .markdown,
        includeMetadata: Bool = true,
        includeSummary: Bool = true,
        includeTranscript: Bool = true,
        includeChat: Bool = false,
        includeTimestamps: Bool = true,
        includeSpeakers: Bool = true,
        markdownFrontMatter: Bool = false
    ) {
        self.format = format
        self.includeMetadata = includeMetadata
        self.includeSummary = includeSummary
        self.includeTranscript = includeTranscript
        self.includeChat = includeChat
        self.includeTimestamps = includeTimestamps
        self.includeSpeakers = includeSpeakers
        self.markdownFrontMatter = markdownFrontMatter
    }
}

public struct ExportTranscriptSegment: Sendable {
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let speaker: String?
    public let text: String

    public init(startTime: TimeInterval, endTime: TimeInterval, speaker: String?, text: String) {
        self.startTime = startTime
        self.endTime = endTime
        self.speaker = speaker
        self.text = text
    }
}

public struct ExportTranscript: Sendable {
    public let segments: [ExportTranscriptSegment]

    public init(segments: [ExportTranscriptSegment]) {
        self.segments = segments
    }
}

public struct ExportSummaryActionItem: Sendable {
    public let text: String
    public let assignee: String?
    public let dueDate: String?
    public let timestamp: TimeInterval?

    public init(text: String, assignee: String? = nil, dueDate: String? = nil, timestamp: TimeInterval? = nil) {
        self.text = text
        self.assignee = assignee
        self.dueDate = dueDate
        self.timestamp = timestamp
    }
}

public struct ExportSummaryDecision: Sendable {
    public let text: String
    public let timestamp: TimeInterval?

    public init(text: String, timestamp: TimeInterval? = nil) {
        self.text = text
        self.timestamp = timestamp
    }
}

public struct ExportSummaryQuote: Sendable {
    public let text: String
    public let speaker: String?
    public let timestamp: TimeInterval?

    public init(text: String, speaker: String? = nil, timestamp: TimeInterval? = nil) {
        self.text = text
        self.speaker = speaker
        self.timestamp = timestamp
    }
}

public struct ExportSummary: Sendable {
    public var title: String = ""
    public var sourceLabels: [String] = []
    public let presetTitle: String
    public let overview: String
    public let keyPoints: [String]
    public let decisions: [ExportSummaryDecision]
    public let actionItems: [ExportSummaryActionItem]
    public let openQuestions: [String]
    public let importantQuotes: [ExportSummaryQuote]
    public let additionalSections: [(title: String, items: [String])]

    public init(
        presetTitle: String,
        overview: String,
        keyPoints: [String],
        decisions: [ExportSummaryDecision],
        actionItems: [ExportSummaryActionItem],
        openQuestions: [String],
        importantQuotes: [ExportSummaryQuote],
        additionalSections: [(title: String, items: [String])] = []
    ) {
        self.presetTitle = presetTitle
        self.overview = overview
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.importantQuotes = importantQuotes
        self.additionalSections = additionalSections
    }
}

public struct ExportChatMessage: Sendable {
    public var sourceLabels: [String] = []
    public let role: String
    public let text: String
    public let timestamps: [TimeInterval]
    public let sentAt: Date

    public init(role: String, text: String, timestamps: [TimeInterval] = [], sentAt: Date = Date()) {
        self.role = role
        self.text = text
        self.timestamps = timestamps
        self.sentAt = sentAt
    }
}

public struct ExportContent: Sendable {
    public var sourceNames: [String] = []
    public let title: String
    public let originalFileName: String
    public let duration: TimeInterval
    public let recordedAt: Date
    public let transcript: ExportTranscript?
    public let summary: ExportSummary?
    public var aiGenerationMetadata: [String] = []
    public let chat: [ExportChatMessage]

    public init(
        title: String,
        originalFileName: String,
        duration: TimeInterval,
        recordedAt: Date,
        transcript: ExportTranscript? = nil,
        summary: ExportSummary? = nil,
        chat: [ExportChatMessage] = []
    ) {
        self.title = title
        self.originalFileName = originalFileName
        self.duration = duration
        self.recordedAt = recordedAt
        self.transcript = transcript
        self.summary = summary
        self.chat = chat
    }
}
