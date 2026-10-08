import Foundation
import Observation
import SwiftData

struct ProjectImportItem: Identifiable {
    enum State: Equatable { case waiting, importing, processing, added, failed(String), cancelled }
    let id: UUID
    let projectID: UUID
    let filename: String
    var state: State = .waiting
    var sourceID: UUID?
    var progress: SourceProcessingProgress?
    var startedAt: Date?
    var statusText: String {
        switch state {
        case .waiting: "Waiting"
        case .importing: "Preparing managed copy"
        case .processing:
            if let progress { "\(progress.phase) · \(progress.completed) / \(progress.total)" } else { "Processing locally" }
        case .added: "Added"
        case .failed(let reason): reason
        case .cancelled: "Cancelled"
        }
    }
    var isActive: Bool { state == .waiting || state == .importing || state == .processing }
}

/// Library-owned serial worker bounds file copies and PDF/OCR work across projects.
/// URLs and retry jobs stay in memory; completed extraction is persisted by the common M9 pipeline.
@MainActor
@Observable
final class ProjectImportQueue {
    private(set) var items: [ProjectImportItem] = []
    @ObservationIgnored private var pending: [Job] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var currentTask: Task<Void, Never>?
    @ObservationIgnored private var currentURL: URL?
    @ObservationIgnored private var closingProjects: Set<UUID> = []
    @ObservationIgnored private var currentProjectID: UUID?
    @ObservationIgnored private let audioImporter: any AudioImporting
    @ObservationIgnored private let sourceImporter: any SourceImporting
    @ObservationIgnored private let processor: any SourceProcessing
    let storage: LibraryStorage
    let imageLoader: SourceImageLoader

    private struct Job {
        let id: UUID
        let project: Project
        let context: ModelContext
        let url: URL?
        let source: RecordingSource?
    }

    init(storage: LibraryStorage = LibraryStorage(), audioImporter: (any AudioImporting)? = nil,
         sourceImporter: (any SourceImporting)? = nil, processor: any SourceProcessing = NativeSourceProcessingService(),
         imageLoader: SourceImageLoader = SourceImageLoader()) {
        self.storage = storage
        self.audioImporter = audioImporter ?? AudioImportService(storage: storage)
        self.sourceImporter = sourceImporter ?? SourceImportService(storage: storage)
        self.processor = processor
        self.imageLoader = imageLoader
    }

    func enqueue(_ urls: [URL], to project: Project, context: ModelContext) {
        guard !closingProjects.contains(project.id), !project.isDeleted else { return }
        // Coalesce repeated native drop events only while the same URL is queued/active.
        for url in urls where !(currentProjectID == project.id && currentURL == url) && !pending.contains(where: { $0.project.id == project.id && $0.url == url }) {
            let id = UUID()
            items.append(.init(id: id, projectID: project.id, filename: url.lastPathComponent))
            pending.append(.init(id: id, project: project, context: context, url: url, source: nil))
        }
        start()
    }

    func retry(_ source: RecordingSource, in project: Project, context: ModelContext) {
        guard !closingProjects.contains(project.id), !project.isDeleted, source.project?.id == project.id, source.recording == nil, source.type != .audio,
              !isProcessing(source.id), source.status != .processing else { return }
        let id = UUID()
        items.append(.init(id: id, projectID: project.id, filename: source.displayName, sourceID: source.id))
        pending.append(.init(id: id, project: project, context: context, url: nil, source: source))
        start()
    }

    func isProcessing(_ sourceID: UUID) -> Bool { items.contains { $0.sourceID == sourceID && $0.isActive } }
    func hasJobs(for projectID: UUID) -> Bool { items.contains { $0.projectID == projectID && $0.isActive } }
    func cancelRemaining(for projectID: UUID) {
        let ids = Set(pending.filter { $0.project.id == projectID }.map(\.id))
        pending.removeAll { $0.project.id == projectID }
        for index in items.indices where ids.contains(items[index].id) { items[index].state = .cancelled }
        if currentProjectID == projectID { currentTask?.cancel() }
    }
    func cancelAndWait(for projectID: UUID) async {
        closingProjects.insert(projectID)
        cancelRemaining(for: projectID)
        if currentProjectID == projectID { await currentTask?.value }
    }
    func endDeletion(for projectID: UUID) { closingProjects.remove(projectID) }
    func waitUntilIdle() async { await worker?.value }
    func clearFinished(for projectID: UUID) { items.removeAll { $0.projectID == projectID && !$0.isActive } }

#if DEBUG
    /// Static offline import-progress presentation. Never starts copies or processing work.
    func prepareReviewProgress(projectID: UUID) {
        items.removeAll { $0.projectID == projectID }
        items += (0..<7).map { index in
            var item = ProjectImportItem(id: UUID(), projectID: projectID,
                filename: ["lecture.pdf", "whiteboard.png", "notes.md", "assignment.pdf", "corrupted.pdf", "glossary.md", "diagram.png"][index])
            item.startedAt = .now
            switch index {
            case 0: item.state = .added
            case 1: item.state = .processing
            case 2: item.state = .waiting
            case 3: item.state = .added
            case 4: item.state = .failed(SourceImportError.invalidFile.localizedDescription)
            default: item.state = .waiting
            }
            return item
        }
    }
#endif

    private func start() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            defer { self.worker = nil; self.currentTask = nil; self.currentProjectID = nil }
            while !self.pending.isEmpty {
                let job = self.pending.removeFirst()
                self.currentProjectID = job.project.id
                self.currentURL = job.url
                let task = Task { await self.run(job) }
                self.currentTask = task
                await task.value
                self.currentTask = nil
                self.currentURL = nil
                self.currentProjectID = nil
            }
        }
    }

    private func update(_ id: UUID, _ mutation: (inout ProjectImportItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        mutation(&items[index])
    }

    private func run(_ job: Job) async {
        let project = job.project
        let context = job.context
        var processingSource: RecordingSource?
        do {
            try Task.checkCancellation()
            guard project.modelContext != nil, !project.isDeleted else { throw CancellationError() }
            update(job.id) { $0.state = .importing; $0.startedAt = .now }
            if let url = job.url {
                // Resource inspection and classification are file I/O, never View.body work.
                let type = await Task.detached { SourceImportService.type(for: url) }.value
                try Task.checkCancellation()
                guard let type else { throw SourceImportError.unsupported }
                if type == .audio {
                    let audio = try await audioImporter.importFile(at: url)
                    let recording = Recording(id: audio.id, title: audio.title, audioFileName: audio.fileName,
                        originalFileName: audio.originalFileName, duration: audio.duration)
                    do {
                        try Task.checkCancellation()
                        guard !project.isDeleted else { throw CancellationError() }
                        context.insert(recording)
                        recording.project = project
                        SourceCompatibilityMigration().ensurePrimaryAudio(for: recording, context: context)
                        let previous = project.updatedAt
                        project.updatedAt = .now
                        do { try context.save() }
                        catch { project.updatedAt = previous; recording.project = nil; context.delete(recording); throw error }
                    } catch { try? await audioImporter.discard(audio); throw error }
                    update(job.id) { $0.state = .added }
                    return
                }
                let imported = try await sourceImporter.importFile(url, existingHashes: Set(project.sources.compactMap(\.contentHash)))
                let source = RecordingSource(id: imported.id, type: imported.type, displayName: imported.originalFilename,
                    originalFilename: imported.originalFilename, localFileReference: imported.filename)
                source.contentHash = imported.hash
                do {
                    try Task.checkCancellation()
                    guard !project.isDeleted else { throw CancellationError() }
                    context.insert(source)
                    source.project = project
                    let previous = project.updatedAt
                    project.updatedAt = .now
                    do { try context.save() }
                    catch { project.updatedAt = previous; source.project = nil; context.delete(source); throw error }
                } catch { try? await sourceImporter.discard(imported); throw error }
                processingSource = source
            } else { processingSource = job.source }
            guard let source = processingSource, source.project?.id == project.id, source.recording == nil else { throw ProjectEditingError.invalidOwner }
            update(job.id) { $0.sourceID = source.id; $0.state = .processing }
            source.status = .processing
            source.processingError = nil
            try context.save()
            let jobID = job.id
            let result = try await processor.process(url: storage.sourceURL(source), type: source.type) { [weak self] progress in
                await self?.setProgress(progress, id: jobID)
            }
            try Task.checkCancellation()
            guard !project.isDeleted, source.project?.id == project.id, !source.isDeleted else { throw CancellationError() }
            let units = try result.units.map { try SourceTextUnit(position: $0.position, text: $0.text, origin: $0.origin, locator: $0.locator) }
            for unit in source.textUnits { context.delete(unit) }
            source.textUnits = units
            source.metadata = result.metadata
            source.processingError = result.warnings.isEmpty ? nil : result.warnings.joined(separator: "\n")
            source.status = result.warnings.isEmpty || source.type == .image ? .ready : .partial
            project.updatedAt = .now
            try context.save()
            update(job.id) { $0.state = .added }
        } catch {
            let message = userFacingFailure(error)
            if let source = processingSource, !source.isDeleted, source.project?.id == project.id {
                source.status = .failed
                source.processingError = message
                try? context.save()
            }
            update(job.id) { $0.state = error is CancellationError ? .cancelled : .failed(message) }
        }
    }

    private func userFacingFailure(_ error: Error) -> String {
        if error is CancellationError { return "Processing cancelled. Retry to continue." }
        if let error = error as? SourceImportError { return error.localizedDescription }
        if let error = error as? CocoaError, error.code == .fileReadNoPermission {
            return "This file couldn't be opened. Check that it is downloaded in Files, then retry."
        }
        return "This file couldn't be read. Retry processing or import another copy."
    }
    private func setProgress(_ value: SourceProcessingProgress, id: UUID) { update(id) { $0.progress = value } }
}
