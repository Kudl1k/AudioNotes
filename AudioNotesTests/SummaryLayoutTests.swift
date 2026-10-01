import AppKit
import SwiftData
import SwiftUI
import Testing
@testable import AudioNotes

/// Exercises AppKit constraint passes, rather than checking SwiftUI view structure.
@Suite(.serialized)
@MainActor
struct SummaryLayoutTests {
    private final class LocalProvider: LLMProvider {
        let id: LLMProviderID = .llamaCpp
        let displayName = "llama.cpp Server"
        let modelID: String? = String(repeating: "long-local-model-name-", count: 12) + ".gguf"
        let executionLocation: ProviderExecutionLocation = .local
        let billingKind: BillingKind = .local

        func generateSummary(transcript: Transcript, configuration: SummaryConfiguration) async throws -> Summary {
            Issue.record("Layout must not execute a provider")
            throw CancellationError()
        }

        func streamChat(messages: [LLMChatMessage], context: ChatContext) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
            Issue.record("Layout must not execute a provider")
            throw CancellationError()
        }
    }

    private struct LocalResolver: LLMProviderResolving {
        let provider: LocalProvider
        func resolve() -> any LLMProvider { provider }
        func summaryModels(for provider: LLMProviderID) -> [GenerationModelOption] {
            [.init(id: self.provider.modelID!, title: self.provider.modelID!)]
        }
    }

    @Test func singleLocalModelFitsShortAndNarrowSummaryPane() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let recording = Recording(title: "Local summary", audioFileName: "", originalFileName: "", duration: 10)
        recording.transcript = Transcript()
        recording.transcript?.segments = [TranscriptSegment(position: 0, startTime: 0, endTime: 10, text: "Offline fixture content")]
        container.mainContext.insert(recording)
        let provider = LocalProvider()
        let model = SummaryViewModel(recording: recording, resolver: LocalResolver(provider: provider))
        let host = NSHostingView(rootView: TabView {
            Tab("Summary", systemImage: "doc.text") {
                SummaryView(recording: recording, model: model, onSeek: { _ in })
            }
        }.modelContainer(container))
        // An offscreen native window still participates in AppKit constraint/layout passes.
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 550, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        for preset in [SummaryPreset.general, .custom] {
            model.selectBuiltInPreset(preset)
            model.selectedProvider = .llamaCpp
            model.selectedModel = provider.modelID
            for size in [NSSize(width: 550, height: 500), NSSize(width: 280, height: 240), NSSize(width: 400, height: 320)] {
                window.setContentSize(size)
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(80))
                window.layoutIfNeeded()
                assertValidFrames(host)
            }
        }
        #expect(model.availableModels.count == 1)
        #expect(model.selectedModelName == provider.modelID)
        #expect(model.canGenerate)
    }

    private func assertValidFrames(_ view: NSView) {
        #expect(view.frame.width.isFinite && view.frame.width >= 0)
        #expect(view.frame.height.isFinite && view.frame.height >= 0)
        for subview in view.subviews { assertValidFrames(subview) }
    }
}
