import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ProjectChatView: View {
    @Bindable var model: ProjectChatViewModel
    let library: LibraryViewModel
    @Environment(\.modelContext) private var context
    @State private var showsSelection = false
    @State private var showsUsage = false
    @State private var preview: SourcePreviewTarget?
    @State private var exportError: String?
    @State private var focusRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.coverageText).font(.caption).foregroundStyle(.secondary)
                    if !model.coverageWarnings.isEmpty { Text(model.coverageWarnings).font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer()
                Button("Usage & Cost", systemImage: "dollarsign.circle") { showsUsage = true }.labelStyle(.iconOnly)
                    .help("Project chat usage & cost").accessibilityIdentifier("chat.usage")
                Button("Export Chat…", systemImage: "square.and.arrow.up") { export() }.labelStyle(.iconOnly)
                    .disabled(model.session?.messages.isEmpty ?? true)
                    .help("Export chat as Markdown").accessibilityIdentifier("chat.export")
                Button("Clear Conversation…", systemImage: "trash") { model.confirmingClear = true }.labelStyle(.iconOnly).disabled(model.isGenerating)
                    .help("Clear conversation").accessibilityIdentifier("chat.clear")
            }.buttonStyle(.borderless).padding(12)
            Divider()
            conversation
            Divider()
            composer
        }
        .onAppear { model.attach(context: context) }
        .onChange(of: model.selection) { _, _ in model.saveSelection() }
        .onChange(of: coverageRevision) { _, _ in model.refreshCoverage() }
        .sheet(isPresented: $showsSelection) { ProjectChatSelectionView(model: model) }
        .sheet(isPresented: $showsUsage) { UsageCostView(projectID: model.project.id, feature: .chat) }
        .sheet(item: $preview) { SourcePreviewView(target: $0, url: library.projectImports.storage.sourceURL($0.source)) }
        .confirmationDialog("Send relevant project excerpts?", isPresented: $model.confirmingCloud, titleVisibility: .visible) {
            Button("Send to Selected Provider") { model.approveCloud() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("\(model.providerDescription) receives your question, bounded conversation history, and relevant excerpts from selected project material. This permission lasts while this project chat is open in this window.") }
        .confirmationDialog("Clear Project Chat?", isPresented: $model.confirmingClear, titleVisibility: .visible) {
            Button("Clear Conversation", role: .destructive) { model.clear() }
        } message: { Text("This deletes project chat messages. Recordings, sources and usage history remain.") }
        .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(exportError ?? "") }
    }

    private var coverageRevision: String {
        model.project.recordings.map { "\($0.id)-\($0.transcript?.id.uuidString ?? "")-\($0.sources.map { $0.statusRaw }.joined())" }.joined() +
        model.project.sources.map { "\($0.id)-\($0.statusRaw)" }.joined()
    }

    private var conversation: some View {
        ChatMessageList(scrollState: $model.scrollState, scrollPosition: $model.scrollPosition,
            messageCount: model.session?.messages.count ?? 0,
            latestMessageID: model.session?.orderedMessages.last?.id, activeResponseID: model.assistantMessageID, draft: model.streamingDraft,
            generationState: model.state, sentQuestionID: model.sentQuestionID) {
            if (model.session?.messages.isEmpty ?? true) && !model.isGenerating { emptyState }
            let messages = model.session?.orderedMessages ?? []
            ForEach(messages) { message in
                ProjectChatMessageRow(message: message, project: model.project,
                    canRegenerate: message.id == messages.last?.id && !model.isGenerating,
                    open: openCitation, regenerate: model.regenerate)
                    .id(message.id)
            }
            if model.isGenerating {
                ChatActiveResponse(isStreaming: model.state == .streaming,
                    phase: model.statusText, startedAt: model.operationStartedAt) {
                    AssistantMessageView(markdown: model.streamingDraft ?? "", references: [])
                }.id("active-\(model.assistantMessageID)")
            }
            if let error = model.lastError {
                ChatErrorView(error: error, canRetry: model.canRetry, onRetry: model.retry)
            }
        }
    }
    private var emptyState: some View {
        ChatEmptyState(title: "Ask about \(model.project.name)",
            description: model.hasSelectedContent ? "Chat across your searchable recordings and sources." : "This project doesn’t have searchable content in the selected scope yet. Transcribe a recording or add a document to start chatting.") {
            if model.hasSelectedContent {
                Text("Try asking").font(.caption).foregroundStyle(.secondary)
                ForEach(model.suggestions, id: \.self) { prompt in
                    Button(prompt) { model.inputText = prompt; focusRequest += 1 }.buttonStyle(.link)
                }
            }
        }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(model.selection.entireProject ? "Entire Project" : "Selected Sources", systemImage: "line.3.horizontal.decrease") { showsSelection = true }
                    .disabled(model.isGenerating)
                    .accessibilityLabel("Search scope: \(model.selection.entireProject ? "entire project" : "selected sources")")
                    .accessibilityHint("Choose which recordings and sources the assistant can search")
                    .accessibilityIdentifier("chat.scope")
                Spacer()
                SettingsLink { Text(model.providerDescription).font(.caption).lineLimit(2) }
                    .help("Uses the same Chat provider, model and generation settings as Recording Chat")
                    .accessibilityLabel("Chat provider: \(model.providerDescription)")
                    .accessibilityHint("Opens chat provider settings")
                    .accessibilityIdentifier("chat.settings")
            }.buttonStyle(.borderless)
            ChatComposer(text: $model.inputText, focusRequest: $focusRequest,
                placeholder: "Ask about \(model.project.name)…", canSend: model.canSend,
                isGenerating: model.isGenerating, onSend: model.send, onStop: model.cancel)
        }.frame(maxWidth: 760).frame(maxWidth: .infinity).padding(12)
    }
    private func openCitation(_ citation: ProjectCitation) {
        guard ProjectCitationNavigation.available(citation, project: model.project) else { return }
        if let recording = ProjectCitationNavigation.recording(citation, project: model.project) {
            library.selectRecording(recording.id); library.pendingProjectCitation = citation
        } else if let source = ProjectCitationNavigation.source(citation, project: model.project) {
            preview = .init(source: source, locator: citation.reference.locator)
        }
    }
    private func export() {
        Task {
            let types = [UTType(filenameExtension: "md") ?? .plainText]
            guard let url = await FilePanels.chooseSaveDestination(fileName: model.project.name + " Chat.md", types: types) else { return }
            let content = model.exportContent()
            let options = ExportOptions(format: .markdown, includeMetadata: false, includeSummary: false, includeTranscript: false, includeChat: true)
            do { try await NativeExportService().write(content: content, options: options, to: url) } catch { exportError = error.localizedDescription }
        }
    }
}

private struct ProjectChatMessageRow: View {
    let message: ChatMessage
    let project: Project
    let canRegenerate: Bool
    let open: (ProjectCitation) -> Void
    let regenerate: () -> Void
    var body: some View {
        ChatMessageRow(presentation: ChatMessagePresentation(message), canRegenerate: canRegenerate,
            onCopy: copy, onRegenerate: regenerate) {
            if message.role == .assistant {
                AssistantMessageView(markdown: message.text, references: [])
                if !message.projectCitations.isEmpty {
                    DisclosureGroup("Sources Used · \(SourceReferencePresentation.groups(message.projectCitations.map(\.reference)).count)") {
                        FlowLayout {
                            ForEach(SourceReferencePresentation.groups(message.projectCitations.map(\.reference))) { group in
                                if let citation = message.projectCitations.first(where: { $0.id == group.primary.chunkID }) {
                                    let available = ProjectCitationNavigation.available(citation, project: project)
                                    let label = ProjectCitationNavigation.label(citation, project: project)
                                    Button { open(citation) } label: {
                                        Label(label + (available ? "" : " · Unavailable"), systemImage: group.primary.sourceType.icon)
                                            .font(.caption).padding(6).background(Color.accentColor.opacity(0.1), in: Capsule())
                                    }.buttonStyle(.plain).disabled(!available).help(group.excerpt)
                                        .accessibilityLabel((available ? "Open citation, " : "Citation unavailable, ") + label)
                                }
                            }
                        }.padding(.top, 6)
                    }.font(.caption)
                }
            } else { Text(message.text).font(.callout).textSelection(.enabled) }
        }
    }
    private func copy() { Clipboard.copy(message.text) }
}
