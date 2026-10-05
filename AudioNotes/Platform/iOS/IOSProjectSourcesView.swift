#if os(iOS)
import PDFKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct IOSProjectSourcesView: View {
    let project: Project
    @Bindable var queue: ProjectImportQueue
    @Environment(\.modelContext) private var context
    @State private var showingImporter = false
    @State private var preview: RecordingSource?
    @State private var previewPage = 0
    @State private var deleteTarget: RecordingSource?
    @State private var renameTarget: RecordingSource?
    @State private var rename = ""
    @State private var errorMessage: String?

    private var repository: SwiftDataProjectRepository { .init(context: context, storage: queue.storage) }
    private var jobs: [ProjectImportItem] { queue.items.filter { $0.projectID == project.id } }

    var body: some View {
        List {
            if project.sources.isEmpty && jobs.isEmpty {
                IOSCreationPrompt(title: "Add project sources", symbol: "doc.badge.plus",
                    description: "Add PDFs, images and notes so AudioNotes can use them with your recordings.") {
                    Button("Add Sources", systemImage: "plus") { showingImporter = true }
                        .accessibilityIdentifier("project.sources.emptyAdd")
                        .modifier(IOSPrimaryAction())
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                if !jobs.isEmpty {
                    Section("Import Activity") {
                        ForEach(jobs) { job in
                            HStack(spacing: 12) {
                                jobSymbol(job)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(job.filename).lineLimit(1)
                                    Text(job.statusText).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                if case .failed = job.state, let id = job.sourceID,
                                   let source = project.sources.first(where: { $0.id == id }) {
                                    Button("Retry") { queue.retry(source, in: project, context: context) }
                                        .font(.caption).accessibilityIdentifier("project.import.retry.\(id.uuidString)")
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(job.filename), \(job.statusText)")
                        }
                    }
                }
                if !project.sources.isEmpty {
                    Section("Sources") {
                        ForEach(project.sources.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }) { source in
                            HStack(spacing: 8) {
                                Button { preview = source } label: { sourceRow(source) }
                                    .buttonStyle(.plain)
                                if source.status == .failed || source.status == .partial {
                                    Button("Retry") { queue.retry(source, in: project, context: context) }
                                        .font(.caption).accessibilityIdentifier("project.source.retry.\(source.id.uuidString)")
                                        .disabled(queue.isProcessing(source.id))
                                }
                            }
                                .contextMenu { actions(for: source) }
                                .swipeActions(edge: .trailing) {
                                    if source.status == .failed || source.status == .partial {
                                        Button("Retry", systemImage: "arrow.clockwise") { queue.retry(source, in: project, context: context) }
                                            .tint(.green).disabled(queue.isProcessing(source.id))
                                    }
                                    Button("Delete", systemImage: "trash", role: .destructive) { deleteTarget = source }
                                    Button("Rename", systemImage: "pencil") { beginRename(source) }
                                        .tint(.blue)
                                }
                                .accessibilityIdentifier("project.source.\(source.id.uuidString)")
                        }
                    }
                }
            }
        }
        .navigationTitle("Sources")
        .onAppear {
#if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--ios-project-import-progress") {
                queue.prepareReviewProgress(projectID: project.id)
            }
            let wanted: RecordingSourceType? = args.contains("--ios-project-review-pdf") ? .pdf :
                (args.contains("--ios-project-review-image") ? .image :
                    (args.contains("--ios-project-review-markdown") ? .document : nil))
            if let wanted, let source = project.sources.first(where: {
                guard $0.type == wanted, $0.status == .ready || $0.status == .partial else { return false }
                return !args.contains("--ios-project-review-markdown") || ["md", "markdown"].contains(URL(fileURLWithPath: $0.originalFilename).pathExtension.lowercased())
            }) {
                preview = source
                previewPage = args.contains("--ios-project-review-pdf") ? 1 : 0
            }
#endif
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add Sources", systemImage: "plus") { showingImporter = true }
                    .accessibilityIdentifier("project.sources.add")
                    .modifier(IOSControlSurface())
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: SourceImportService.supportedTypes,
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): queue.enqueue(urls, to: project, context: context)
            case .failure: errorMessage = "The selected files could not be opened. Try downloading them in Files, then import again."
            }
        }
        .sheet(item: $preview) { source in IOSProjectSourceViewer(source: source, url: queue.storage.sourceURL(source), page: previewPage) }
        .alert("Delete Source?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Delete", role: .destructive) {
                guard let source = deleteTarget else { return }
                do { try repository.deleteSource(source, from: project) }
                catch { errorMessage = "The source could not be deleted. Nothing was removed." }
                deleteTarget = nil
            }
        } message: { Text("The managed copy and its extracted text will be removed from this project.") }
        .alert("Rename Source", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $rename)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") {
                guard let source = renameTarget else { return }
                do { try repository.renameSource(source, in: project, name: rename) }
                catch { errorMessage = "The source name could not be saved. Try again." }
                renameTarget = nil
            }.disabled(rename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("Project Sources", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder private func sourceRow(_ source: RecordingSource) -> some View {
        HStack(spacing: 12) {
            Image(systemName: source.type.icon).font(.title3).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(source.displayName).font(.body).lineLimit(2)
                Text(detail(source)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            if source.status == .processing { ProgressView().controlSize(.small).accessibilityLabel("Processing") }
            else { Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary).accessibilityHidden(true) }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(source.displayName), \(detail(source))")
    }

    private func detail(_ source: RecordingSource) -> String {
        switch source.status {
        case .processing, .imported: return source.status == .processing ? "Processing…" : "Waiting to process"
        case .failed, .unsupported:
            let reason = source.processingError ?? "This file couldn't be read. Retry processing."
            return "\(reason) · Retry available"
        case .ready, .partial:
            switch source.type {
            case .pdf:
                if case .pdf(let pages, _) = source.metadata { return "PDF · \(pages) pages" }
                return "PDF · Pages processed"
            case .image: return source.textUnits.isEmpty ? "Image · OCR complete, no text found" : "Image · OCR complete"
            case .document:
                let ext = URL(fileURLWithPath: source.originalFilename).pathExtension.lowercased()
                let title = ["md", "markdown"].contains(ext) ? "Markdown" : "Text"
                let bytes = (try? FileManager.default.attributesOfItem(atPath: queue.storage.sourceURL(source).path)[.size] as? NSNumber)?.intValue ?? 0
                return "\(title) · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
            case .audio: return "Audio source"
            }
        }
    }

    @ViewBuilder private func jobSymbol(_ job: ProjectImportItem) -> some View {
        switch job.state {
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .importing, .processing: ProgressView().controlSize(.small)
        case .added: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func actions(for source: RecordingSource) -> some View {
        Button("Open", systemImage: "arrow.up.right.square") { preview = source }
        Button("Rename", systemImage: "pencil") { beginRename(source) }
        if source.status == .failed || source.status == .partial {
            Button("Retry Processing", systemImage: "arrow.clockwise") { queue.retry(source, in: project, context: context) }
                .disabled(queue.isProcessing(source.id))
        }
        Button("Delete", systemImage: "trash", role: .destructive) { deleteTarget = source }
    }

    private func beginRename(_ source: RecordingSource) { rename = source.displayName; renameTarget = source }
}

struct IOSProjectSourceViewer: View {
    let source: RecordingSource
    let url: URL
    var page: Int = 0
    @Environment(\.dismiss) private var dismiss
    @State private var image: CGImage?
    @State private var imageUnavailable = false
    @State private var pdfReadable: Bool?
    private let imageLoader = SourceImageLoader()

    var body: some View {
        NavigationStack {
            Group {
                switch source.type {
                case .pdf:
                    if pdfReadable == false {
                        ContentUnavailableView("PDF unavailable", systemImage: "doc.questionmark",
                            description: Text("The PDF couldn't be read. Retry processing or import an unlocked copy."))
                    } else if pdfReadable == true { IOSPDFSourceView(url: url, page: page) }
                    else { ProgressView("Opening PDF…") }
                case .image:
                    if let image { Image(decorative: image, scale: 1).resizable().scaledToFit().padding() }
                    else if imageUnavailable { ContentUnavailableView("Image unavailable", systemImage: "photo", description: Text("Text couldn't be extracted from this image. Retry processing or import another copy.")) }
                    else { ProgressView("Opening image…") }
                case .document:
                    if source.textUnits.isEmpty {
                        ContentUnavailableView("No readable text", systemImage: "doc.text.magnifyingglass",
                            description: Text("This file couldn't be imported. Retry processing or choose a UTF-8/UTF-16 text file."))
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(source.textUnits.sorted { $0.position < $1.position }) { unit in
                                    if ["md", "markdown"].contains(url.pathExtension.lowercased()) {
                                        MarkdownSourceUnit(text: unit.text)
                                    } else {
                                        Text(unit.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }.frame(maxWidth: 760).padding()
                        }
                    }
                case .audio:
                    ContentUnavailableView("Audio Source", systemImage: "waveform", description: Text("Open this item from Recordings."))
                }
            }
            .navigationTitle(source.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .task(id: url) {
            switch source.type {
            case .pdf:
                let exists = await Task.detached { PDFDocument(url: url) != nil }.value
                guard !Task.isCancelled else { return }
                pdfReadable = exists
            case .image:
                let loaded = await imageLoader.image(url: url, maximumDimension: 2400)
                guard !Task.isCancelled else { return }
                image = loaded
                imageUnavailable = loaded == nil
            case .document, .audio: break
            }
        }
        .accessibilityIdentifier("project.sourceViewer")
    }
}

private struct MarkdownSourceUnit: View {
    let text: String
    @State private var document = MarkdownDocument("")
    var body: some View {
        MarkdownMessageView(document: document).equatable().textSelection(.enabled)
            .task(id: text) {
                let worker = Task.detached { MarkdownDocument(text) }
                let parsed = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled else { return }
                document = parsed
            }
    }
}

private struct IOSPDFSourceView: UIViewRepresentable {
    let url: URL
    let page: Int

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .secondarySystemBackground
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        // Avoid resetting PDFKit's scroll position on unrelated SwiftUI updates.
        if context.coordinator.url != url {
            context.coordinator.url = url
            view.document = PDFDocument(url: url)
        }
        if context.coordinator.page != page {
            context.coordinator.page = page
            if let document = view.document, document.pageCount > 0 {
                view.go(to: document.page(at: min(max(page, 0), document.pageCount - 1))!)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url, page: Int.min) }
    final class Coordinator { var url: URL; var page: Int; init(url: URL, page: Int) { self.url = url; self.page = page } }
}
#endif
