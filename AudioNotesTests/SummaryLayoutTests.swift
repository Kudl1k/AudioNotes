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

    private struct LongModelTranscriptionResolver: TranscriptionProviderResolving {
        let models: [GenerationModelOption]
        func resolve() -> any TranscriptionProvider { MockTranscriptionProvider() }
        func models(for provider: TranscriptionProviderID) -> [GenerationModelOption] { models }
    }

    @Test func transcriptionOptionsFormKeepsEqualPickerWidthsAndTruncatesLongNames() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let recording = Recording(title: "Sample", audioFileName: "sample.m4a", originalFileName: "sample.m4a", duration: 120)
        container.mainContext.insert(recording)

        let shortResolver = LongModelTranscriptionResolver(models: [.init(id: "tiny", title: "Tiny")])
        let shortModel = RecordingViewModel(recording: recording, resolver: shortResolver, storage: workspace.storage)
        let longName = String(repeating: "very-long-whisper-model-variant-", count: 8) + ".bin"
        let longResolver = LongModelTranscriptionResolver(models: [.init(id: longName, title: longName)])
        let longModel = RecordingViewModel(recording: recording, resolver: longResolver, storage: workspace.storage)
        longModel.selectedProvider = .localWhisper
        longModel.selectedModel = longName

        for viewModel in [shortModel, longModel] {
            let root = VStack(alignment: .leading, spacing: 12) {
                Text("Transcription Options").font(.headline)
                TranscriptionOptionsForm(model: viewModel)
            }
            .padding(16)
            .frame(width: 420)
            .modelContainer(container)

            let host = NSHostingView(rootView: root)
            let fitting = host.fittingSize
            #expect(abs(fitting.width - 420) <= 1, "Expected fixed 420 width, got \(fitting.width)")
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 420, height: max(180, fitting.height)),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }

            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            window.layoutIfNeeded()
            assertValidFrames(host)
            #expect(host.frame.width == 420)
        }
    }

    @Test func recordingDetailUsesSegmentedPickerWithoutTabViewBox() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let recording = try await workspace.makeRecording(in: container.mainContext)

        let host = NSHostingView(
            rootView: RecordingDetailView(recording: recording, resolver: FixedTranscriptionProviderResolver(provider: MockTranscriptionProvider()), storage: workspace.storage)
                .modelContainer(container)
        )
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 720, height: 560),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        for size in [NSSize(width: 720, height: 560), NSSize(width: 420, height: 300)] {
            window.setContentSize(size)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            window.layoutIfNeeded()
            assertValidFrames(host)
        }
        #expect(findSubviews(of: NSTabView.self, in: host).isEmpty)
        #expect(!findSubviews(of: NSSegmentedControl.self, in: host).isEmpty)
    }

    private final class BlockingTranscriptionProvider: TranscriptionProvider {
        let providerID: String? = TranscriptionProviderID.openAI.rawValue
        let modelID: String? = "whisper-1"
        let displayName = "OpenAI · whisper-1"
        let executionLocation: ProviderExecutionLocation = .cloud

        func transcribe(audioURL: URL, progress: @escaping TranscriptionProgress) async throws -> Transcript {
            try await transcribe(audioURL: audioURL, progress: progress, status: { _ in })
        }

        func transcribe(audioURL: URL, progress: @escaping TranscriptionProgress, status: @escaping TranscriptionStatusReporter) async throws -> Transcript {
            status(.init(phase: .transcribing, currentPart: 1, totalParts: 9, completedParts: 0, processedAudioDuration: 0, totalAudioDuration: 5178))
            try await Task.sleep(for: .seconds(30))
            throw CancellationError()
        }
    }

    @Test func transcriptionControlsDeduplicateModelAndExpandOnLabelClick() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let recording = try await workspace.makeRecording(in: container.mainContext)
        recording.duration = 5178
        let provider = BlockingTranscriptionProvider()
        let model = RecordingViewModel(recording: recording, provider: provider, storage: workspace.storage)
        #expect(model.transcriptionConfiguration == "OpenAI · whisper-1 · Cloud")

        let task = model.startTranscription(using: SwiftDataTranscriptRepository(context: container.mainContext))
        defer {
            model.cancelTranscription()
            task?.cancel()
        }
        try await Task.sleep(for: .milliseconds(80))
        #expect(model.state.isProcessing)

        let host = NSHostingView(
            rootView: TranscriptionControls(model: model, transcribe: {})
                .padding(16)
                .frame(width: 720)
                .environment(\.colorScheme, .dark)
                .modelContainer(container)
        )
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 720, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.alphaValue = 0
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }

        let collapsedHeight = host.fittingSize.height
        window.setContentSize(NSSize(width: 720, height: collapsedHeight))
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        window.layoutIfNeeded()

        // Click directly on the "Transcription Steps" text (x = 110, y = 28 from bottom in AppKit coords)
        sendClick(in: window, at: NSPoint(x: 110, y: 28))
        try await Task.sleep(for: .milliseconds(260))
        let expandedHeight = host.fittingSize.height
        window.setContentSize(NSSize(width: 720, height: expandedHeight))
        window.layoutIfNeeded()
        assertValidFrames(host)

        #expect(expandedHeight > collapsedHeight + 80,
                "Clicking 'Transcription Steps' text should expand steps (collapsed: \(collapsedHeight), expanded: \(expandedHeight))")
    }

    private func sendClick(in window: NSWindow, at point: NSPoint) {
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                            context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime + 0.01, windowNumber: window.windowNumber,
                                          context: nil, eventNumber: 2, clickCount: 1, pressure: 0) else { return }
        window.sendEvent(down)
        window.sendEvent(up)
    }

    @Test func sidebarRecordingRowFormatsProjectDateDurationAndCompactCost() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = container.mainContext

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 17, minute: 45)))
        let todayMorning = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 10, minute: 50)))
        let yesterdayMorning = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 10, minute: 50)))
        let olderDate = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 10, minute: 50)))

        #expect(RecordingRowPresentation.importedDateText(todayMorning, now: now, calendar: calendar).hasPrefix("Today, "))
        #expect(RecordingRowPresentation.importedDateText(yesterdayMorning, now: now, calendar: calendar).hasPrefix("Yesterday, "))
        #expect(RecordingRowPresentation.importedDateText(olderDate, now: now, calendar: calendar).contains("2026"))

        var mixedUsage = UsageTotals(operationCount: 2, completedResponses: 2, knownAPIAmount: Decimal(string: "0.12")!,
                                     unavailableRequests: 1, meteredRequests: 2)
        #expect(mixedUsage.compactDisplayText == MoneyFormatter.string(Money(amount: Decimal(string: "0.12")!)))
        #expect(UsageTotals().compactDisplayText == nil)
        mixedUsage.meteredRequests = 0
        mixedUsage.localRequests = 1
        #expect(mixedUsage.compactDisplayText == "Local")

        let project = Project(name: "Lectures")
        context.insert(project)

        let activeRec = try await workspace.makeRecording(in: context)
        activeRec.title = "2026-10-21 10_50_49"
        activeRec.importedAt = olderDate
        activeRec.duration = 5178
        activeRec.project = project

        let transcribedRec = Recording(title: "Product Roadmap Sync", audioFileName: "sync.m4a",
                                       originalFileName: "sync.m4a", duration: 1940, importedAt: todayMorning)
        let transcript = Transcript(sourceName: "Local Whisper")
        transcribedRec.transcript = transcript
        context.insert(transcribedRec)
        context.insert(transcript)

        let provider = BlockingTranscriptionProvider()
        let activeModel = RecordingViewModel(recording: activeRec, provider: provider, storage: workspace.storage)
        let task = activeModel.startTranscription(using: SwiftDataTranscriptRepository(context: context))
        defer {
            activeModel.cancelTranscription()
            task?.cancel()
        }
        try await Task.sleep(for: .milliseconds(80))

        let costLabel = MoneyFormatter.string(Money(amount: Decimal(string: "0.12")!))
        let metadata = RecordingRowPresentation.metadataText(for: activeRec, costText: costLabel, now: now, calendar: calendar)
        #expect(metadata.contains("1:26:18"))
        #expect(metadata.contains(costLabel))
        #expect(!metadata.contains("unavailable"))

        let selectedID: UUID? = activeRec.id
        let host = NSHostingView(
            rootView: List(selection: .constant(selectedID)) {
                Section("Recent Recordings") {
                    SidebarRecordingRow(recording: activeRec, transcription: activeModel, costText: costLabel)
                        .tag(Optional(activeRec.id))
                    SidebarRecordingRow(recording: transcribedRec, transcription: nil, costText: "Local")
                        .tag(Optional(transcribedRec.id))
                }
            }
            .listStyle(.sidebar)
            .frame(width: 270, height: 220)
            .environment(\.colorScheme, .dark)
            .modelContainer(container)
        )
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 270, height: 220),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.alphaValue = 0
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        window.layoutIfNeeded()
        assertValidFrames(host)
    }

    @Test func recordingDetailHeaderGroupsProjectMetadataAndToolbar() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = container.mainContext

        let project = Project(name: "SUS")
        let otherProject = Project(name: "Archive")
        context.insert(project)
        context.insert(otherProject)

        let recording = try await workspace.makeRecording(in: context)
        recording.title = "2026-10-21 10_50_49"
        recording.duration = 5178
        recording.project = project

        let host = NSHostingController(
            rootView: NavigationStack {
                RecordingDetailView(
                    recording: recording,
                    transcriptionResolver: FixedTranscriptionProviderResolver(provider: MockTranscriptionProvider()),
                    llmResolver: FixedLLMProviderResolver(provider: MockLLMProvider()),
                    storage: workspace.storage,
                    projects: [project, otherProject],
                    openProject: {},
                    moveToProject: { _ in }
                )
            }
            .environment(\.colorScheme, .dark)
            .modelContainer(container)
        )
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 920, height: 420))
        window.setFrameOrigin(NSPoint(x: -2500, y: -2500))
        window.appearance = NSAppearance(named: .darkAqua)
        window.alphaValue = 0
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        defer { window.close() }

        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        window.layoutIfNeeded()
        assertValidFrames(host.view)
        #expect(window.toolbar?.items.count == 3)

        recording.project = nil
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        window.layoutIfNeeded()
        assertValidFrames(host.view)
    }

    private func findSubviews<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        var matches: [T] = []
        if let typed = view as? T { matches.append(typed) }
        for subview in view.subviews { matches.append(contentsOf: findSubviews(of: type, in: subview)) }
        return matches
    }

    private func assertValidFrames(_ view: NSView) {
        #expect(view.frame.width.isFinite && view.frame.width >= 0)
        #expect(view.frame.height.isFinite && view.frame.height >= 0)
        for subview in view.subviews { assertValidFrames(subview) }
    }
}
