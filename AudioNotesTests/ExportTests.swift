import Foundation
import PDFKit
import Testing
@testable import AudioNotes

struct ExportTests {

    private func makeSampleContent() -> ExportContent {
        let segments = [
            ExportTranscriptSegment(startTime: 0, endTime: 5.5, speaker: "Alice", text: "Welcome to the planning meeting."),
            ExportTranscriptSegment(startTime: 6.0, endTime: 12.0, speaker: "Bob", text: "Thanks Alice. Let's review the timeline.")
        ]
        let transcript = ExportTranscript(segments: segments)

        var summary = ExportSummary(
            presetTitle: "Meeting",
            overview: "A productive team kickoff.",
            keyPoints: ["Project starts Monday", "Design specs are finalized"],
            decisions: [ExportSummaryDecision(text: "Approved SwiftUI for macOS", timestamp: 8.5)],
            actionItems: [ExportSummaryActionItem(text: "Deploy staging server", assignee: "Charlie", dueDate: "Friday", timestamp: 10.0)],
            openQuestions: ["What about localized strings?"],
            importantQuotes: [ExportSummaryQuote(text: "SwiftUI gives us great velocity.", speaker: "Bob", timestamp: 9.0)]
        )
        summary.title = "Project Timeline and SwiftUI Approval"

        let chat = [
            ExportChatMessage(role: "User", text: "What did we approve?"),
            ExportChatMessage(role: "Assistant", text: "You approved SwiftUI for macOS.", timestamps: [8.5])
        ]

        return ExportContent(
            title: "Sprint Kickoff",
            originalFileName: "meeting.m4a",
            duration: 12.0,
            recordedAt: Date(timeIntervalSince1970: 1713000000),
            transcript: transcript,
            summary: summary,
            chat: chat
        )
    }

    @Test func markdownExportContainsExpectedSections() {
        let content = makeSampleContent()
        let exporter = MarkdownExporter()
        let options = ExportOptions(
            format: .markdown,
            includeMetadata: true,
            includeSummary: true,
            includeTranscript: true,
            includeChat: true,
            includeTimestamps: true,
            includeSpeakers: true,
            markdownFrontMatter: false
        )

        let output = exporter.export(content: content, options: options)

        #expect(output.contains("# Sprint Kickoff"))
        #expect(output.contains("Original File:** meeting.m4a"))
        #expect(output.contains("## Summary (Meeting)"))
        #expect(output.contains("### Project Timeline and SwiftUI Approval"))
        #expect(output.contains("### Overview"))
        #expect(output.contains("A productive team kickoff."))
        #expect(output.contains("- Project starts Monday"))
        #expect(output.contains("Approved SwiftUI for macOS"))
        #expect(output.contains("- [ ] Deploy staging server (Assignee: Charlie, Due: Friday)"))
        #expect(output.contains("## Transcript"))
        #expect(output.contains("**Alice:** Welcome to the planning meeting."))
        #expect(output.contains("## Chat History"))
        #expect(output.contains("You approved SwiftUI for macOS."))
    }

    @Test func markdownExportWithFrontMatter() {
        let content = makeSampleContent()
        let exporter = MarkdownExporter()
        let options = ExportOptions(
            format: .markdown,
            includeMetadata: false,
            includeSummary: true,
            includeTranscript: false,
            markdownFrontMatter: true
        )

        let output = exporter.export(content: content, options: options)

        #expect(output.hasPrefix("---\n"))
        #expect(output.contains("title: \"Sprint Kickoff\""))
        #expect(output.contains("original_file: \"meeting.m4a\""))
        #expect(output.contains("---"))
        #expect(!output.contains("## Transcript"))
    }

    @Test func markdownExportRespectsExclusions() {
        let content = makeSampleContent()
        let exporter = MarkdownExporter()
        let options = ExportOptions(
            format: .markdown,
            includeMetadata: false,
            includeSummary: false,
            includeTranscript: true,
            includeChat: false,
            includeTimestamps: false,
            includeSpeakers: false
        )

        let output = exporter.export(content: content, options: options)

        #expect(!output.contains("## Summary"))
        #expect(!output.contains("Project Timeline and SwiftUI Approval"))
        #expect(!output.contains("## Chat History"))
        #expect(!output.contains("**Alice:**"))
        #expect(output.contains("Welcome to the planning meeting."))
    }

    @Test func pdfExportProducesValidPDFData() {
        let content = makeSampleContent()
        let exporter = PDFExporter()
        let options = ExportOptions(format: .pdf)

        let pdfData = exporter.export(content: content, options: options)

        #expect(!pdfData.isEmpty)
        // PDF magic byte signature "%PDF"
        let magicString = String(decoding: pdfData.prefix(4), as: UTF8.self)
        #expect(magicString == "%PDF")
        #expect(PDFDocument(data: pdfData)?.string?.contains("Project Timeline and SwiftUI Approval") == true)
    }

    @Test func pdfExportHandlesUnicodeAndEmojis() {
        let segments = [
            ExportTranscriptSegment(startTime: 0, endTime: 5, speaker: "Petr", text: "Dobrý den, jak se daří? 🎉 Příliš žluťoučký kůň úpěl ďábelské ódy.")
        ]
        let transcript = ExportTranscript(segments: segments)
        let content = ExportContent(
            title: "Čeština & Emojis 🚀",
            originalFileName: "audio.m4a",
            duration: 5,
            recordedAt: Date(),
            transcript: transcript
        )

        let exporter = PDFExporter()
        let options = ExportOptions(format: .pdf)
        let pdfData = exporter.export(content: content, options: options)

        #expect(!pdfData.isEmpty)
        let magicString = String(decoding: pdfData.prefix(4), as: UTF8.self)
        #expect(magicString == "%PDF")
    }
}
