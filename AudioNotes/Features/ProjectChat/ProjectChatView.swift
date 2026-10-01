import AppKit
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
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.coverageText).font(.caption).foregroundStyle(.secondary)
                    if !model.coverageWarnings.isEmpty { Text(model.coverageWarnings).font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer()
                Button("Usage & Cost", systemImage: "dollarsign.circle") { showsUsage = true }.labelStyle(.iconOnly)
                Button("Export Chat…", systemImage: "square.and.arrow.up") { export() }.labelStyle(.iconOnly)
                    .disabled(model.session?.messages.isEmpty ?? true)
                Button("Clear Conversation…", systemImage: "trash") { model.confirmingClear = true }.labelStyle(.iconOnly).disabled(model.isGenerating)
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.session?.messages.isEmpty ?? true { emptyState }
                    ProjectChatHistory(model: model, open: openCitation)
                    if model.isGenerating {
                        if let draft = model.streamingDraft {
                            AssistantMessageView(markdown: draft, references: [])
                                .padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                        } else {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(model.statusText).foregroundStyle(.secondary) }
                                .padding(12).accessibilityLabel(model.statusText)
                        }
                    }
                    if let error = model.lastError {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(error, systemImage: "exclamationmark.triangle").font(.callout)
                            if model.canRetry { Button("Retry", action: model.retry) }
                            SettingsLink { Text("Choose Chat Provider…") }
                        }.padding(10)
                    }
                    Color.clear.frame(height: 1).id("project_chat_bottom")
                }.frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity).padding(20)
                .scrollTargetLayout()
            }
            .scrollPosition(id: $model.scrollAnchor, anchor: .top)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - (geometry.contentOffset.y + geometry.containerSize.height) <= 64
            } action: { _, nearBottom in model.scrollState.positionChanged(nearBottom: nearBottom) }
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .tracking, .interacting, .decelerating: model.scrollState.userScrolling(true)
                case .idle: model.scrollState.userScrolling(false)
                default: break
                }
            }
            .overlay(alignment: .bottom) {
                if model.scrollState.hasUnseenContent {
                    Button("Jump to Latest", systemImage: "arrow.down") {
                        model.scrollState.jumpToLatest(); proxy.scrollTo("project_chat_bottom", anchor: .bottom)
                    }.buttonStyle(.borderedProminent).padding(8)
                }
            }
            .onChange(of: model.streamingDraft) { _, _ in
                if model.scrollState.contentArrived() { proxy.scrollTo("project_chat_bottom", anchor: .bottom) }
            }
            .onChange(of: model.session?.messages.count) { _, _ in
                if model.scrollState.contentArrived() { proxy.scrollTo("project_chat_bottom", anchor: .bottom) }
            }
        }
    }
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask about \(model.project.name)").font(.title2.bold())
            Text(model.hasSelectedContent ? "Chat across your searchable recordings and sources." : "This project doesn’t have searchable content in the selected scope yet. Transcribe a recording or add a document to start chatting.")
                .foregroundStyle(.secondary)
            if model.hasSelectedContent {
                Text("Try asking").font(.caption).foregroundStyle(.secondary)
                ForEach(model.suggestions, id: \.self) { prompt in
                    Button(prompt) { model.inputText = prompt; inputFocused = true }.buttonStyle(.link)
                }
            }
        }.padding(.vertical, 24)
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(model.selection.entireProject ? "Entire Project" : "Selected Sources", systemImage: "line.3.horizontal.decrease") { showsSelection = true }
                    .disabled(model.isGenerating)
                Spacer()
                SettingsLink { Text(model.providerDescription).font(.caption).lineLimit(2) }
                    .help("Uses the same Chat provider, model and generation settings as Recording Chat")
            }.buttonStyle(.borderless)
            HStack(alignment: .bottom) {
                TextField("Ask about \(model.project.name)…", text: $model.inputText, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...5).focused($inputFocused)
                    .onKeyPress(.return) {
                        if NSEvent.modifierFlags.contains(.shift) { return .ignored }
                        if model.canSend { model.send() }; return .handled
                    }
                if model.isGenerating {
                    Button("Cancel", systemImage: "stop.circle.fill", action: model.cancel).keyboardShortcut(.cancelAction)
                } else { Button("Send", systemImage: "arrow.up.circle.fill", action: model.send).disabled(!model.canSend) }
            }
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
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = model.project.name + " Chat.md"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let content = model.exportContent()
            let options = ExportOptions(format: .markdown, includeMetadata: false, includeSummary: false, includeTranscript: false, includeChat: true)
            Task { do { try await NativeExportService().write(content: content, options: options, to: url) } catch { exportError = error.localizedDescription } }
        }
    }
}

private struct ProjectChatHistory: View {
    let model: ProjectChatViewModel
    let open: (ProjectCitation) -> Void
    var body: some View {
        let messages = model.session?.orderedMessages ?? []
        ForEach(messages) { message in
            ProjectChatMessageRow(message: message, project: model.project,
                canRegenerate: message.id == messages.last?.id && !model.isGenerating, open: open, regenerate: model.regenerate)
                .id(message.id)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(message.role == .user ? "You" : "AudioNotes").font(.caption.bold()).foregroundStyle(.secondary)
                if message.role == .assistant { GenerationDetailsButton(generationID: message.generationID) }
                if message.status == .interrupted { Text("Interrupted").font(.caption).foregroundStyle(.secondary) }
            }
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
                                        .accessibilityLabel("Source: " + label + (available ? "" : ", unavailable"))
                                }
                            }
                        }.padding(.top, 6)
                    }.font(.caption)
                }
            } else { Text(message.text).font(.callout).textSelection(.enabled) }
            HStack {
                Button("Copy", systemImage: "doc.on.doc", action: copy).font(.caption)
                if message.role == .assistant && canRegenerate { Button("Regenerate", systemImage: "arrow.clockwise", action: regenerate).font(.caption) }
            }.buttonStyle(.borderless)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(message.role == .user ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain).accessibilityLabel(message.role == .user ? "User message" : "Assistant message")
            .contextMenu {
                Button("Copy", action: copy)
                if message.role == .assistant && canRegenerate { Button("Regenerate", action: regenerate) }
            }
    }
    private func copy() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string) }
}
