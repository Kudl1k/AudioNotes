import Foundation
import SwiftData
import Testing
@testable import AudioNotes

struct ChatRenderingTests {
    private let id = UUID(uuidString: "220467DC-8F29-48FE-B50B-4D7BD85A14F4")!

    private var czechFixture: String {
        """
        ## Postup vytvoření kernelového modulu

        V nahrávce je postup popsán obecně takto:
        1. Napište kernelový modul v C.
           Kernel i běžné ovladače jsou psané v C. Použijte `module_init`.

           ```c
           module_init(hello_init);
           module_exit(hello_exit);
           ```
        2. Zaregistrujte zařízení.
           - `major` — typ zařízení
           - `minor` — konkrétní instance

        Pro přenos použijte **bezpečné** kopírování a *uvolněte prostředky*.
        【\(id.uuidString)】【1803656E-56FE-482F-BC60-1581FCE0224B】【53?】 4:5651:46
        """
    }

    @Test func exactCzechRegression() {
        let reference = TranscriptReference(segmentID: id, startTime: 296)
        let response = LLMChatResponse(content: czechFixture, references: [reference])
        #expect(!response.content.contains("【"))
        #expect(!response.content.contains(id.uuidString))
        #expect(!response.content.contains("4:5651:46"))
        #expect(response.content.contains("běžné ovladače"))
        let document = MarkdownDocument(response.content)
        #expect(document.blocks.count == 4)
        guard case .list(let items) = document.blocks[2] else { Issue.record("Missing ordered list"); return }
        #expect(items.map(\.marker) == ["1.", "2."])
        #expect(items[0].blocks.contains(.code(language: "c", text: "module_init(hello_init);\nmodule_exit(hello_exit);")))
        guard case .list(let bullets) = items[1].blocks.last else { Issue.record("Missing nested bullets"); return }
        #expect(bullets.count == 2)
        #expect(response.references[0].startTime == 296)
    }

    @Test(arguments: ["Plain paragraph", "**bold** and *italic*", "`copy_from_user`", "Čeština žluťoučký kůň", "**Kernel mod", "[unfinished", "<b>literal HTML</b>"])
    func paragraphsAndIncompleteInlineContentRemainVisible(_ text: String) {
        #expect(MarkdownDocument(text).blocks == [.paragraph(text)])
    }

    @Test func inlineFormattingPreservesIntentAndUnicode() {
        let value = MarkdownDocument.inline("**Důležité** *poznámky* `module_init`")
        #expect(String(value.characters) == "Důležité poznámky module_init")
        #expect(value.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(value.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
        #expect(value.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        #expect(!String(MarkdownDocument.inline("**Kernel mod").characters).isEmpty)
    }

    @Test func semanticBlocks() {
        #expect(MarkdownDocument("First\n\nSecond").blocks == [.paragraph("First"), .paragraph("Second")])
        #expect(MarkdownDocument("# Heading\n\n> Quote\n> continuation\n\n---").blocks == [.heading(1, "Heading"), .quote([.paragraph("Quote\ncontinuation")]), .separator])
        guard case .list(let items) = MarkdownDocument("- read\n  - nested\n- write").blocks.first else { Issue.record("Missing list"); return }
        #expect(items.count == 2)
        #expect(items[0].blocks.count == 2)
    }

    @Test func streamingMarkdown() {
        var markdown = ""
        for chunk in ["## Post", "up\n\n1. Napište ", "`kernelový", " modul`...", "\n\n```c\nmodule_", "init(...);", "\n```"] {
            markdown += chunk
            #expect(!MarkdownDocument(markdown).blocks.isEmpty)
        }
        #expect(MarkdownDocument(markdown).blocks.last == .code(language: "c", text: "module_init(...);"))
        #expect(MarkdownDocument("```c\nint hel").blocks == [.code(language: "c", text: "int hel")])
        #expect(ChatContentNormalizer.clean("Answer 【220467DC-", streaming: true) == "Answer")
    }

    @Test func conservativeLegacyCleaning() {
        let text = "[normal brackets] `int array[4]` 【literary quotation】 user UUID 12345678-1234-1234-1234-123456789012"
        #expect(ChatContentNormalizer.clean(text) == text)
        #expect(ChatContentNormalizer.clean("Answer [segment_id=bad] 【53?】 【malformed-reference】") == "Answer")
    }

    @Test func cleaningLargeTranscriptRemovesOnlyAuthoritativeIDs() {
        let ids = (0..<10_000).map { _ in UUID() }
        let ordinaryID = UUID()
        let text = "Čeština [ordinary] \(ids[0].uuidString.lowercased()) middle \(ids[9999]) end \(ordinaryID)"
        #expect(ChatContentNormalizer.clean(text, internalSegmentIDs: ids)
            == "Čeština [ordinary]  middle  end \(ordinaryID)")
    }

    @Test func validatesReferencesAndGroupsWithoutLosingSources() {
        let next = UUID()
        let segments = [
            TranscriptSegmentSnapshot(id: id, startTime: 296, endTime: 300, speaker: nil, text: "First"),
            TranscriptSegmentSnapshot(id: next, startTime: 300, endTime: 305, speaker: nil, text: "Next")
        ]
        let refs = TranscriptReferenceResolver().resolve(segmentIDs: [next.uuidString, id.uuidString, id.uuidString, "invalid", UUID().uuidString], against: segments)
        #expect(refs.map(\.segmentID) == [id, next])
        let groups = ChatSourcePresentation.groups(refs + refs)
        #expect(groups.count == 1)
        #expect(groups[0].references.count == 2)
        let forged = LLMChatResponse(content: "Use `read` 【\(id)】", references: [TranscriptReference(segmentID: id, startTime: 999), TranscriptReference(segmentID: UUID(), startTime: 1)])
        let clean = ChatContentNormalizer.validated(forged, against: segments)
        #expect(clean.references.count == 1)
        #expect(clean.references[0].startTime == 296)
        #expect(clean.content == "Use `read`")
    }

    @Test(arguments: [(0.0, "00:00"), (296.0, "04:56"), (3106.0, "51:46"), (3872.0, "1:04:32")])
    func canonicalTimestamps(_ seconds: Double, _ expected: String) {
        #expect(TimestampFormatter.string(seconds) == expected)
        #expect(AudioTime.format(seconds) == expected)
    }

    @MainActor @Test func persistenceReloadKeepsCleanMarkdownAndStructuredReferences() throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = container.mainContext
        let recording = Recording(title: "Lecture", audioFileName: "audio.m4a", originalFileName: "audio.m4a", duration: 600)
        let transcript = Transcript()
        transcript.segments = [TranscriptSegment(id: id, position: 0, startTime: 296, endTime: 300, text: "Kernel")]
        recording.transcript = transcript
        context.insert(recording)
        let repository = SwiftDataChatRepository(context: context)
        let session = try repository.ensureSession(for: recording)
        let response = LLMChatResponse(content: czechFixture, references: [TranscriptReference(segmentID: id, startTime: 296)])
        try repository.appendMessage(ChatMessage(role: .assistant, text: response.content, references: response.references), to: session)
        let reloaded = try ModelContext(container).fetch(FetchDescriptor<ChatMessage>())
        #expect(reloaded.count == 1)
        #expect(reloaded[0].text == response.content)
        #expect(reloaded[0].references.map(\.segmentID) == response.references.map(\.segmentID))
        #expect(reloaded[0].references[0].startTime == 296)
        let legacy = ChatMessage(role: .assistant, text: czechFixture)
        #expect(!ChatContentNormalizer.clean(legacy.text).contains("【"))
        #expect(legacy.text == czechFixture) // No destructive migration.
    }
}
