#if os(macOS)
import SwiftData
import SwiftUI

struct RecordingDetailView: View {
    let recording: Recording
    private let projectCitation: ProjectCitation?
    private let projects: [Project]
    private let openProject: (() -> Void)?
    private let moveToProject: (Project?) -> Void
    private let renameRecording: (() -> Void)?
    private let transcriptionResolver: any TranscriptionProviderResolving
    @State private var showsSharing = false
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
    @State private var detailFitsChat = true

    private enum DetailTab: Hashable { case summary, transcript, sources }

    /// Inspector ideal width (350) plus the narrowest detail content that still lays out (about 280), with margin.
    nonisolated static let minimumDetailWidthForChat: CGFloat = 640

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
        moveToProject: @escaping (Project?) -> Void = { _ in },
        renameRecording: (() -> Void)? = nil
    ) {
        self.projectCitation = projectCitation
        self.projects = projects
        self.openProject = openProject
        self.moveToProject = moveToProject
        self.renameRecording = renameRecording
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

    private var shareRecordingAction: (() -> Void)? {
        guard recording.transcript?.segments.isEmpty == false else { return nil }
        return { showsSharing = true }
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
                        .frame(height: max(240, geometry.size.height - headerHeight))
                }
            }
        }
        // Opening the inspector while the detail pane cannot fit beside it makes AppKit's constraint pass loop
        // until it aborts. The width is observed while the inspector is closed, so the toggle is simply unavailable.
        .onGeometryChange(for: Bool.self) { $0.size.width >= Self.minimumDetailWidthForChat } action: { detailFitsChat = $0 }
        .sheet(isPresented: $showsTranscriptHistory) {
            TranscriptHistoryView(recording: recording, isProcessing: model.state.isProcessing) { playback.seek(to: $0) }
        }
        .sheet(isPresented: $showsUsage) { UsageCostView(recordingID: recording.id) }
        .sheet(isPresented: $showsSharing) { RecordingSharingSheet(recording: recording, storage: storage) }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button {
                    showingExportSheet = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Export")
                    }
                }
                .help("Export as Markdown or PDF (⌘E)")
                .accessibilityLabel("Export")
                .accessibilityIdentifier("toolbar.export")

                Menu {
                    if let renameRecording {
                        Button("Rename…", systemImage: "pencil", action: renameRecording)
                        Divider()
                    }
                    Section("Project") {
                        RecordingProjectMenu(recording: recording, projects: projects, move: moveToProject)
                    }
                    Section {
                        if shareRecordingAction != nil {
                            Button("Share Recording…", systemImage: "person.2") {
                                showsSharing = true
                            }
                        }
                        if recording.transcript != nil {
                            Button("Transcript History…", systemImage: "clock.arrow.circlepath") {
                                showsTranscriptHistory = true
                            }
                        }
                        Button("Usage & Cost…", systemImage: "dollarsign.circle") {
                            showsUsage = true
                        }
                        .accessibilityIdentifier("toolbar.usage")
                    }
                } label: {
                    Label("More Actions", systemImage: "ellipsis.circle")
                }
                .help("Rename, project, sharing, history, and usage")
                .accessibilityIdentifier("toolbar.more")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsChat.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showsChat ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                        Text("Chat")
                    }
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(!showsChat && !detailFitsChat)
                .help(showsChat ? "Hide AI Chat (⌥⌘C)" : detailFitsChat ? "Show AI Chat (⌥⌘C)" : "Make the window wider or hide the sidebar to show chat")
                .accessibilityLabel("Chat")
                .accessibilityValue(showsChat ? "Shown" : "Hidden")
                .accessibilityIdentifier("toolbar.chat")
            }
        }
        .focusedSceneValue(\.shareRecording, shareRecordingAction)
        .focusedSceneValue(\.exportAction) {
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
            VStack(alignment: .leading, spacing: WorkspaceSpacing.section) {
                VStack(alignment: .leading, spacing: WorkspaceSpacing.standard) {
                    Text(recording.title)
                        .font(.title.bold())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(recording.title)
                        .accessibilityAddTraits(.isHeader)

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            projectBadgeMenu
                            metadataItems
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            projectBadgeMenu
                            HStack(spacing: 8) {
                                metadataItems
                            }
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                if !recording.audioFileName.isEmpty {
                    PlaybackControls(playback: playback)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(WorkspaceSpacing.majorSection)
            .layoutPriority(1)
            Divider()
            if !recording.audioFileName.isEmpty && showsTranscriptionStatus {
                TranscriptionControls(
                    model: model,
                    transcribe: startTranscription,
                    regenerate: { selectedTab = .transcript; showsRegenerationOptions = true }
                )
                .padding(WorkspaceSpacing.majorSection)
                Divider()
            }
        }
    }

    @ViewBuilder
    private var projectBadgeMenu: some View {
        if let project = recording.project {
            Menu {
                if let openProject {
                    Button("Open Project “\(project.name)”", systemImage: "arrow.up.forward.square", action: openProject)
                    Divider()
                }
                if !projects.isEmpty {
                    Section("Move to Project") {
                        ForEach(projects) { candidate in
                            Button {
                                moveToProject(candidate)
                            } label: {
                                if candidate.id == project.id {
                                    Label(candidate.name, systemImage: "checkmark")
                                } else {
                                    Text(candidate.name)
                                }
                            }
                        }
                    }
                    Divider()
                }
                Button("Remove from Project", systemImage: "folder.badge.minus", role: .destructive) {
                    moveToProject(nil)
                }
            } label: {
                Label(project.name, systemImage: "folder.fill")
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Project \(project.name)")
            .accessibilityIdentifier("recording.project")
        } else if !projects.isEmpty {
            Menu {
                Section("Add to Project") {
                    ForEach(projects) { candidate in
                        Button(candidate.name, systemImage: "folder") {
                            moveToProject(candidate)
                        }
                    }
                }
            } label: {
                Label("Add to Project", systemImage: "folder.badge.plus")
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("recording.project")
        }
    }

    @ViewBuilder
    private var metadataItems: some View {
        Text(recording.importedAt.formatted(date: .abbreviated, time: .shortened))
        Text("·").accessibilityHidden(true)
        Button("^[\(recording.sources.count) source](inflect: true)") {
            selectedTab = .sources
        }
        .buttonStyle(.link)
        .accessibilityHint("Shows the Sources tab")
        TranscriptionCostInlineLabel(recordingID: recording.id)
    }

    private var sectionPicker: some View {
        Picker("Section", selection: $selectedTab) {
            Text("Sources").tag(DetailTab.sources)
            Text("Summary").tag(DetailTab.summary)
            Text("Transcript").tag(DetailTab.transcript)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityIdentifier("recording.tabs")
    }

    private var recordingTabs: some View {
        VStack(spacing: 0) {
            sectionPicker
                .padding(.horizontal, WorkspaceSpacing.majorSection)
                .padding(.top, WorkspaceSpacing.section)
                .padding(.bottom, WorkspaceSpacing.standard)

            Group {
                switch selectedTab {
                case .sources:
                    SourcesView(model: sourcesModel, transcriptionResolver: transcriptionResolver, transcriptionModel: model,
                        primaryTranscriptionBusy: model.state.isProcessing, onPrimaryTranscribe: startTranscription, onReference: openReference)
                case .summary:
                    SummaryView(recording: recording, model: summaryModel, onSeek: { playback.seek(to: $0) }, onOpenSource: openReference)
                case .transcript:
                    transcriptTab
                }
            }
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
    }

    private var transcriptTab: some View {
        VStack(spacing: WorkspaceSpacing.standard) {
            if recording.transcript != nil {
                HStack {
                    Button("History", systemImage: "clock.arrow.circlepath") { showsTranscriptHistory = true }
                    Text(recording.transcriptHistory.isEmpty ? "1 version" : "\(recording.transcriptHistory.count + 1) versions")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Regenerate…", systemImage: "arrow.clockwise") { showsRegenerationOptions = true }
                        .disabled(!model.canRegenerate)
                        .popover(isPresented: $showsRegenerationOptions) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Regenerate Transcript").font(.headline)
                                TranscriptionOptionsForm(model: model)
                                Text("The current transcript will be kept in history when the new version is ready.")
                                    .font(.callout).foregroundStyle(.secondary)
                                HStack {
                                    OpenSettingsLink(section: .transcription) { Text("Transcription Settings…") }
                                    Spacer()
                                    Button("Regenerate") {
                                        showsRegenerationOptions = false
                                        model.startTranscription(using: SwiftDataTranscriptRepository(context: modelContext), replacingExisting: true)
                                    }.buttonStyle(.borderedProminent).disabled(!model.canRegenerate)
                                }
                            }.padding(16).frame(width: 420)
                        }
                }
                .padding(.horizontal, WorkspaceSpacing.majorSection)
                .padding(.top, WorkspaceSpacing.compact)
            }
            if recording.transcript == nil && !recording.audioFileName.isEmpty {
                if showsTranscriptionStatus {
                    Spacer()
                } else {
                    transcriptionEmptyState
                }
            } else {
                TranscriptView(transcript: recording.transcript, revealedSegmentID: revealedSegmentID) { playback.seek(to: $0) }
            }
        }
    }

    private var transcriptionEmptyState: some View {
        ContentUnavailableView {
            Label("No transcript yet", systemImage: "text.alignleft")
        } description: {
            VStack(spacing: 4) {
                Text(model.transcriptionConfiguration)
                Text(model.transcriptionEstimate.displayText)
                if model.hasCheckpoint {
                    Text("Completed parts from an earlier transcription are saved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } actions: {
            HStack {
                TranscriptionOptionsButton(model: model)
                if model.hasCheckpoint {
                    Button("Reset", action: model.resetTranscription)
                        .help("Clear saved progress and start from the beginning")
                        .accessibilityIdentifier("transcription.reset")
                }
                Button(model.hasCheckpoint ? "Resume" : (model.state == .idle ? "Transcribe" : "Retry"), action: startTranscription)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canTranscribe)
                    .accessibilityIdentifier(model.state == .idle ? "transcription.start" : "transcription.retry")
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

    private var showsTranscriptionStatus: Bool {
        switch model.state {
        case .failed, .cancelled:
            return true
        default:
            return model.showsCompletion || model.state.isProcessing || model.errorDetails != nil
        }
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

#endif
