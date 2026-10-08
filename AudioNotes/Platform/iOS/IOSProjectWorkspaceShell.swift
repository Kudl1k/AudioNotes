#if os(iOS)
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct IOSProjectWorkspaceShell: View {
    let project: Project
    let services: AppServices
    @Environment(IOSAudioImportModel.self) private var imports
    @Environment(\.modelContext) private var context
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var section: Section = .recordings
    @State private var showingImporter = false
    @State private var importerTypes = SourceImportService.supportedTypes

    private enum Section: String, CaseIterable, Identifiable {
        case recordings = "Recordings", sources = "Sources", chat = "Chat"
        var id: String { rawValue }
        var symbol: String { switch self { case .recordings: "waveform"; case .sources: "doc.text"; case .chat: "bubble.left.and.bubble.right" } }
    }

    var body: some View {
        VStack(spacing: 0) {
            sectionPicker
            .padding(.horizontal, 16).padding(.vertical, 8)
            .accessibilityIdentifier("project.sections")

            Group {
                switch section {
                case .recordings: recordings
                case .sources: IOSProjectSourcesView(project: project, queue: imports.library.projectImports)
                case .chat: IOSProjectChatView(project: project, services: services, library: imports.library)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
#if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--ios-project-review-sources") { section = .sources }
            if args.contains("--ios-project-review-chat") { section = .chat }
#endif
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if section != .sources {
                Menu {
                    Button("Add Sources", systemImage: "doc.badge.plus") { openImporter(SourceImportService.supportedTypes) }
                        .accessibilityIdentifier("project.addSources")
                    Button("Add Recordings", systemImage: "waveform.badge.plus") { openImporter([.audio]) }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add to Project")
                .accessibilityIdentifier("project.add")
                .modifier(IOSControlSurface())
                }
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: importerTypes,
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): imports.library.projectImports.enqueue(urls, to: project, context: context)
            case .failure: imports.resultMessage = "The selected files could not be opened. Try downloading them in Files, then import again."
            }
        }
        .safeAreaInset(edge: .bottom) {
            let active = imports.library.projectImports.items.filter { $0.projectID == project.id && $0.isActive }
            if let item = active.first {
                let batch = imports.library.projectImports.items.filter { $0.projectID == project.id }
                let ordinal = (batch.firstIndex(where: { $0.id == item.id }) ?? 0) + 1
                let title = "Importing \(ordinal) of \(batch.count) · \(item.filename)"
                let status = if case .failed = item.state { "This file couldn't be imported. Retry from Sources." } else { item.statusText }
                OperationProgressView(title: title,
                    status: status,
                    progress: OperationProgressValue(completed: item.progress?.completed, total: item.progress?.total),
                    startedAt: item.startedAt,
                    cancel: { imports.library.projectImports.cancelRemaining(for: project.id) }, canCancel: true)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.regularMaterial)
                    .accessibilityIdentifier("project.importProgress")
            }
        }
        .alert("Project Import", isPresented: Binding(get: { imports.resultMessage != nil }, set: { if !$0 { imports.resultMessage = nil } })) {
            Button("OK") { imports.resultMessage = nil }
        } message: { Text(imports.resultMessage ?? "") }
    }

    private var recordings: some View {
        List {
            if let description = project.projectDescription, !description.isEmpty {
                Text(description).font(.subheadline).foregroundStyle(.secondary)
            }
            if project.recordings.isEmpty {
                ContentUnavailableView {
                    Label("No Recordings", systemImage: "waveform")
                } description: {
                    Text("Add recordings to use their transcripts in Project Chat.")
                } actions: {
                    Button("Add Recordings", systemImage: "plus") { openImporter([.audio]) }
                        .accessibilityIdentifier("project.addRecordings.empty")
                }
            } else {
                ForEach(project.recordings.sorted { $0.importedAt > $1.importedAt }) { recording in
                    NavigationLink {
                        IOSRecordingDetailShell(recording: recording, services: services,
                            transcriptionModel: imports.library.transcriptionModel(for: recording, resolver: IOSFeatureProviders.transcription(services)),
                            summaryModel: imports.library.summaryModel(for: recording, resolver: IOSFeatureProviders.llm(services)),
                            chatModel: imports.library.chatModel(for: recording, resolver: IOSFeatureProviders.llm(services)))
                    } label: { IOSRecordingRow(recording: recording) }
                    .modifier(IOSRecordingActions(recording: recording))
                }
            }
        }
        .accessibilityIdentifier("project.recordings")
    }

    private func openImporter(_ types: [UTType]) {
        importerTypes = types
        showingImporter = true
    }

    @ViewBuilder private var sectionPicker: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Picker("Project area", selection: $section) {
                ForEach(Section.allCases) { value in Label(value.rawValue, systemImage: value.symbol).tag(value) }
            }.pickerStyle(.menu)
        } else {
            Picker("Project area", selection: $section) {
                ForEach(Section.allCases) { value in Label(value.rawValue, systemImage: value.symbol).tag(value) }
            }.pickerStyle(.segmented)
        }
    }
}
#endif
