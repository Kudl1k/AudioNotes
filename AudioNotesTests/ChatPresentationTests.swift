import AppKit
import SwiftUI
import SwiftData
import Testing
@testable import AudioNotes

@Suite(.serialized)
@MainActor
struct ChatPresentationTests {
    @Test func returnValidatesContentAndLeavesModifiedKeysNative() {
        let editor = ChatInputTextView(frame: .zero)
        var sends = 0
        editor.onSend = { sends += 1 }
        editor.canSend = true
        for text in ["", "   ", "\n \n"] {
            editor.string = text
            #expect(editor.handleReturn(modifiers: []))
        }
        #expect(sends == 0)
        editor.string = "  hello\nworld  "
        #expect(editor.handleReturn(modifiers: []))
        #expect(sends == 1 && editor.string == "  hello\nworld  ")
        #expect(editor.handleReturn(modifiers: [], isRepeat: true))
        for modifier: NSEvent.ModifierFlags in [.shift, .option, .command, .control] {
            #expect(!editor.handleReturn(modifiers: modifier))
        }
        editor.canSend = false
        #expect(editor.handleReturn(modifiers: []))
        #expect(sends == 1)
    }

    @Test func nativeNewlineReplacesSelectionAtCursor() {
        let editor = ChatInputTextView(frame: .zero)
        editor.allowsUndo = true
        editor.string = "hello world"
        editor.setSelectedRange(NSRange(location: 9, length: 0))
        #expect(!editor.handleReturn(modifiers: .shift))
        editor.insertNewline(nil)
        #expect(editor.string == "hello wor\nld")
        #expect(editor.selectedRange() == NSRange(location: 10, length: 0))
        editor.setSelectedRange(NSRange(location: 6, length: 3))
        editor.insertNewline(nil)
        #expect(editor.string == "hello \n\nld")
        #expect(editor.selectedRange() == NSRange(location: 7, length: 0))
    }

    @Test func markedTextReturnDoesNotSend() {
        let editor = ChatInputTextView(frame: .zero)
        editor.canSend = true
        var sent = false
        editor.onSend = { sent = true }
        var markedStates: [Bool] = []
        editor.onCompositionChange = { markedStates.append($0) }
        editor.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        #expect(!editor.handleReturn(modifiers: []))
        #expect(!sent)
        editor.unmarkText()
        #expect(markedStates.first == true && markedStates.last == false)
        #expect(editor.handleReturn(modifiers: []))
        #expect(sent)
    }

    @Test func escapeCancelsWorkAndPreservesMarkedTextHandling() {
        let editor = ChatInputTextView(frame: .zero)
        var cancels = 0
        var sends = 0
        editor.onCancel = { cancels += 1 }
        editor.onSend = { sends += 1 }
        editor.cancelOperation(nil)
        #expect(cancels == 1 && sends == 0)
        editor.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.cancelOperation(nil)
        #expect(cancels == 1 && sends == 0)
    }

    @Test func editorHeightIsBoundedForLongPasteAndAdaptsToWidth() {
        let scroll = ChatEditorScrollView()
        let editor = ChatInputTextView(frame: .zero)
        editor.font = .systemFont(ofSize: 13)
        editor.textContainerInset = NSSize(width: 5, height: 6)
        scroll.documentView = editor
        #expect(scroll.editorHeight(width: 300) >= ChatEditorScrollView.minimumHeight)
        editor.string = String(repeating: "Long prompt words ", count: 600)
        let displayedContainerSize = editor.textContainer?.containerSize
        let clock = ContinuousClock(), start = clock.now
        #expect(editor.string.count > 10_000)
        #expect(scroll.editorHeight(width: 300) == ChatEditorScrollView.maximumHeight)
        #expect(editor.textContainer?.containerSize == displayedContainerSize)
        print("M14.2 10K composer layout: \(start.duration(to: clock.now))")
        editor.string = "One line\nTwo lines\nThree lines"
        #expect(scroll.editorHeight(width: 300) > ChatEditorScrollView.minimumHeight)
        #expect(scroll.editorHeight(width: 300) < ChatEditorScrollView.maximumHeight)
        editor.string = String(repeating: "wrapped words ", count: 8)
        #expect(scroll.editorHeight(width: 180) >= scroll.editorHeight(width: 700))
    }

    @Test func presentationDoesNotChangeIdentityWithMessageContent() {
        let message = ChatMessage(role: .assistant, text: "First")
        let initial = ChatMessagePresentation(message)
        message.text += " chunk"
        #expect(ChatMessagePresentation(message) == initial)
        message.status = .interrupted
        #expect(ChatMessagePresentation(message).id == initial.id)
        #expect(ChatMessagePresentation(message).interrupted)
    }

    @Test func activeScrollGestureSuppressesFollowingBeforeGeometryArrives() {
        var state = ChatScrollState()
        state.userScrolling(true)
        #expect(!({ state.contentArrived() })())
        state.positionChanged(nearBottom: false)
        #expect(!({ state.contentArrived() })() && state.hasUnseenContent)
        state.userScrolling(false)
        #expect(!({ state.contentArrived() })())
        state.jumpToLatest()
        #expect(({ state.contentArrived() })() && !state.hasUnseenContent)
        state.positionChanged(nearBottom: false) // response growth, not a gesture
        #expect(({ state.contentArrived() })())
        state.userScrolling(true)
        state.positionChanged(nearBottom: true)
        state.userScrolling(false)
        #expect(({ state.contentArrived() })())
    }

    @Test func wheelMovementPausesFollowingButGrowthAndResizeDoNot() {
        let initial = ChatScrollGeometry(offset: 500, contentHeight: 1000, viewportHeight: 500)
        let upward = ChatScrollGeometry(offset: 300, contentHeight: 1000, viewportHeight: 500)
        #expect(upward.movedByUser(from: initial, isPositionedByUser: true))
        #expect(!upward.movedByUser(from: initial, isPositionedByUser: false))
        let growth = ChatScrollGeometry(offset: 500, contentHeight: 1300, viewportHeight: 500)
        #expect(!growth.movedByUser(from: initial, isPositionedByUser: true))
        let resize = ChatScrollGeometry(offset: 300, contentHeight: 1000, viewportHeight: 700)
        #expect(!resize.movedByUser(from: initial, isPositionedByUser: true))
        var state = ChatScrollState()
        state.positionChanged(nearBottom: upward.nearBottom, userInitiated: true)
        let follows = state.contentArrived()
        #expect(!follows && state.hasUnseenContent)
    }

    @Test func isolatedStressHistoriesAreIdempotentAndCreateNoGenerationRecords() throws {
        let container = try LibraryStorage().makeContainer(inMemory: true)
        let context = container.mainContext
        let project = Project(name: "Synthetic")
        let recording = try PerformanceFixtures.recording(.small)
        recording.project = project
        context.insert(project)
        context.insert(recording)
        try ChatPresentationFixtures.prepare(context: context)
        try ChatPresentationFixtures.prepare(context: context)
        #expect(recording.chatSessions.first?.messages.count == 500)
        #expect(project.chatSessions.first?.messages.count == 500)
        #expect(recording.chatSessions.first?.orderedMessages.last?.role == .assistant)
        let session = try #require(project.chatSessions.first)
        try SwiftDataChatRepository(context: context).appendMessage(ChatMessage(role: .user, text: "Additional fixture question"), to: session)
        try ChatPresentationFixtures.prepare(context: context)
        #expect(session.messages.count == 501)
        #expect(try context.fetchCount(FetchDescriptor<GenerationRecord>()) == 0)
    }

    @Test func hundredAndFiveHundredMessagePresentationAndMarkdownBaseline() async throws {
        for count in [100, 500] {
            let messages = (0..<count).map { index in
                ChatMessage(id: PerformanceFixtures.id("shared-chat-\(count)-\(index)"), role: index.isMultiple(of: 2) ? .user : .assistant,
                    text: index.isMultiple(of: 2) ? "Explain lifecycle \(index)" : PerformanceFixtures.markdown,
                    createdAt: PerformanceFixtures.epoch.addingTimeInterval(Double(index)))
            }
            let clock = ContinuousClock(), start = clock.now
            let rows = messages.map(ChatMessagePresentation.init)
            #expect(Set(rows.map(\.id)).count == count)
            print("M14.2 \(count) message presentation snapshots: \(start.duration(to: clock.now))")
            let texts = messages.filter { $0.role == .assistant }.map(\.text)
            let parseStart = clock.now
            let blockCount = await Task.detached {
                texts.reduce(0) { $0 + MarkdownDocument($1).blocks.count }
            }.value
            #expect(blockCount > count)
            print("M14.2 \(count) message Markdown preparation: \(parseStart.duration(to: clock.now))")
        }
    }
}
