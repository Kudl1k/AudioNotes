#if os(iOS)
import SwiftData
import SwiftUI

struct IOSProjectChatView: View {
    let project: Project
    let services: AppServices
    let library: LibraryViewModel
    @Environment(\.modelContext) private var context
    @State private var model: ProjectChatViewModel
    @State private var focusRequest = 0
    @State private var showsUsage = false
    @State private var preview: CitationPreview?

    private struct CitationPreview: Identifiable {
        let source: RecordingSource
        let page: Int
        var id: UUID { source.id }
    }

    init(project: Project, services: AppServices, library: LibraryViewModel) {
        self.project = project
        self.services = services
        self.library = library
        _model = State(initialValue: library.projectChatModel(for: project, resolver: IOSFeatureProviders.llm(services)))
    }

    var body: some View {
        VStack(spacing: 0) {
            if !model.coverageWarnings.isEmpty {
                Text(model.coverageWarnings).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: 760, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 6)
                    .accessibilityIdentifier("project.chat.coverage")
            } else if model.session?.messages.isEmpty ?? true {
                Text(model.coverageText).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: 760, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 6)
                    .accessibilityIdentifier("project.chat.coverage")
            }
            conversation.frame(maxHeight: .infinity)
            composer
        }
        .onAppear { model.attach(context: context) }
        .onChange(of: coverageRevision) { _, _ in model.refreshCoverage() }
        .sheet(isPresented: $showsUsage) { UsageCostView(projectID: project.id, feature: .chat) }
        .sheet(item: $preview) { target in IOSProjectSourceViewer(source: target.source, url: library.projectImports.storage.sourceURL(target.source), page: target.page) }
        .confirmationDialog("Send relevant project excerpts?", isPresented: $model.confirmingCloud, titleVisibility: .visible) {
            Button("Send to Selected Provider") { model.approveCloud() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(model.providerDescription) receives your question, bounded conversation history, and relevant excerpts from this project. This permission lasts while this project chat is open.")
        }
        .confirmationDialog("Clear Project Chat?", isPresented: $model.confirmingClear, titleVisibility: .visible) {
            Button("Clear Conversation", role: .destructive) { model.clear() }
        } message: { Text("This deletes project chat messages. Recordings, sources and usage history remain.") }
    }

    private var coverageRevision: String {
        project.recordings.map { "\($0.id)-\($0.transcript?.id.uuidString ?? "")-\($0.sources.map(\.statusRaw).joined())" }.joined() +
        project.sources.map { "\($0.id)-\($0.statusRaw)" }.joined()
    }

    private var conversation: some View {
        ChatMessageList(scrollState: $model.scrollState, scrollPosition: $model.scrollPosition,
            messageCount: model.session?.messages.count ?? 0,
            latestMessageID: model.session?.orderedMessages.last?.id,
            activeResponseID: model.assistantMessageID, draft: model.streamingDraft,
            generationState: model.state, sentQuestionID: model.sentQuestionID) {
            if (model.session?.messages.isEmpty ?? true) && !model.isGenerating { emptyState }
            let messages = model.session?.orderedMessages ?? []
            ForEach(messages) { message in
                ChatMessageRow(presentation: ChatMessagePresentation(message),
                    canRegenerate: message.role == .assistant && message.id == messages.last?.id && !model.isGenerating,
                    onCopy: { Clipboard.copy(message.text) }, onRegenerate: model.regenerate) {
                    if message.role == .assistant {
                        AssistantMessageView(markdown: message.text, references: [])
                        citations(message.projectCitations)
                    } else {
                        Text(message.text).font(.callout).textSelection(.enabled)
                    }
                }.id(message.id)
            }
            if model.isGenerating {
                ChatActiveResponse(isStreaming: model.state == .streaming, phase: model.statusText,
                    startedAt: model.operationStartedAt) {
                    AssistantMessageView(markdown: model.streamingDraft ?? "", references: [])
                }.id("active-\(model.assistantMessageID)")
            }
            if let error = model.lastError {
                ChatErrorView(error: error, canRetry: model.canRetry, onRetry: model.retry)
            }
        }
        .accessibilityIdentifier("project.chat.conversation")
    }

    private var emptyState: some View {
        ChatEmptyState(title: "Ask about this project",
            description: model.hasSelectedContent
                ? "AudioNotes can use the searchable recordings and sources in this project."
                : "Add a source or transcribe a recording to start chatting.") {
            if model.hasSelectedContent {
                Text("\(model.coverage.searchableRecordings) recordings · \(model.coverage.searchableSources) sources available")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.suggestions.prefix(3), id: \.self) { prompt in
                    Button(prompt) { model.inputText = prompt; focusRequest += 1 }
                        .buttonStyle(.plain).foregroundStyle(.tint).accessibilityIdentifier("project.chat.suggestion")
                }
            }
        }.accessibilityIdentifier("project.chat.empty")
    }

    @ViewBuilder private func citations(_ values: [ProjectCitation]) -> some View {
        if !values.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(SourceReferencePresentation.groups(values.map(\.reference))) { group in
                    if let citation = values.first(where: { $0.id == group.primary.chunkID }) {
                        let label = ProjectCitationNavigation.label(citation, project: project)
                        let available = ProjectCitationNavigation.available(citation, project: project)
                        Button { open(citation) } label: {
                            Label(label, systemImage: group.primary.sourceType.icon)
                                .font(.caption).padding(.horizontal, 8).padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.1), in: Capsule())
                        }.buttonStyle(.plain).disabled(!available)
                            .accessibilityLabel((available ? "Open citation, " : "Citation unavailable, ") + label)
                            .accessibilityIdentifier("project.chat.citation")
                    }
                }
            }.padding(.top, 4)
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            HStack {
                Text(model.coverageText).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Menu {
                    Section(model.providerDescription) {
                    Button("Usage & Cost", systemImage: "dollarsign.circle") { showsUsage = true }
                    ShareLink(item: exportedMarkdown) { Label("Export Chat as Markdown", systemImage: "square.and.arrow.up") }
                    Button("Clear Conversation…", systemImage: "trash", role: .destructive) { model.confirmingClear = true }
                        .disabled(model.isGenerating || (model.session?.messages.isEmpty ?? true))
                    OpenSettingsLink { Label("Chat Provider Settings", systemImage: "slider.horizontal.3") }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Project Chat options")
                    .accessibilityIdentifier("project.chat.options")
            }.padding(.horizontal, 16)
            ChatComposer(text: $model.inputText, focusRequest: $focusRequest,
                placeholder: "Ask about \(project.name)…", canSend: model.canSend,
                isGenerating: model.isGenerating, onSend: model.send, onStop: model.cancel)
                .frame(maxWidth: 760).padding(.horizontal, 12).padding(.bottom, 8)
        }
        .background(.bar)
    }

    private var exportedMarkdown: String {
        let options = ExportOptions(format: .markdown, includeMetadata: false, includeSummary: false, includeTranscript: false, includeChat: true)
        return MarkdownExporter().export(content: model.exportContent(), options: options)
    }

    private func open(_ citation: ProjectCitation) {
        guard let intent = ProjectCitationNavigation.intent(citation, project: project) else { return }
        switch intent {
        case .recording(let id, _):
            library.selectRecording(id)
            library.pendingProjectCitation = citation
        case .source(let id, let pageIndex):
            guard let source = project.sources.first(where: { $0.id == id }) else { return }
            preview = CitationPreview(source: source, page: pageIndex ?? 0)
        }
    }
}
#endif
