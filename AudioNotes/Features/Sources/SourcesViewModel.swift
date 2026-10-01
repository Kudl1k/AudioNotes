import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class SourcesViewModel {
    let recording: Recording
    let imageLoader: SourceImageLoader
    var error: String?
    var isImporting = false
    var importPhase: String?
    var progress: [UUID: SourceProcessingProgress] = [:]
    var startedAt: [UUID: Date] = [:]
    var searchQuery = ""
    var searchResults: [SourceChunk] = []
    @ObservationIgnored private let importer: any SourceImporting
    @ObservationIgnored private let processor: any SourceProcessing
    @ObservationIgnored private let storage: LibraryStorage
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init(recording: Recording, storage: LibraryStorage = LibraryStorage(), importer: (any SourceImporting)? = nil,
         processor: any SourceProcessing = NativeSourceProcessingService(), imageLoader: SourceImageLoader = SourceImageLoader()) {
        self.recording = recording
        self.imageLoader = imageLoader
        self.storage = storage
        self.importer = importer ?? SourceImportService(storage: storage)
        self.processor = processor
    }

    func prepare(context: ModelContext) {
        SourceCompatibilityMigration().ensurePrimaryAudio(for: recording, context: context)
        do { try context.save() } catch { self.error = error.localizedDescription }
    }
    func url(for source: RecordingSource) -> URL { storage.sourceURL(source) }
    func thumbnailURL(for source: RecordingSource) -> URL { storage.sourceDirectory(id: source.id).appending(path: "thumbnail.jpg") }
    func isProcessing(_ source: RecordingSource) -> Bool { tasks[source.id] != nil || source.status == .processing }

    func importURLs(_ urls: [URL], context: ModelContext) async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false; importPhase = nil }
        var failures: [String] = []
        // Populate legacy hashes locally once, off the UI actor.
        let importedTypes = Set(urls.compactMap(SourceImportService.type(for:)))
        for source in recording.sources where source.contentHash == nil && importedTypes.contains(source.type) {
            importPhase = "Checking duplicate: " + source.displayName
            let file = url(for: source)
            source.contentHash = try? await Task.detached { try SourceImportService.hash(file) }.value
        }
        for url in urls {
            do {
                try Task.checkCancellation()
                importPhase = "Copying " + url.lastPathComponent
                let hashes = Set(recording.sources.compactMap(\.contentHash))
                let imported = try await importer.importFile(url, existingHashes: hashes)
                let source = RecordingSource(id: imported.id, type: imported.type, displayName: imported.originalFilename,
                    originalFilename: imported.originalFilename, localFileReference: imported.filename)
                source.contentHash = imported.hash
                if let duration = imported.duration { source.metadata = .audio(duration: duration) }
                source.recording = recording
                context.insert(source)
                do { try context.save() }
                catch {
                    recording.sources.removeAll { $0.id == source.id }
                    context.delete(source)
                    try? await importer.discard(imported)
                    throw error
                }
                if source.type != .audio { reprocess(source, context: context) }
            } catch is CancellationError { break }
            catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        if !failures.isEmpty { error = failures.joined(separator: "\n\n") }
    }

    func reprocess(_ source: RecordingSource, context: ModelContext) {
        guard source.type != .audio, !isProcessing(source) else { return }
        source.status = .processing
        progress[source.id] = .init(phase: "Preparing local extraction", completed: 0, total: 1)
        source.processingError = nil
        startedAt[source.id] = .now
        do { try context.save() } catch { self.error = error.localizedDescription; source.status = .failed; return }
        let processor = processor
        let fileURL = url(for: source)
        let sourceID = source.id
        tasks[source.id] = Task { [weak self] in
            guard let self else { return }
            defer { self.tasks[source.id] = nil; self.progress[source.id] = nil; self.startedAt[source.id] = nil }
            do {
                let result = try await processor.process(url: fileURL, type: source.type) { [weak self] update in
                    await self?.updateProgress(update, sourceID: sourceID)
                }
                try Task.checkCancellation()
                guard source.recording?.id == self.recording.id else { return }
                let units = try result.units.map { try SourceTextUnit(position: $0.position, text: $0.text, origin: $0.origin, locator: $0.locator) }
                let previous = source.textUnits
                for unit in previous { context.delete(unit) }
                source.textUnits = units
                source.metadata = result.metadata
                source.processingError = result.warnings.isEmpty ? nil : result.warnings.joined(separator: "\n")
                source.status = result.warnings.isEmpty || source.type == .image ? .ready : .partial
                try context.save()
                self.search()
            } catch {
                source.status = .failed
                source.processingError = error is CancellationError ? "Processing cancelled. Reprocess to try again." : error.localizedDescription
                try? context.save()
            }
        }
    }
    private func updateProgress(_ value: SourceProcessingProgress, sourceID: UUID) { progress[sourceID] = value }

    func transcribe(_ source: RecordingSource, resolver: any TranscriptionProviderResolving, context: ModelContext,
                    provider selectedProvider: TranscriptionProviderID? = nil, model selectedModel: String? = nil) {
        guard source.type == .audio, !source.isPrimaryAudio, !isProcessing(source) else { return }
        source.status = .processing
        startedAt[source.id] = .now
        let provider = resolver.resolve(provider: selectedProvider, model: selectedModel)
        let generation = GenerationRecord(recording: recording, feature: .transcription, provider: provider.providerID.flatMap(LLMProviderID.init(rawValue:)),
            model: provider.modelID, presetName: nil, outputLength: .medium, settings: nil, authenticationMethod: provider.authenticationMethod,
            status: .inProgress, billingKind: provider.billingKind)
        generation.providerIDRaw = provider.providerID
        generation.selectedSourceIDsData = try? JSONEncoder().encode([source.id])
        context.insert(generation)
        let tracker = OperationUsageTracker(generation: generation) { try? context.save() }
        var requestIDs: [UUID: UUID] = [:]
        let fileURL = url(for: source)
        tasks[source.id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation.statusRaw == GenerationStatus.inProgress.rawValue { tracker.finish(status: Task.isCancelled ? .cancelled : .failed) }
                try? context.save()
                self.tasks[source.id] = nil; self.startedAt[source.id] = nil
            }
            do {
                let transcript = try await provider.transcribe(audioURL: fileURL, progress: { _ in }, status: { _ in }, usage: { event in
                    switch event {
                    case .began(let id): requestIDs[id] = tracker.beginRequest()
                    case .finished(let id, let usage, let succeeded):
                        if let requestID = requestIDs.removeValue(forKey: id) { tracker.finishRequest(requestID, transcription: usage, succeeded: succeeded) }
                    }
                })
                try Task.checkCancellation()
                if let previous = source.transcript { context.delete(previous) }
                transcript.sourceName = provider.displayName
                transcript.isMock = provider.isMock
                source.transcript = transcript
                source.status = .ready
                source.processingError = nil
                tracker.finish(status: .succeeded)
                try context.save()
            } catch {
                source.status = .failed
                source.processingError = error.localizedDescription
            }
        }
    }
    func cancel(_ source: RecordingSource) { tasks[source.id]?.cancel() }

    func waitForProcessing() async {
        for task in Array(tasks.values) { await task.value }
    }

    func rename(_ source: RecordingSource, name: String, context: ModelContext) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let previous = source.displayName
        source.displayName = name
        do { try context.save() } catch { source.displayName = previous; self.error = error.localizedDescription }
    }

    func remove(_ source: RecordingSource, context: ModelContext) {
        guard !isProcessing(source) else { return }
        let file = url(for: source)
        let trash = storage.rootURL.appending(path: "SourceRemoval-" + UUID().uuidString)
        // Stage the owned file for rollback if the database cannot save.
        let owned = source.isPrimaryAudio ? file : storage.sourceDirectory(id: source.id)
        do {
            let exists = FileManager.default.fileExists(atPath: owned.path)
            if exists { try FileManager.default.moveItem(at: owned, to: trash) }
            do {
                let segmentIDs = Set(source.authoritativeTranscript?.segments.map(\.id) ?? [])
                for session in recording.chatSessions {
                    for message in session.messages {
                        message.sourceReferences = message.sourceReferences.filter { $0.sourceID != source.id }
                        message.references.removeAll { $0.segmentID.map(segmentIDs.contains) ?? false }
                    }
                }
                for summary in recording.summaryHistory + [recording.summary].compactMap({ $0 }) {
                    summary.sourceReferences = summary.sourceReferences.filter { $0.sourceID != source.id }
                    if source.isPrimaryAudio {
                        summary.decisions = summary.decisions.map { var item = $0; item.timestamp = nil; return item }
                        summary.actionItems = summary.actionItems.map { var item = $0; item.timestamp = nil; return item }
                        summary.openQuestions = summary.openQuestions.map { var item = $0; item.timestamp = nil; return item }
                        summary.importantQuotes = summary.importantQuotes.map { var item = $0; item.timestamp = nil; return item }
                    }
                }
                if source.isPrimaryAudio {
                    if let transcript = recording.transcript { context.delete(transcript) }
                    recording.transcript = nil
                    recording.audioFileName = ""
                    recording.originalFileName = ""
                    recording.duration = 0
                }
                recording.sources.removeAll { $0.id == source.id }
                context.delete(source)
                try context.save()
            } catch {
                context.rollback()
                if exists { try? FileManager.default.moveItem(at: trash, to: owned) }
                throw error
            }
            if exists { try FileManager.default.removeItem(at: trash) }
            search()
        } catch { self.error = error.localizedDescription }
    }

    func search() {
        searchTask?.cancel()
        let query = searchQuery
        searchResults = []
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(180))
                guard let self else { return }
                let snapshot = try await RecordingContextSnapshot.load(recording: self.recording)
                let worker = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    return RecordingContextRetriever().search(query: query, chunks: snapshot.chunks)
                }
                let results = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                self.searchResults = Array(results.prefix(100))
            } catch { /* Superseded searches never publish. */ }
        }
    }
}
