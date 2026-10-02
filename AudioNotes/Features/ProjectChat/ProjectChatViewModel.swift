import Foundation
import SwiftUI
import Observation
import SwiftData

@MainActor @Observable
final class ProjectChatViewModel {
    let project: Project
    var session: ChatSession?
    var inputText = ""
    private(set) var sentQuestionID: UUID?
    private(set) var assistantMessageID = UUID()
    var selection = ProjectChatSelection()
    var scrollState = ChatScrollState()
    var scrollPosition = ScrollPosition(edge: .bottom)
    private(set) var state = ChatGenerationState.idle
    private(set) var streamingDraft: String?
    private(set) var lastError: String?
    private(set) var coverage = RetrievalCoverage()
    private(set) var searchableIDs = Set<UUID>()
    private(set) var operationStartedAt: Date?
    var confirmingClear = false
    var confirmingCloud = false
    private var pendingAction: Action?
    private enum Action: Equatable { case send, retry, regenerate }
    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var repository: SwiftDataChatRepository?
    @ObservationIgnored private let retrieval: RetrievalService
    @ObservationIgnored private let resolver: any LLMProviderResolving
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var publishTask: Task<Void, Never>?
    @ObservationIgnored private var pendingDraft = ""
    @ObservationIgnored private var lastGeneration: GenerationRecord?
    private var cloudConsentProvider: String?

    init(project: Project, resolver: any LLMProviderResolving, retrieval: RetrievalService) {
        self.project = project; self.resolver = resolver; self.retrieval = retrieval
    }
    var isGenerating: Bool { state.isGenerating }
    var providerDescription: String {
        let p = resolver.resolveChat()
        return [p.displayName, p.modelID, p.executionLocation.title].compactMap { $0 }.joined(separator: " · ")
    }
    var hasSelectedContent: Bool { !searchableIDs.intersection(selection.sourceIDs(in: project)).isEmpty }
    var canSend: Bool { !isGenerating && hasSelectedContent && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canRetry: Bool { !isGenerating && session?.interruptedProjectQuestionID != nil && hasSelectedContent }
    var statusText: String {
        switch state {
        case .preparing: "Searching project…"
        case .waitingForFirstToken: "Waiting for AI…"
        case .streaming: "Generating answer…"
        default: ""
        }
    }
    var coverageText: String { "Searching \(coverage.searchableRecordings) recordings and \(coverage.searchableSources) sources" }
    var coverageWarnings: String {
        var parts: [String] = []
        if coverage.untranscribedRecordings > 0 { parts.append("\(coverage.untranscribedRecordings) recordings are not transcribed") }
        if coverage.processingSources > 0 { parts.append("\(coverage.processingSources) sources are still processing") }
        if coverage.failedSources > 0 { parts.append("\(coverage.failedSources) sources are unavailable; retry in Sources") }
        return parts.joined(separator: " · ")
    }
    var suggestions: [String] {
        var values = ["Summarize the main concepts across this project", "Which topics should I review?"]
        if coverage.searchableRecordings > 0 { values.insert("Where was this topic explained in the recordings?", at: 1) }
        if coverage.searchableSources > 0 { values.append("Compare the recordings with the documents") }
        return values
    }

    func attach(context: ModelContext) {
        self.context = context
        repository = SwiftDataChatRepository(context: context)
        do {
            session = try repository?.ensureProjectSession(for: project)
            if let data = session?.projectSelectionData, let value = try? JSONDecoder().decode(ProjectChatSelection.self, from: data) { selection = value }
            if !isGenerating, let pending = session?.pendingProjectQuestionID {
                session?.interruptedProjectQuestionID = pending
                session?.pendingProjectQuestionID = nil
                try repository?.saveSession(session!)
            }
            if session?.interruptedProjectQuestionID != nil { lastError = "Generation interrupted. Retry to search current project material." }
            refreshCoverage()
        } catch { lastError = error.localizedDescription }
    }

    /// Metadata/eligibility only; no derived retrieval index on opening or typing.
    func refreshCoverage() {
        var value = RetrievalCoverage(), ids = Set<UUID>()
        func include(_ source: RecordingSource) {
            let status = source.status
            switch status {
            case .processing, .imported: value.processingSources += 1; return
            case .failed, .unsupported: value.failedSources += 1; return
            case .ready, .partial: break
            }
            guard source.isContextReady else { return }
            let hasText = source.type == .audio ? source.transcript?.segments.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == true :
                source.textUnits.contains { $0.locator != nil && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if hasText { value.searchableSources += 1; ids.insert(source.id) }
        }
        let selected = selection.sourceIDs(in: project)
        for recording in project.recordings {
            let primary = recording.sources.first(where: \.isPrimaryAudio)?.id ?? recording.id
            if selected.contains(primary) {
                if recording.transcript?.segments.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) == true {
                    value.searchableRecordings += 1; ids.insert(primary)
                } else { value.untranscribedRecordings += 1 }
            }
            for source in recording.sources where !source.isPrimaryAudio && source.project == nil && selected.contains(source.id) { include(source) }
        }
        for source in project.sources where source.recording == nil && selected.contains(source.id) { include(source) }
        coverage = value; searchableIDs = ids
        selection.recordingIDs.formIntersection(project.recordings.map(\.id))
        selection.sharedSourceIDs.formIntersection(project.sources.map(\.id))
    }
    func saveSelection() {
        refreshCoverage()
        session?.projectSelectionData = try? JSONEncoder().encode(selection)
        if let session { do { try repository?.saveSession(session) } catch { lastError = error.localizedDescription } }
    }

    func send() { request(.send) }
    func retry() { request(.retry) }
    func regenerate() { request(.regenerate) }
    private func request(_ action: Action) {
        guard !isGenerating else { return }
        refreshCoverage()
        guard hasSelectedContent else { lastError = "Select searchable recordings or sources first."; return }
        let p = resolver.resolveChat()
        if p.executionLocation != .local && p.id != .mock && cloudConsentProvider != p.id.rawValue + (p.modelID ?? "") {
            pendingAction = action; confirmingCloud = true; return
        }
        perform(action)
    }
    func approveCloud() {
        let p = resolver.resolveChat()
        cloudConsentProvider = p.id.rawValue + (p.modelID ?? "")
        if let pendingAction { perform(pendingAction) }
        pendingAction = nil
    }
    private func perform(_ action: Action) {
        guard let session, let repository, let context else { return }
        do {
            switch action {
            case .send:
                let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                let message = ChatMessage(role: .user, text: text)
                try repository.appendMessage(message, to: session)
                session.pendingProjectQuestionID = message.id
                inputText = ""
                sentQuestionID = message.id
            case .retry:
                guard let id = session.interruptedProjectQuestionID else { return }
                session.pendingProjectQuestionID = id
                if let last = session.orderedMessages.last, last.role == .assistant, last.status != .completed { try repository.deleteMessage(last) }
            case .regenerate:
                guard let last = session.orderedMessages.last, last.role == .assistant else { return }
                try repository.deleteMessage(last)
                session.pendingProjectQuestionID = session.orderedMessages.last(where: { $0.role == .user })?.id
            }
            session.interruptedProjectQuestionID = nil
            try repository.saveSession(session)
            guard let question = session.orderedMessages.first(where: { $0.id == session.pendingProjectQuestionID }) else { return }
            generate(question: question, session: session, repository: repository, context: context, isRetry: action == .retry)
        } catch { lastError = error.localizedDescription }
    }

    func cancel() { activeTask?.cancel() }
    func cancelAndWait() async { let task = activeTask; task?.cancel(); await task?.value }
    func clear() {
        guard !isGenerating, let session, let repository else { return }
        do {
            try repository.clearMessages(in: session)
            session.pendingProjectQuestionID = nil; session.interruptedProjectQuestionID = nil
            try repository.saveSession(session)
            lastError = nil; state = .idle; scrollPosition = ScrollPosition(edge: .bottom); scrollState = .init()
        } catch { lastError = error.localizedDescription }
    }

    private func publish(_ delta: String) {
        pendingDraft += delta
        if streamingDraft == nil { streamingDraft = ProjectCitationResolver.clean(pendingDraft) }
        guard publishTask == nil else { return }
        publishTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            streamingDraft = ProjectCitationResolver.clean(pendingDraft); publishTask = nil
        }
    }

    private func history(session: ChatSession, question: ChatMessage, selected: Set<UUID>) -> [LLMChatMessage] {
        let generations = Dictionary(project.generationRecords.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var values: [LLMChatMessage] = []
        for message in session.orderedMessages {
            if message.role == .assistant {
                guard message.status == .completed, let id = message.generationID,
                      let data = generations[id]?.selectedSourceIDsData,
                      let ids = try? JSONDecoder().decode([UUID].self, from: data), Set(ids).isSubset(of: selected) else { continue }
            }
            if message.role != .system { values.append(.init(role: message.role, content: message.text)) }
            if message.id == question.id { break }
        }
        return values
    }

    private func generate(question: ChatMessage, session: ChatSession, repository: SwiftDataChatRepository, context: ModelContext, isRetry: Bool) {
        let provider = resolver.resolveChat(), settings = resolver.chatSettings()
        let selected = selection.sourceIDs(in: project).intersection(searchableIDs)
        let messages = history(session: session, question: question, selected: selected)
        let query = ProjectRetrievalQueryBuilder().query(history: messages)
        let selectionData = try? JSONEncoder().encode(selected.sorted { $0.uuidString < $1.uuidString })
        let generation: GenerationRecord
        if isRetry, let previous = lastGeneration, previous.selectedSourceIDsData == selectionData,
           previous.canRetry(provider: provider.id.rawValue, model: provider.modelID, authentication: provider.authenticationMethod),
           previous.outputLengthRaw == settings.outputLength.rawValue, previous.maxOutputTokens == settings.maxOutputTokens,
           previous.temperature == settings.temperature, previous.topP == settings.topP,
           previous.reasoningEffortRaw == settings.reasoningEffort?.rawValue {
            generation = previous
            generation.statusRaw = GenerationStatus.inProgress.rawValue
            generation.attemptCount += 1
        } else {
            generation = GenerationRecord(feature: .chat, provider: provider.id, model: provider.modelID,
                presetName: nil, outputLength: settings.outputLength, settings: settings,
                authenticationMethod: provider.authenticationMethod, status: .inProgress, billingKind: provider.billingKind, project: project)
        }
        lastGeneration = generation
        generation.selectedSourceIDsData = selectionData
        generation.executionLocationRaw = provider.executionLocation.rawValue
        generation.generationStrategy = "project_retrieval"
        let tracker = OperationUsageTracker(generation: generation)
        do { try repository.record(generation) } catch { lastError = error.localizedDescription; return }
        assistantMessageID = UUID()
        state = .preparing; pendingDraft = ""; streamingDraft = nil; lastError = nil; operationStartedAt = .now
        activeTask = Task { [self] in
            var requestID: UUID?, usage: GenerationUsage?
            let started = Date.now
            defer {
                publishTask?.cancel(); publishTask = nil
                streamingDraft = nil; activeTask = nil
            }
            do {
                let budget = try ProjectChatBudget(contextWindow: provider.inputCapabilities.contextWindowTokens, settings: settings, question: question.text)
                let history = budget.history(messages)
                var options = RetrievalOptions(); options.sourceIDs = selected; options.maximumTokens = budget.evidenceBudget
                let result = try await retrieval.retrieve(query: query, scope: .project(project.id), context: context, options: options)
                try Task.checkCancellation()
                generation.retrievalDurationSeconds = Date.now.timeIntervalSince(started)
                var chatContext = ChatContext(recordingTitle: project.name, transcript: Transcript(), generationSettings: settings, retrievalUsed: true)
                var effectiveSettings = settings
                if effectiveSettings.maxOutputTokens == nil { effectiveSettings.maxOutputTokens = budget.outputReserve }
                chatContext.generationSettings = effectiveSettings
                chatContext.sourceChunks = ProjectChatPrompt.chunks(result.context)
                chatContext.projectEvidence = try ProjectChatPrompt.evidence(result.context)
                let formatted = try ChatContextBuilder().buildPrompt(context: chatContext, history: history)
                let actual = TranscriptTokenEstimator.estimate(formatted.systemInstructions) + formatted.messages.reduce(0) { $0 + ProjectChatBudget.tokens($1) }
                guard actual + budget.outputReserve + 256 <= budget.contextWindow else { throw LLMError.contextTooLarge(approximateTokens: actual + budget.outputReserve) }
                generation.estimatedHistoryTokens = history.reduce(0) { $0 + ProjectChatBudget.tokens($1) }
                generation.estimatedProjectContextTokens = TranscriptTokenEstimator.estimate(chatContext.projectEvidence ?? "")
                generation.chunkCount = result.context.entries.count
                generation.retrievedSourceCount = Set(result.context.entries.map { $0.document.sourceID }).count
                state = .waitingForFirstToken
                requestID = tracker.beginRequest()
                try repository.record(generation)
                let stream = try await provider.streamChat(messages: history, context: chatContext)
                for try await event in stream {
                    if case .usage(let reported) = event { usage = reported }
                    try Task.checkCancellation()
                    switch event {
                    case .textDelta(let delta):
                        if generation.firstTokenSeconds == nil { generation.firstTokenSeconds = Date.now.timeIntervalSince(started) }
                        if state != .streaming { state = .streaming }
                        publish(delta)
                    case .usage, .references: break
                    case .completed(let response):
                        usage = response.usage ?? usage
                        let citations = try await validated(response: response, package: result.context, selected: selected, context: context)
                        try Task.checkCancellation()
                        let message = ChatMessage(id: assistantMessageID, role: .assistant, text: ProjectCitationResolver.clean(response.content))
                        message.projectCitations = citations; message.sourceReferences = citations.map(\.reference)
                        message.generationID = generation.id; generation.chatMessageID = message.id
                        generation.characterCount = message.text.count; generation.wordCount = message.text.split(whereSeparator: \.isWhitespace).count
                        session.pendingProjectQuestionID = nil; session.interruptedProjectQuestionID = nil
                        try repository.appendMessage(message, to: session)
                        if let requestID { tracker.finishRequest(requestID, usage: usage, model: response.modelID, succeeded: true) }
                        tracker.finish(status: .succeeded); try repository.record(generation)
                        state = .completed; return
                    }
                }
                try Task.checkCancellation()
                throw LLMError.invalidResponse
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError
                if let requestID {
                    if ProviderRequestFailure.isKnownPreflight(error) { tracker.discardUnsentRequest(requestID) }
                    else { tracker.finishRequest(requestID, usage: (error as? ProviderUsageError)?.usage ?? usage, succeeded: false) }
                }
                tracker.finish(status: cancelled ? .cancelled : .failed)
                session.interruptedProjectQuestionID = question.id; session.pendingProjectQuestionID = nil
                if !pendingDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let message = ChatMessage(id: assistantMessageID, role: .assistant, text: ProjectCitationResolver.clean(pendingDraft), status: .interrupted)
                    message.generationID = generation.id; generation.chatMessageID = message.id
                    // Partial Markdown remains readable; only complete validated final citations are persisted.
                    try? repository.appendMessage(message, to: session)
                }
                lastError = cancelled ? "Generation interrupted. Retry to search current project material." : error.localizedDescription
                state = cancelled ? .cancelled : .failed(lastError ?? "Generation failed")
                do { try repository.record(generation); try repository.saveSession(session) }
                catch { lastError = "Could not save generation state: \(error.localizedDescription)" }
            }
        }
    }

    private func validated(response: LLMChatResponse, package: ContextPackage, selected: Set<UUID>, context: ModelContext) async throws -> [ProjectCitation] {
        let needed = Set(package.entries.map { $0.document.sourceID }).intersection(selected)
        let snapshot = try RetrievalSnapshot.capture(scope: .project(project.id), context: context, includedSourceIDs: needed)
        let sources = snapshot.sources.filter { needed.contains($0.id) }
        let worker = Task.detached(priority: .userInitiated) { try sources.flatMap { try RetrievalDocumentBuilder().documents(source: $0) } }
        let documents = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        return ProjectCitationResolver.resolve(response: response, package: package, fresh: documents)
    }

    func exportContent() -> ExportContent {
        let messages = (session?.orderedMessages ?? []).map { message in
            var value = ExportChatMessage(role: message.role.rawValue, text: message.text, sentAt: message.createdAt)
            value.sourceLabels = SourceReferencePresentation.labels(message.projectCitations.map(\.reference))
            return value
        }
        return ExportContent(title: project.name, originalFileName: "", duration: 0, recordedAt: project.createdAt, chat: messages)
    }
}
