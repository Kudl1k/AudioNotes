import SwiftData
import SwiftUI

struct ProjectWorkspaceView: View {
    let project: Project
    let projects: [Project]
    @Bindable var queue: ProjectImportQueue
    let library: LibraryViewModel
    let llmResolver: any LLMProviderResolving
    let openRecording: (UUID) -> Void
    let moveRecordingIDs: ([UUID], Project) -> Void
    let importFiles: () -> Void
    @Environment(\.modelContext) private var context
    @State private var tab = WorkspaceTab.overview
    @State private var query = ""
    @State private var preview: SourcePreviewTarget?
    @State private var exporting: Recording?
    @State private var model = ProjectWorkspaceViewModel()
    @State private var showsActivity = false
    @State private var recordingDropTargeted = false
    private enum WorkspaceTab: Hashable { case overview, recordings, sources, chat }

    // These paths read metadata only. They never construct chunks or read transcript segments/chat.
    private var recordings: [Recording] {
        project.recordings.filter { query.isEmpty || $0.title.localizedStandardContains(query) }
            .sorted { $0.importedAt == $1.importedAt ? $0.id.uuidString < $1.id.uuidString : $0.importedAt > $1.importedAt }
    }
    private var sources: [RecordingSource] {
        project.sources.filter { query.isEmpty || $0.displayName.localizedStandardContains(query) || $0.originalFilename.localizedStandardContains(query) }
            .sorted { $0.importedAt == $1.importedAt ? $0.id.uuidString < $1.id.uuidString : $0.importedAt > $1.importedAt }
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: WorkspaceSpacing.section) {
                VStack(alignment: .leading, spacing: WorkspaceSpacing.compact) {
                    Text(project.name).font(.title.bold()).textSelection(.enabled)
                        .lineLimit(2).truncationMode(.tail).help(project.name)
                    Text("^[\(project.recordings.count) recording](inflect: true) · ^[\(project.sources.count) source](inflect: true)")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let description = project.projectDescription {
                        Text(description).font(.subheadline).foregroundStyle(.secondary)
                            .lineLimit(2).textSelection(.enabled).help(description)
                    }
                }
                // Title, counts and description are read as one project summary.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.headerLabel(name: project.name, recordings: project.recordings.count,
                    sources: project.sources.count, description: project.projectDescription))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("project.header")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: WorkspaceSpacing.section) {
                        sectionPicker
                        Spacer(minLength: WorkspaceSpacing.section)
                        if tab != .chat { searchField.frame(width: 230) }
                    }
                    VStack(alignment: .leading, spacing: WorkspaceSpacing.standard) {
                        sectionPicker
                        if tab != .chat { searchField }
                    }
                }
            }
            .padding(WorkspaceSpacing.majorSection)
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Divider()
            Group {
                if tab == .chat {
                    ProjectChatView(model: library.projectChatModel(for: project, resolver: llmResolver), library: library)
                } else if project.recordings.isEmpty && project.sources.isEmpty {
                    ContentUnavailableView {
                        Label("This project is empty", systemImage: "folder")
                    } description: {
                        Text("Add recordings, PDFs, documents, images and notes. You can also drop files here.")
                    } actions: { Button("Import Files…", action: importFiles) }
                } else if tab != .chat && tabIsEmpty {
                    emptyTabState
                } else {
                    List {
                        switch tab {
                        case .overview:
                            if !recordings.isEmpty { Section("Recent Recordings") { ForEach(Array(recordings.prefix(8))) { recordingRow($0) } } }
                            if !sources.isEmpty { Section("Recent Sources · Shared with this project") { ForEach(Array(sources.prefix(8))) { sourceRow($0) } } }
                            let active = queue.items.filter { $0.projectID == project.id && $0.isActive }
                            if !active.isEmpty {
                                Section("Processing") {
                                    ForEach(active) { item in
                                        projectImportProgress(item)
                                    }
                                }
                            }
                            let operations = library.activeOperations.filter { activity in project.recordings.contains { $0.id == activity.recordingID } }
                            if !operations.isEmpty {
                                Section("Recording Activity") {
                                    ForEach(operations) { activity in Button(activity.title) { openRecording(activity.recordingID) } }
                                }
                            }
                        case .recordings: ForEach(recordings) { recordingRow($0) }
                        case .chat: EmptyView()
                        case .sources:
                            Section("Shared with this project") { ForEach(sources) { sourceRow($0) } }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)

        }
        .dropDestination(for: RecordingDragItem.self) { items, _ in
            let ids = Array(Set(items.map(\.recordingID)))
            guard !ids.isEmpty else { return false }
            moveRecordingIDs(ids, project)
            return true
        } isTargeted: { recordingDropTargeted = $0 }
        .overlay {
            if recordingDropTargeted {
                RoundedRectangle(cornerRadius: 10).strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(6).allowsHitTesting(false)
            }
        }
        .onAppear { if library.projectChatTabs.contains(project.id) { tab = .chat } }
        .onChange(of: tab) { _, value in
            if value == .chat { library.projectChatTabs.insert(project.id) }
            else { library.projectChatTabs.remove(project.id) }
        }
        .safeAreaInset(edge: .bottom) {
            let items = queue.items.filter { $0.projectID == project.id }
            if !items.isEmpty {
                HStack {
                    Text("\(items.filter { $0.state == .added }.count) of \(items.count) items added").font(.caption)
                    if items.contains(where: { if case .failed = $0.state { true } else { false } }) {
                        Label("Some items could not be added", systemImage: "exclamationmark.triangle").font(.caption)
                    }
                    Spacer()
                    Button("Import Activity…") { showsActivity = true }
                    if queue.hasJobs(for: project.id) { Button("Cancel Remaining") { queue.cancelRemaining(for: project.id) } }
                }.padding(12).background(.bar)
            }
        }
        .toolbar {
            ToolbarItem { Button("Import Activity", systemImage: "list.bullet") { showsActivity.toggle() }
                .popover(isPresented: $showsActivity) { ProjectImportActivityView(projectID: project.id, queue: queue) } }
        }
        .sheet(item: $exporting) { ExportSheetView(recording: $0) }
        .sheet(item: $preview) { SourcePreviewView(target: $0, url: queue.storage.sourceURL($0.source)) }
        .alert(promptTitle, isPresented: Binding(get: { model.prompt != nil }, set: { if !$0 { model.prompt = nil } }),
               presenting: model.prompt) { prompt in
            promptActions(prompt)
        } message: { prompt in
            promptMessage(prompt)
        }
        .alert("Project could not be updated", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    static func headerLabel(name: String, recordings: Int, sources: Int, description: String?) -> String {
        ["\(name)", "\(recordings) \(recordings == 1 ? "recording" : "recordings"), \(sources) \(sources == 1 ? "source" : "sources")", description].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ". ")
    }

    private var sectionPicker: some View {
        Picker("Project section", selection: $tab) {
            Text("Overview").tag(WorkspaceTab.overview)
            Text("Recordings").tag(WorkspaceTab.recordings)
            Text("Sources").tag(WorkspaceTab.sources)
            Text("Chat").tag(WorkspaceTab.chat)
        }
        .pickerStyle(.segmented).labelsHidden()
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityIdentifier("project.tabs")
    }

    private var searchField: some View {
        TextField("Filter titles and filenames", text: $query)
            .textFieldStyle(.roundedBorder).accessibilityLabel("Filter project titles and filenames")
            .accessibilityIdentifier("project.search")
    }

    @ViewBuilder private func projectImportProgress(_ item: ProjectImportItem) -> some View {
        if item.state == .waiting {
            Label(item.filename + " · Waiting", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
        } else {
            OperationProgressView(title: item.filename, status: item.statusText,
                progress: OperationProgressValue(completed: item.progress?.completed, total: item.progress?.total),
                startedAt: item.startedAt)
        }
    }

    private var projectRepository: SwiftDataProjectRepository {
        SwiftDataProjectRepository(context: context, storage: queue.storage)
    }

    private var promptTitle: String {
        switch model.prompt {
        case .deleteRecording: "Delete Recording?"
        case .deleteSource: "Delete Project Source?"
        case .renameSource: "Rename Source"
        case nil: ""
        }
    }

    @ViewBuilder private func promptActions(_ prompt: ProjectWorkspaceViewModel.Prompt) -> some View {
        switch prompt {
        case .deleteRecording(let recording):
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                model.confirmDelete(recording, library: library, using: SwiftDataRecordingRepository(context: context, storage: queue.storage))
            }
        case .deleteSource(let source):
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { model.confirmDelete(source, from: project, using: projectRepository) }
        case .renameSource(let source):
            TextField("Name", text: $model.sourceName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { model.confirmRename(source, in: project, using: projectRepository) }
                .disabled(model.sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder private func promptMessage(_ prompt: ProjectWorkspaceViewModel.Prompt) -> some View {
        switch prompt {
        case .deleteRecording: Text("This recording and its managed files, transcript, summaries, chats and history will be permanently deleted. Project sources and your original files remain.")
        case .deleteSource: Text("The managed copy and extracted text will be removed. Your original file remains on your Mac.")
        case .renameSource: EmptyView()
        }
    }

    /// A tab with nothing to show: either the filter excludes everything, or this kind of content is absent.
    private var tabIsEmpty: Bool {
        switch tab {
        case .overview: recordings.isEmpty && sources.isEmpty
        case .recordings: recordings.isEmpty
        case .sources: sources.isEmpty
        case .chat: false
        }
    }

    @ViewBuilder private var emptyTabState: some View {
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if tab == .recordings {
            ContentUnavailableView {
                Label("No recordings in this project", systemImage: "waveform")
            } description: {
                Text("Import audio here, or drag a recording from the library onto this project.")
            } actions: { Button("Import Files…", action: importFiles).accessibilityIdentifier("project.import") }
        } else {
            ContentUnavailableView {
                Label("No shared sources", systemImage: "doc.on.doc")
            } description: {
                Text("Add PDFs, documents, images and notes that every recording in this project can use.")
            } actions: { Button("Import Files…", action: importFiles).accessibilityIdentifier("project.import") }
        }
    }

    private func recordingRow(_ recording: Recording) -> some View {
        Button { openRecording(recording.id) } label: {
            HStack {
                Image(systemName: "waveform").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(recording.title).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle).help(recording.title)
                    Text(AudioTime.string(recording.duration) + " · " + recordingStatus(recording)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(recording.importedAt, format: .dateTime.month(.abbreviated).day()).font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(.plain)
        .accessibilityElement(children: .combine).accessibilityHint("Opens the recording")
        .accessibilityIdentifier("project.recording.\(recording.id.uuidString)")
        .contextMenu {
            Button("Open") { openRecording(recording.id) }
            RecordingProjectMenu(recording: recording, projects: projects) { model.move(recording, to: $0, using: projectRepository) }
            Button("Export…") { exporting = recording }
            Button("Delete…", role: .destructive) { model.requestDelete(recording) }.disabled(!library.canDelete(recording))
        }
    }
    private func recordingStatus(_ recording: Recording) -> String {
        if library.activeTranscriptionModel(for: recording) != nil { return "Transcribing" }
        return recording.transcript == nil ? "Ready to transcribe" : "Transcribed"
    }
    private func sourceRow(_ source: RecordingSource) -> some View {
        HStack(spacing: 12) {
            SourceThumbnailView(url: queue.storage.sourceDirectory(id: source.id).appending(path: "thumbnail.jpg"),
                revision: source.statusRaw, icon: source.type.icon, loader: queue.imageLoader)
                .frame(width: 36, height: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(source.displayName).lineLimit(1)
                Text(sourceDescription(source)).font(.caption).foregroundStyle(.secondary)
                if let item = queue.items.last(where: { $0.sourceID == source.id && $0.isActive }) {
                    projectImportProgress(item)
                } else if let problem = source.processingError { Text(problem).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer()
            Button("Open") { preview = .init(source: source) }
                .accessibilityLabel("Open \(source.displayName)")
            if source.status == .failed || source.status == .partial {
                Button("Retry") { queue.retry(source, in: project, context: context) }.disabled(queue.isProcessing(source.id))
                    .accessibilityLabel("Retry \(source.displayName)")
            }
        }.padding(.vertical, 4).accessibilityElement(children: .contain)
        .accessibilityIdentifier("project.source.\(source.id.uuidString)")
        .contextMenu {
            Button("Open") { preview = .init(source: source) }
            Button("Rename…") { model.requestRename(source) }
            Button("Retry") { queue.retry(source, in: project, context: context) }.disabled(queue.isProcessing(source.id))
            Button("Show in Finder") { Workspace.revealInFinder([queue.storage.sourceURL(source)]) }
            Button("Delete…", role: .destructive) { model.requestDelete(source) }.disabled(queue.isProcessing(source.id))
        }
    }
    private func sourceDescription(_ source: RecordingSource) -> String {
        let kind: String
        switch source.type {
        case .pdf:
            if case .pdf(let count, _) = source.metadata { kind = "PDF · \(count) \(count == 1 ? "page" : "pages")" } else { kind = "PDF" }
        case .image: kind = "Image"
        case .document: kind = "Text / Markdown"
        case .audio: kind = "Audio"
        }
        let status: String
        switch source.status {
        case .ready: status = source.type == .image ? "OCR complete" : "Ready"
        case .partial: status = "Ready with warnings"
        case .failed: status = "Failed"
        case .processing: status = "Processing"
        case .imported: status = "Waiting"
        case .unsupported: status = "Unsupported"
        }
        return kind + " · " + status
    }
}
