import SwiftData
import SwiftUI

struct RecordingDetailView: View {
    let recording: Recording
    private let projectCitation: ProjectCitation?
    private let projects: [Project]
    private let openProject: (() -> Void)?
    private let moveToProject: (Project?) -> Void
    private let transcriptionResolver: any TranscriptionProviderResolving
    private let storage: LibraryStorage
    @State private var sourcesModel: SourcesViewModel
    @State private var sourcePreview: SourcePreviewTarget?
    @State private var revealedSegmentID: UUID?
    private let llmResolver: any LLMProviderResolving
    @Environment(\.modelContext) private var modelContext
    @State private var model: RecordingViewModel
    @State private var summaryModel: SummaryViewModel
    private let chatModel: ChatViewModel?
    @State private var selectedTab = DetailTab.transcript
    @State private var playback = AudioPlaybackService()
    @State private var showsChat = false
    @State private var showingExportSheet = false
    @State private var showsUsage = false
    @State private var showsTranscriptHistory = false
    @State private var showsRegenerationOptions = false
    @State private var headerHeight: CGFloat = 0

    private enum DetailTab: Hashable { case summary, transcript, sources }

    init(
        recording: Recording,
        transcriptionResolver: any TranscriptionProviderResolving,
        llmResolver: any LLMProviderResolving = FixedLLMProviderResolver(provider: MockLLMProvider()),
        storage: LibraryStorage = LibraryStorage(),
        transcriptionModel: RecordingViewModel? = nil,
        sourcesModel: SourcesViewModel? = nil,
        summaryModel: SummaryViewModel? = nil,
        chatModel: ChatViewModel? = nil,
        projectCitation: ProjectCitation? = nil,
        projects: [Project] = [],
        openProject: (() -> Void)? = nil,
        moveToProject: @escaping (Project?) -> Void = { _ in }
    ) {
        self.projectCitation = projectCitation
        self.projects = projects
        self.openProject = openProject
        self.moveToProject = moveToProject
        self.recording = recording
        self.chatModel = chatModel
        self.llmResolver = llmResolver
        self.transcriptionResolver = transcriptionResolver
        self.storage = storage
        _sourcesModel = State(initialValue: sourcesModel ?? SourcesViewModel(recording: recording, storage: storage))
        if recording.audioFileName.isEmpty { _selectedTab = State(initialValue: .sources) }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--performance-fixtures") {
            let args = ProcessInfo.processInfo.arguments
            let tab = args.firstIndex(of: "--performance-tab").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            _selectedTab = State(initialValue: tab == "summary" ? .summary : tab == "sources" ? .sources : .transcript)
            _showsChat = State(initialValue: tab == "chat")
        }
#endif
        _model = State(initialValue: transcriptionModel ?? RecordingViewModel(recording: recording, resolver: transcriptionResolver, storage: storage))
        _summaryModel = State(initialValue: summaryModel ?? SummaryViewModel(recording: recording, resolver: llmResolver))
    }

    /// Convenience initializer to preserve compatibility with existing tests and previews
    init(
        recording: Recording,
        resolver: any TranscriptionProviderResolving,
        storage: LibraryStorage = LibraryStorage()
    ) {
        self.init(recording: recording, transcriptionResolver: resolver, llmResolver: FixedLLMProviderResolver(provider: MockLLMProvider()), storage: storage)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    recordingHeader
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                    recordingTabs
                        // A usable tab viewport survives short windows; the outer
                        // column scrolls rather than forcing native constraints smaller.
                        .frame(height: max(240, geometry.size.height - headerHeight - 16))
                        .padding(.vertical, WorkspaceSpacing.standard)
                }
            }
        }
        .navigationTitle(recording.title)
        .sheet(isPresented: $showsTranscriptHistory) {
            TranscriptHistoryView(recording: recording, isProcessing: model.state.isProcessing) { playback.seek(to: $0) }
        }
        .sheet(isPresented: $showsUsage) { UsageCostView(recordingID: recording.id) }
        .toolbar {
            ToolbarItem {
                Button("Usage & Cost", systemImage: "dollarsign.circle") { showsUsage = true }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingExportSheet = true
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .help("Export recording summary and transcript (⌘E)")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsChat.toggle()
                } label: {
                    Label("Chat", systemImage: "sidebar.right")
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .help(showsChat ? "Hide chat (⌘⌥C)" : "Show chat (⌘⌥C)")
            }
        }
        .focusedValue(\.exportAction) {
            showingExportSheet = true
        }
        .sheet(isPresented: $showingExportSheet) {
            ExportSheetView(recording: recording)
        }
        .inspector(isPresented: $showsChat) {
            ChatInspectorView(
                recording: recording,
                resolver: llmResolver,
                onSeek: { playback.seek(to: $0) },
                onTranscribe: startTranscription, onOpenSource: openReference, chatModel: chatModel
            )
            .inspectorColumnWidth(min: 280, ideal: 350, max: 480)
        }
        .task(id: model.showsCompletion) {
            guard model.showsCompletion else { return }
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            model.dismissCompletion()
        }
        .sheet(item: $sourcePreview) { target in SourcePreviewView(target: target, url: storage.sourceURL(target.source)) }
        .onAppear {
            sourcesModel.prepare(context: modelContext)
            if !recording.audioFileName.isEmpty { playback.load(url: model.audioURL) }
            openProjectCitation()
        }
        .onChange(of: recording.audioFileName) { _, name in
            if name.isEmpty { playback.stop() }
        }
        .onDisappear {
            playback.stop()
        }
    }

    private var recordingHeader: some View {
        VStack(spacing: 0) {
            if let project = recording.project, let openProject {
                HStack {
                    Button(project.name, systemImage: "folder", action: openProject).buttonStyle(.link)
                    Image(systemName: "chevron.right").font(.caption)
                    Text(recording.title).lineLimit(1)
                    Spacer()
                    Menu("Organize") {
                        RecordingProjectMenu(recording: recording, projects: projects, move: moveToProject)
                    }
                }
                .font(.caption)
                .padding(.horizontal, WorkspaceSpacing.majorSection)
                .padding(.vertical, WorkspaceSpacing.standard)
            }
            VStack(alignment: .leading, spacing: WorkspaceSpacing.standard) {
                Text(recording.title).font(.title.bold()).textSelection(.enabled)
                HStack {
                    Button("Sources: \(recording.sources.count)") { selectedTab = .sources }.buttonStyle(.link)
                    Text("•")
                    Text(recording.importedAt, format: .dateTime.month().day().year())
                }
                .font(.subheadline).foregroundStyle(.secondary)
                TranscriptionCostLabel(recordingID: recording.id)
                if !recording.audioFileName.isEmpty {
                    PlaybackControls(playback: playback)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(WorkspaceSpacing.majorSection)
            .layoutPriority(1)
            Divider()
            if !recording.audioFileName.isEmpty && (recording.transcript == nil || model.showsCompletion || model.state.isProcessing || model.errorDetails != nil || transcriptionFailed) {
                TranscriptionControls(model: model, transcribe: startTranscription, regenerate: { selectedTab = .transcript; showsRegenerationOptions = true })
                    .padding([.horizontal, .top], 16)
            }
        }
    }

    private var recordingTabs: some View {
        TabView(selection: $selectedTab) {
            Tab("Sources", systemImage: "doc.on.doc", value: DetailTab.sources) {
                SourcesView(model: sourcesModel, transcriptionResolver: transcriptionResolver, transcriptionModel: model,
                    primaryTranscriptionBusy: model.state.isProcessing, onPrimaryTranscribe: startTranscription, onReference: openReference)
            }
            Tab("Summary", systemImage: "doc.text", value: DetailTab.summary) {
                SummaryView(recording: recording, model: summaryModel, onSeek: { playback.seek(to: $0) }, onOpenSource: openReference)
            }
            Tab("Transcript", systemImage: "text.alignleft", value: DetailTab.transcript) {
                VStack(spacing: 8) {
                    if recording.transcript != nil {
                        HStack {
                            Button("History", systemImage: "clock.arrow.circlepath") { showsTranscriptHistory = true }
                            Text(recording.transcriptHistory.isEmpty ? "1 version" : "\(recording.transcriptHistory.count + 1) versions").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Regenerate…", systemImage: "arrow.clockwise") { showsRegenerationOptions = true }
                                .disabled(!model.canRegenerate)
                                .popover(isPresented: $showsRegenerationOptions) {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text("Regenerate Transcript").font(.headline)
                                        TranscriptionProviderControls(model: model)
                                        Text(model.transcriptionEstimate.displayText).font(.caption).foregroundStyle(.secondary)
                                        Text("The current transcript will be kept in history when the new version is ready.")
                                            .font(.callout).foregroundStyle(.secondary)
                                        HStack {
                                            SettingsLink { Text("Transcription Settings…") }
                                            Spacer()
                                            Button("Regenerate") {
                                                showsRegenerationOptions = false
                                                model.startTranscription(using: SwiftDataTranscriptRepository(context: modelContext), replacingExisting: true)
                                            }.buttonStyle(.borderedProminent).disabled(!model.canRegenerate)
                                        }
                                    }.padding().frame(width: 390)
                                }
                        }.padding(.horizontal, 16)
                    }
                    TranscriptView(transcript: recording.transcript, revealedSegmentID: revealedSegmentID) { playback.seek(to: $0) }
                }
            }
        }
    }

    private func openProjectCitation() {
        guard let citation = projectCitation, let project = recording.project,
              citation.recordingID == recording.id, ProjectCitationNavigation.available(citation, project: project) else { return }
        let reference = citation.reference
        let primary = recording.sources.first(where: \.isPrimaryAudio)?.id ?? recording.id
        if reference.sourceID == primary, case .audio(let ids, let start, _) = reference.locator {
            selectedTab = .transcript
            revealedSegmentID = ids.first
            playback.seek(to: start)
        } else if let source = ProjectCitationNavigation.source(citation, project: project) {
            sourcePreview = .init(source: source, locator: reference.locator)
        }
    }

    private var transcriptionFailed: Bool {
        if case .failed = model.state { return true }
        return false
    }

    private func openReference(_ raw: SourceReference) {
        guard let reference = SourceReferenceResolver().validate([raw], recording: recording).first,
              let source = recording.sources.first(where: { $0.id == reference.sourceID }) else { return }
        if source.isPrimaryAudio, case .audio(let ids, let start, _) = reference.locator {
            selectedTab = .transcript
            revealedSegmentID = ids.first
            playback.seek(to: start)
        } else { sourcePreview = .init(source: source, locator: reference.locator) }
    }

    private func startTranscription() {
        selectedTab = .transcript
        model.startTranscription(using: SwiftDataTranscriptRepository(context: modelContext))
    }
}
