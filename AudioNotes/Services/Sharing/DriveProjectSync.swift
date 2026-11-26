import CryptoKit
import Foundation
import SwiftData
import UniformTypeIdentifiers

enum DriveProjectError: LocalizedError {
    case folderUnavailable, conflictingFiles, conflictingVersion, remoteVersionChanged, noProjects, selectOneProject, selectPublishedProject

    var errorDescription: String? {
        switch self {
        case .folderUnavailable: "Choose a writable folder you own in My Drive."
        case .conflictingFiles: "Drive contains conflicting copies of a synchronized item."
        case .conflictingVersion: "The local and Drive versions differ. Both copies were kept."
        case .remoteVersionChanged: "This item has a newer version on Drive. The Drive copy was kept."
        case .noProjects: "Select at least one project to synchronize."
        case .selectOneProject: "Select one local project to link to this published Drive project."
        case .selectPublishedProject: "Choose the published project folder inside your Drive sharing folder."
        }
    }
}

struct DriveProjectSnapshot: Sendable {
    struct Source: Sendable {
        let id: UUID
        let name: String
        let url: URL
        let type: RecordingSourceType
    }
    let id: UUID
    let name: String
    let recordings: [RecordingPackageSnapshot]
    let sources: [Source]
    let unfinished: Int

    /// Copies the project on the caller's actor. Must run on the actor that owns `project`'s model context;
    /// prefer `make(projectIDs:storage:container:)` to keep this work off the main actor.
    init(project: Project, storage: LibraryStorage) throws {
        id = project.id
        name = project.name
        let finished = project.recordings.filter { $0.transcript?.segments.isEmpty == false }
        unfinished = project.recordings.count - finished.count
        recordings = try finished.sorted { $0.id.uuidString < $1.id.uuidString }.map {
            try RecordingPackageSnapshot(recording: $0, selected: Set($0.sources.map(\.id)), storage: storage)
        }
        sources = project.sources.filter { [.document, .pdf, .image].contains($0.type) }
            .sorted { $0.id.uuidString < $1.id.uuidString }.map {
                // Same location as `LibraryStorage.sourceURL(_:)`, without requiring the main actor.
                let url = $0.isPrimaryAudio ? storage.recordingURL(fileName: $0.localFileReference)
                    : storage.sourceURL(id: $0.id, filename: $0.localFileReference)
                return Source(id: $0.id, name: $0.originalFilename, url: url, type: $0.type)
            }
    }

    /// Builds snapshots of the saved state of `projectIDs` on a background model actor, in the given order.
    /// Projects that no longer exist are skipped.
    static func make(projectIDs: [UUID], storage: LibraryStorage,
                     container: ModelContainer) async throws -> [DriveProjectSnapshot] {
        try await DriveProjectSnapshotBuilder(modelContainer: container).snapshots(projectIDs: projectIDs, storage: storage)
    }
}

@ModelActor
actor DriveProjectSnapshotBuilder {
    func snapshots(projectIDs: [UUID], storage: LibraryStorage) throws -> [DriveProjectSnapshot] {
        var result: [DriveProjectSnapshot] = []
        for projectID in projectIDs {
            try Task.checkCancellation()
            var request = FetchDescriptor<Project>(predicate: #Predicate { $0.id == projectID })
            request.fetchLimit = 1
            guard let project = try modelContext.fetch(request).first else { continue }
            result.append(try DriveProjectSnapshot(project: project, storage: storage))
        }
        return result
    }
}

/// Tracks running Drive project work so deleting a project can cancel and await it.
actor DriveProjectSyncRegistry {
    static let shared = DriveProjectSyncRegistry()

    private struct Entry {
        let projectIDs: Set<UUID>
        let cancel: @Sendable () -> Void
        let wait: @Sendable () async -> Void
    }
    private var entries: [UUID: Entry] = [:]
    /// Projects being deleted; work registered for them is cancelled immediately.
    private var deleting: Set<UUID> = []

    /// Registers `task` as working on `projectIDs`. It is unregistered automatically when it finishes.
    @discardableResult
    func register<Success: Sendable, Failure: Error>(projectIDs: Set<UUID>, task: Task<Success, Failure>) -> UUID {
        let token = UUID()
        if !projectIDs.isDisjoint(with: deleting) { task.cancel() }
        entries[token] = Entry(projectIDs: projectIDs, cancel: { task.cancel() }, wait: { _ = await task.result })
        Task { [weak self] in
            _ = await task.result
            await self?.remove(token)
        }
        return token
    }

    @discardableResult
    func register<Success: Sendable, Failure: Error>(projectID: UUID, task: Task<Success, Failure>) -> UUID {
        register(projectIDs: [projectID], task: task)
    }

    func unregister(_ token: UUID) { entries[token] = nil }

    func isActive(projectID: UUID) -> Bool { entries.values.contains { $0.projectIDs.contains(projectID) } }

    /// Cancels every registered task touching `projectID` and returns once they have all finished.
    func cancelAndWait(projectID: UUID) async {
        let matching = entries.filter { $0.value.projectIDs.contains(projectID) }
        for entry in matching.values { entry.cancel() }
        for (token, entry) in matching {
            await entry.wait()
            entries[token] = nil
        }
    }

    /// Blocks new work for `projectID`, then cancels and awaits running work. Pair with `endDeletion`.
    func beginDeletion(projectID: UUID) async {
        deleting.insert(projectID)
        await cancelAndWait(projectID: projectID)
    }

    func endDeletion(projectID: UUID) { deleting.remove(projectID) }

    func isDeleting(projectID: UUID) -> Bool { deleting.contains(projectID) }

    private func remove(_ token: UUID) { entries[token] = nil }
}

actor DriveProjectSync {
    static let shared = DriveProjectSync()
    private var running = false
    private var checksums = LocalChecksumCache()

    struct ImportResult: Sendable, Equatable {
        enum SkipReason: Sendable, Equatable {
            /// The item already exists in the target project.
            case alreadyInProject
            /// The item exists locally in another project or outside any project.
            case belongsToOtherProject
            /// Drive holds several copies with the same key; only the primary copy was considered.
            case duplicateOnDrive
        }
        struct Skipped: Sendable, Equatable {
            let name: String
            let reason: SkipReason
        }
        struct Failure: Sendable, Equatable {
            let name: String
            let message: String
        }
        var importedRecordings = 0
        var importedSources = 0
        var skipped: [Skipped] = []
        var failures: [Failure] = []
    }

    func importProject(_ folder: DriveProjectFolder, remote: DriveProjectRemote,
                       storage: LibraryStorage, container: ModelContainer) async throws -> ImportResult {
        guard !running else { throw GoogleDriveSharingError.busy }
        running = true
        defer { running = false }
        let current = try await remote.validateFolder(id: folder.id, access: .read)
        guard current.isSameFolder(as: folder), let projectID = current.publishedProjectID else {
            throw DriveProjectError.selectPublishedProject
        }
        var result = ImportResult()
        let listed = try await remote.publishedItems(in: folder.id)
        var order: [String] = []
        var groups: [String: [DriveProjectRemote.Item]] = [:]
        for item in listed {
            guard let key = item.appProperties?["soniquillKey"] else { continue }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
        }
        var items: [DriveProjectRemote.Item] = []
        for key in order {
            guard let group = groups[key] else { continue }
            let selected = Self.selectPrimaryFile(from: group, local: nil, remote: remote)
            guard let primary = selected.primary else { continue }
            items.append(primary)
            for extra in group where extra.id != primary.id {
                result.skipped.append(.init(name: extra.name, reason: .duplicateOnDrive))
            }
        }
        let ids = items.compactMap { DriveProjectRemote.publishedID($0, prefix: "r-") }
        try remote.checkPrivacy()
        let placement = try await Self.prepareImport(projectID: projectID, name: current.name,
                                                     recordingIDs: Set(ids), container: container)
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let codec = RecordingPackageCodec()
        for item in items {
            try Task.checkCancellation()
            do {
                if let id = DriveProjectRemote.publishedID(item, prefix: "s-") {
                    switch try await importSource(item, id: id, projectID: projectID, remote: remote,
                                                  temporary: temporary, storage: storage, container: container) {
                    case .absent: result.importedSources += 1
                    case .inProject: result.skipped.append(.init(name: item.name, reason: .alreadyInProject))
                    case .elsewhere: result.skipped.append(.init(name: item.name, reason: .belongsToOtherProject))
                    }
                    continue
                }
                guard let id = DriveProjectRemote.publishedID(item, prefix: "r-") else { continue }
                if placement.inProject.contains(id) {
                    result.skipped.append(.init(name: item.name, reason: .alreadyInProject))
                    continue
                }
                if placement.elsewhere.contains(id) {
                    result.skipped.append(.init(name: item.name, reason: .belongsToOtherProject))
                    continue
                }
                let file = temporary.appending(path: item.id + ".soniquill")
                defer { try? FileManager.default.removeItem(at: file) }
                try await remote.downloadPackage(item, to: file)
                let staged = try await codec.stage(file, under: storage.rootURL)
                do {
                    guard staged.manifest.recordingID == id else { throw RecordingPackageError.invalid }
                    try remote.checkPrivacy()
                } catch {
                    try? FileManager.default.removeItem(at: staged.directory)
                    throw error
                }
                _ = try await RecordingPackageImport.commit(staged, storage: storage, container: container, projectID: projectID)
                result.importedRecordings += 1
            } catch {
                try Self.rethrowIfFatal(error, remote: remote)
                result.failures.append(.init(name: item.name, message: error.localizedDescription))
            }
        }
        return result
    }

    /// Rethrows cancellation, Local Only and authentication errors; other errors are per-item failures.
    private static func rethrowIfFatal(_ error: any Error, remote: DriveProjectRemote) throws {
        try Task.checkCancellation()
        if error is CancellationError { throw error }
        if let failure = error as? GoogleDriveSharingError {
            switch failure {
            case .localOnly, .signInRequired, .http(401): throw failure
            default: break
            }
        }
        try remote.checkPrivacy()
    }

    private enum LocalPlacement { case absent, inProject, elsewhere }

    private func importSource(_ item: DriveProjectRemote.Item, id: UUID, projectID: UUID, remote: DriveProjectRemote,
                              temporary: URL, storage: LibraryStorage, container: ModelContainer) async throws -> LocalPlacement {
        let placement = try await Self.sourcePlacement(id, projectID: projectID, container: container)
        guard placement == .absent else { return placement }
        let ext = (item.name as NSString).pathExtension.lowercased()
        guard ["pdf", "jpg", "jpeg", "png", "heif", "heic", "txt", "md", "markdown"].contains(ext) else {
            throw SourceImportError.unsupported
        }
        let file = temporary.appending(path: item.id + "." + ext)
        defer { try? FileManager.default.removeItem(at: file) }
        let limit: UInt64 = ["txt", "md", "markdown"].contains(ext) ? 64 : 512
        try await remote.download(item, to: file, limit: limit * 1_048_576)
        guard let type = SourceImportService.type(for: file), type != .audio else { throw SourceImportError.unsupported }
        try remote.checkPrivacy()
        return try await Self.commitSource(item, id: id, projectID: projectID, file: file, type: type,
                                           storage: storage, container: container)
    }

    @MainActor
    private static func sourcePlacement(_ id: UUID, projectID: UUID, container: ModelContainer) throws -> LocalPlacement {
        let context = ModelContext(container)
        guard let source = try context.fetch(FetchDescriptor<RecordingSource>(predicate: #Predicate { $0.id == id })).first
        else { return .absent }
        return source.project?.id == projectID ? .inProject : .elsewhere
    }

    @MainActor
    private static func commitSource(_ item: DriveProjectRemote.Item, id: UUID, projectID: UUID, file: URL,
                                     type: RecordingSourceType, storage: LibraryStorage,
                                     container: ModelContainer) throws -> LocalPlacement {
        try Task.checkCancellation()
        let placement = try sourcePlacement(id, projectID: projectID, container: container)
        guard placement == .absent else { return placement }
        let context = ModelContext(container)
        guard let project = try context.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.id == projectID })).first
        else { throw DriveProjectError.noProjects }
        let fm = FileManager.default
        let directory = storage.sourceDirectory(id: id)
        guard !fm.fileExists(atPath: directory.path) else { throw SourceImportError.duplicate }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "original." + file.pathExtension
        do {
            try fm.moveItem(at: file, to: storage.sourceURL(id: id, filename: filename))
            let source = RecordingSource(id: id, type: type, displayName: item.name, originalFilename: item.name,
                                         localFileReference: filename)
            source.contentHash = item.sha256Checksum
            context.insert(source)
            source.project = project
            try context.save()
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
        return .absent
    }

    @MainActor
    private static func prepareImport(projectID: UUID, name: String, recordingIDs: Set<UUID>,
                                      container: ModelContainer) throws -> (inProject: Set<UUID>, elsewhere: Set<UUID>) {
        let context = ModelContext(container)
        let projectQuery = FetchDescriptor<Project>(predicate: #Predicate { $0.id == projectID })
        let project = try context.fetch(projectQuery).first
        let existing = try context.fetch(FetchDescriptor<Recording>()).filter { recordingIDs.contains($0.id) }
        try Task.checkCancellation()
        if project == nil {
            context.insert(Project(id: projectID, name: name))
            try context.save()
        }
        let inProject = Set(existing.filter { $0.project?.id == projectID }.map(\.id))
        return (inProject, Set(existing.map(\.id)).subtracting(inProject))
    }

    struct Version: Codable, Equatable, Hashable {
        let name: String
        let checksum: String

        enum Change: Equatable { case unchanged, upload, download, conflict }

        func change(comparedTo remote: Self, baseline: Self?) -> Change {
            if self == remote { return .unchanged }
            if remote == baseline { return .upload }
            if self == baseline { return .download }
            return .conflict
        }
    }

    struct Result: Sendable {
        var uploaded = 0
        var downloaded = 0
        var unchanged = 0
        /// Recordings skipped because they have no finished transcript yet.
        var unfinished = 0
        var unfinishedByProject: [UUID: Int] = [:]
        var failures: [String] = []
        var conflicts: [Conflict] = []
        var resolvedConflictIDs: Set<String> = []
        /// The destination as currently named on Drive; persist it so a rename on Drive sticks locally.
        var destination: DriveProjectFolder? = nil
    }

    struct Conflict: Equatable, Sendable, Identifiable, Error {
        let parent: String
        let key: String
        let id: String
        let local: Version
        let drive: Version
        /// Whether `.drive` can be applied. `false` for project sources and for recordings whose Drive copy
        /// can't update the local recording in place; only `.local` and `.both` resolve those.
        let canDownload: Bool

        func matchesVersions(of other: Self) -> Bool {
            parent == other.parent && key == other.key && id == other.id &&
                local == other.local && drive == other.drive
        }
    }

    enum Choice: Sendable { case local, drive, both }

    struct Resolution: Sendable {
        let conflict: Conflict
        let choice: Choice
    }

    struct Verification: Sendable {
        let checkedAt: Date
        /// The destination as currently named on Drive.
        let folder: DriveProjectFolder
        let projects: [UUID: Bool]
        let unfinished: Int
        /// Recordings per project that were not checked because they have no finished transcript yet.
        var unfinishedByProject: [UUID: Int] = [:]
    }

    /// A local item to synchronize. `checksum`/`size` may come from the fingerprint cache; `materialize`
    /// produces a file with exactly that content only when bytes are needed (upload or conflict copy).
    private struct File {
        let key: String
        let name: String
        let mime: String
        let checksum: String
        let materialize: () async throws -> URL

        func renamed(key: String, name: String) -> File {
            File(key: key, name: name, mime: mime, checksum: checksum, materialize: materialize)
        }
    }

    typealias ApplyTranscript = @MainActor @Sendable (RecordingPackageManifest, RecordingPackageSnapshot, UUID) throws -> Void

    func run(projects: [DriveProjectSnapshot], folder: DriveProjectFolder,
             remote: DriveProjectRemote, storageRoot: URL? = nil, applyTranscript: ApplyTranscript? = nil,
             resolution: Resolution? = nil, resolutions: [Resolution] = [],
             progress: @Sendable (String, Double?) async -> Void) async throws -> Result {
        guard !running else { throw GoogleDriveSharingError.busy }
        guard !projects.isEmpty else { throw DriveProjectError.noProjects }
        running = true
        defer { running = false }
        let activeResolutions = resolutions + (resolution.map { [$0] } ?? [])
        let resolutionMap = Dictionary(
            activeResolutions.map { ("\($0.conflict.parent)/\($0.conflict.key)", $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let resolvingParents = Set(activeResolutions.map(\.conflict.parent))
        let destination = try await remote.validateFolder(id: folder.id, access: .linkPublished)
        guard destination.isSameFolder(as: folder) else { throw DriveProjectError.folderUnavailable }
        if destination.publishedProjectID != nil, projects.count != 1 { throw DriveProjectError.selectOneProject }
        var result = Result()
        result.destination = destination
        let runKeys = Set(projects.map { "p-" + $0.id.uuidString })
        for project in projects {
            try remote.checkPrivacy()
            result.unfinished += project.unfinished
            if project.unfinished > 0 { result.unfinishedByProject[project.id] = project.unfinished }
            let excluding = runKeys.subtracting(["p-" + project.id.uuidString])
            let projectID: String
            if destination.publishedProjectID != nil {
                projectID = destination.id
            } else if !activeResolutions.isEmpty {
                guard let existing = try await remote.projectFolder(in: destination.id, project: project,
                                                                    access: .linkPublished, excluding: excluding)
                else { continue }
                projectID = existing.id
            } else {
                projectID = try await remote.ensureProjectFolder(in: destination.id, project: project, excluding: excluding)
            }
            if !activeResolutions.isEmpty, !resolvingParents.contains(projectID) { continue }
            for source in project.sources {
                try remote.checkPrivacy()
                let key = "s-" + source.id.uuidString
                let itemResolution: Resolution?
                if !activeResolutions.isEmpty {
                    guard let matched = resolutionMap["\(projectID)/\(key)"] else { continue }
                    itemResolution = matched
                } else {
                    itemResolution = nil
                }
                try await attempt(label: source.name, resolvedID: itemResolution?.conflict.id, remote: remote, result: &result) {
                    let file = try sourceFile(source, key: key)
                    return try await upload(file, to: projectID, remote: remote, resolution: itemResolution, progress: progress)
                }
            }
            for recording in project.recordings {
                try remote.checkPrivacy()
                let recordingKey = "r-" + recording.recordingID.uuidString
                let itemResolution: Resolution?
                if !activeResolutions.isEmpty {
                    guard let matched = resolutionMap["\(projectID)/\(recordingKey)"] else { continue }
                    itemResolution = matched
                } else {
                    itemResolution = nil
                }
                try await attempt(label: recording.title, resolvedID: itemResolution?.conflict.id, remote: remote, result: &result) {
                    await progress(recording.title, nil)
                    return try await withWorkingDirectory { directory in
                        let (file, manifestFiles) = try await recordingFile(recording, in: directory)
                        var receive: ((DriveProjectRemote.Item) async throws -> Void)?
                        if let storageRoot, let applyTranscript {
                            receive = { item in
                                let target = directory.appending(path: "Remote.soniquill")
                                try await remote.downloadPackage(item, to: target)
                                let staged = try await RecordingPackageCodec().stage(target, under: storageRoot)
                                defer { try? FileManager.default.removeItem(at: staged.directory) }
                                guard staged.manifest.files == manifestFiles else {
                                    throw DriveProjectError.conflictingVersion
                                }
                                try remote.checkPrivacy()
                                try await applyTranscript(staged.manifest, recording, project.id)
                            }
                        }
                        return try await upload(file, to: projectID, remote: remote, receive: receive,
                                                resolution: itemResolution, progress: progress)
                    }
                }
            }
            if activeResolutions.isEmpty {
                do { try await remote.pruneLocalState(parent: projectID) }
                catch { try Self.rethrowIfFatal(error, remote: remote) }
            }
        }
        if !activeResolutions.isEmpty, result.uploaded + result.downloaded + result.unchanged == 0,
           result.failures.isEmpty, result.conflicts.isEmpty { throw DriveProjectError.conflictingVersion }
        return result
    }

    func verify(projects: [DriveProjectSnapshot], folder: DriveProjectFolder,
                remote: DriveProjectRemote, progress: @Sendable (String) async -> Void) async throws -> Verification {
        guard !running else { throw GoogleDriveSharingError.busy }
        guard !projects.isEmpty else { throw DriveProjectError.noProjects }
        running = true
        defer { running = false }
        let checkedAt = Date()
        let destination = try await remote.validateFolder(id: folder.id, access: .read)
        guard destination.isSameFolder(as: folder) else { throw DriveProjectError.folderUnavailable }
        if destination.publishedProjectID != nil, projects.count != 1 { throw DriveProjectError.selectOneProject }
        let runKeys = Set(projects.map { "p-" + $0.id.uuidString })
        var verified: [UUID: Bool] = [:]
        var unfinished: [UUID: Int] = [:]
        for project in projects {
            try Task.checkCancellation()
            try remote.checkPrivacy()
            await progress(project.name)
            if project.unfinished > 0 { unfinished[project.id] = project.unfinished }
            verified[project.id] = try await isCurrent(project, in: destination, remote: remote,
                                                       excluding: runKeys.subtracting(["p-" + project.id.uuidString]))
        }
        try Task.checkCancellation()
        return Verification(checkedAt: checkedAt, folder: destination, projects: verified,
                            unfinished: projects.reduce(0) { $0 + $1.unfinished }, unfinishedByProject: unfinished)
    }

    private func isCurrent(_ project: DriveProjectSnapshot, in destination: DriveProjectFolder,
                           remote: DriveProjectRemote, excluding: Set<String>) async throws -> Bool {
        let folderID: String
        if destination.publishedProjectID != nil {
            folderID = destination.id
        } else {
            guard let folder = try await remote.projectFolder(in: destination.id, project: project,
                                                              access: .read, excluding: excluding),
                  folder.name == project.name else { return false }
            folderID = folder.id
        }
        for source in project.sources {
            try Task.checkCancellation()
            let key = "s-" + source.id.uuidString
            let items = try await remote.children(in: folderID, key: key)
                .filter { $0.mimeType != DriveProjectRemote.folderType }
            guard !items.isEmpty else { return false }
            let file = try sourceFile(source, key: key)
            guard items.allSatisfy({ Self.matches($0, file) }) else { return false }
        }
        for recording in project.recordings {
            try Task.checkCancellation()
            let items = try await remote.children(in: folderID, key: "r-" + recording.recordingID.uuidString)
                .filter { $0.mimeType != DriveProjectRemote.folderType }
            guard !items.isEmpty else { return false }
            let same = try await withWorkingDirectory { directory in
                let (file, _) = try await recordingFile(recording, in: directory)
                return items.allSatisfy { Self.matches($0, file) }
            }
            if !same { return false }
        }
        return true
    }

    private func withWorkingDirectory<T>(_ operation: (URL) async throws -> T) async throws -> T {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SoniquillSync-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        return try await operation(folder)
    }

    /// The recording's package identity. When the export inputs are unchanged since a previous export, the
    /// cached checksum is used and the package is only exported again if its bytes are actually needed.
    private func recordingFile(_ recording: RecordingPackageSnapshot,
                               in directory: URL) async throws -> (File, [RecordingPackageManifest.File]) {
        let key = "r-" + recording.recordingID.uuidString
        let name = String(recording.title.prefix(100)) + ".soniquill"
        let url = directory.appending(path: "Recording.soniquill")
        let fingerprint = try LocalChecksumCache.fingerprint(of: recording)
        if let cached = checksums[fingerprint], let manifestFiles = cached.manifestFiles {
            let file = File(key: key, name: name, mime: "application/octet-stream", checksum: cached.checksum) {
                if FileManager.default.fileExists(atPath: url.path) { return url }
                try await RecordingPackageCodec().export(recording, to: url)
                guard try SourceImportService.hash(url) == cached.checksum else {
                    self.invalidate(fingerprint)
                    throw GoogleDriveSharingError.changedFile
                }
                return url
            }
            return (file, manifestFiles)
        }
        let manifest = try await RecordingPackageCodec().export(recording, to: url)
        let checksum = try SourceImportService.hash(url)
        checksums[fingerprint] = .init(checksum: checksum, manifestFiles: manifest.files)
        let file = File(key: key, name: name, mime: "application/octet-stream", checksum: checksum) { url }
        return (file, manifest.files)
    }

    private func sourceFile(_ source: DriveProjectSnapshot.Source, key: String) throws -> File {
        let values = try FileManager.default.attributesOfItem(atPath: source.url.path)
        guard values[.type] as? FileAttributeType == .typeRegular else { throw RecordingPackageError.invalid }
        let limit = (source.type == .document ? 64 : 512) * 1_048_576
        guard let bytes = values[.size] as? NSNumber, bytes.uint64Value <= UInt64(limit) else {
            throw RecordingPackageError.sizeLimit
        }
        let fingerprint = LocalChecksumCache.fingerprint(of: source.url, attributes: values)
        let checksum: String
        if let cached = checksums[fingerprint] {
            checksum = cached.checksum
        } else {
            checksum = try SourceImportService.hash(source.url)
            checksums[fingerprint] = .init(checksum: checksum, manifestFiles: nil)
        }
        let mime = UTType(filenameExtension: source.url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let url = source.url
        return File(key: key, name: source.name, mime: mime, checksum: checksum) { url }
    }

    private func invalidate(_ fingerprint: String) { checksums[fingerprint] = nil }

    private static func matches(_ item: DriveProjectRemote.Item, _ file: File) -> Bool {
        item.mimeType != DriveProjectRemote.folderType && item.name == file.name && item.sha256Checksum == file.checksum
    }

    private func attempt(label: String, resolvedID: String? = nil, remote: DriveProjectRemote, result: inout Result,
                         operation: () async throws -> Version.Change) async throws {
        do {
            switch try await operation() {
            case .upload: result.uploaded += 1
            case .download: result.downloaded += 1
            case .unchanged: result.unchanged += 1
            case .conflict: throw DriveProjectError.conflictingVersion
            }
            if let resolvedID { result.resolvedConflictIDs.insert(resolvedID) }
        } catch let conflict as Conflict {
            result.conflicts.append(conflict)
            result.failures.append("\(label): \(DriveProjectError.conflictingVersion.localizedDescription)")
        } catch {
            try Task.checkCancellation()
            try Self.rethrowIfFatal(error, remote: remote)
            result.failures.append("\(label): \(error.localizedDescription)")
        }
    }

    private func upload(_ file: File, to parent: String, remote: DriveProjectRemote,
                        receive: ((DriveProjectRemote.Item) async throws -> Void)? = nil,
                        resolution: Resolution? = nil,
                        progress: @Sendable (String, Double?) async -> Void) async throws -> Version.Change {
        let allMatches = try await remote.children(in: parent, key: file.key)
        let files = allMatches.filter { $0.mimeType != DriveProjectRemote.folderType }
        if files.isEmpty && !allMatches.isEmpty { throw DriveProjectError.conflictingFiles }
        let local = Version(name: file.name, checksum: file.checksum)
        let selected = Self.selectPrimaryFile(from: files, local: local, remote: remote)
        let item = selected.primary
        let extraDuplicateIDs = selected.extraIDs
        let hasDivergentDriveCopies = selected.hasDivergentCopies
        if item == nil, resolution != nil { throw DriveProjectError.conflictingVersion }
        var expectedDrive: Version?
        if let item {
            guard let checksum = item.sha256Checksum else { throw DriveProjectError.conflictingVersion }
            let current = Version(name: item.name, checksum: checksum)
            expectedDrive = current
            let conflict = Conflict(parent: parent, key: file.key, id: item.id, local: local, drive: current,
                                    canDownload: receive != nil)
            let blocked = Conflict(parent: parent, key: file.key, id: item.id, local: local, drive: current,
                                   canDownload: false)
            var change: Version.Change
            if let resolution {
                guard resolution.conflict.matchesVersions(of: conflict) else { throw conflict }
                switch resolution.choice {
                case .local: change = .upload
                case .drive:
                    guard resolution.conflict.canDownload, receive != nil else { throw blocked }
                    change = .download
                case .both:
                    let outcome = try await keepBoth(file, conflict: conflict, remote: remote, progress: progress)
                    for extraID in extraDuplicateIDs { try await remote.detachDuplicateKey(id: extraID) }
                    return outcome
                }
            } else if hasDivergentDriveCopies {
                change = .conflict
            } else {
                change = local.change(comparedTo: current, baseline: remote.baseline(for: item.id))
                // Only Drive changed, but this item can't be applied locally (e.g. a project source):
                // ask the user instead of failing permanently.
                if change == .download, receive == nil { change = .conflict }
            }
            switch change {
            case .unchanged:
                for extraID in extraDuplicateIDs { try await remote.detachDuplicateKey(id: extraID) }
                remote.saveBaseline(local, for: item.id, parent: parent)
                remote.clearReservation(parent: parent, key: file.key)
                return .unchanged
            case .upload:
                break
            case .download:
                guard let receive else { throw blocked }
                do { try await receive(item) }
                catch DriveProjectError.conflictingVersion { throw blocked }
                for extraID in extraDuplicateIDs { try await remote.detachDuplicateKey(id: extraID) }
                remote.saveBaseline(current, for: item.id, parent: parent)
                return .download
            case .conflict:
                if !hasDivergentDriveCopies {
                    let copy = conflictCopy(file, conflict: conflict)
                    let kept = try await remote.children(in: parent, key: copy.key)
                        .filter { $0.mimeType != DriveProjectRemote.folderType }
                    if kept.contains(where: { $0.sha256Checksum == local.checksum && $0.name == copy.name }) {
                        return .unchanged
                    }
                }
                throw conflict
            }
        }
        let url = try await file.materialize()
        if let item, let expectedDrive {
            // Re-check right before overwriting: another device may have updated the file since it was listed.
            let fresh = try await remote.metadata(id: item.id)
            guard fresh.trashed != true else { throw DriveProjectError.conflictingFiles }
            guard let freshChecksum = fresh.sha256Checksum else { throw DriveProjectError.conflictingVersion }
            let freshVersion = Version(name: fresh.name, checksum: freshChecksum)
            guard freshVersion == expectedDrive else {
                throw Conflict(parent: parent, key: file.key, id: item.id, local: local, drive: freshVersion,
                               canDownload: receive != nil)
            }
        }
        let reservedID = item == nil ? try await remote.reserveID(parent: parent, key: file.key) : nil
        let target = GoogleDriveUpload.Target(id: item?.id, reservedID: reservedID, parent: parent,
                                             key: file.key, mime: file.mime)
        let name = file.name
        await progress(name, 0)
        let uploader = GoogleDriveUpload(file: url, name: name, target: target,
                                         transport: remote.transport, checkPrivacy: remote.checkPrivacy,
                                         knownChecksum: file.checksum, token: remote.token)
        _ = try await uploader.run { count, total in
            await progress(name, Double(count) / Double(total))
        }
        for extraID in extraDuplicateIDs { try await remote.detachDuplicateKey(id: extraID) }
        let finalID = await uploader.currentFileID
        if let id = item?.id ?? finalID ?? reservedID {
            remote.saveBaseline(local, for: id, parent: parent)
            if item == nil, finalID != reservedID {
                remote.saveReservation(id, parent: parent, key: file.key)
            }
        }
        if item != nil { remote.clearReservation(parent: parent, key: file.key) }
        return .upload
    }

    /// Picks the copy to treat as the item when Drive holds several with one key. Without a local version
    /// (import), divergent copies are ordered newest first.
    private static func selectPrimaryFile(
        from files: [DriveProjectRemote.Item],
        local: Version?,
        remote: DriveProjectRemote
    ) -> (primary: DriveProjectRemote.Item?, extraIDs: [String], hasDivergentCopies: Bool) {
        guard !files.isEmpty else { return (nil, [], false) }
        if files.count == 1 { return (files[0], [], false) }
        let versions = Set(files.compactMap { item in
            item.sha256Checksum.map { Version(name: item.name, checksum: $0) }
        })
        let hasDivergent = versions.count > 1 || files.contains { $0.sha256Checksum == nil }
        let sorted = files.sorted { lhs, rhs in
            if hasDivergent {
                let lhsDiffers = lhs.sha256Checksum.map { local == nil || Version(name: lhs.name, checksum: $0) != local } ?? true
                let rhsDiffers = rhs.sha256Checksum.map { local == nil || Version(name: rhs.name, checksum: $0) != local } ?? true
                if lhsDiffers != rhsDiffers { return lhsDiffers }
                let lhsMod = lhs.modifiedTime ?? ""
                let rhsMod = rhs.modifiedTime ?? ""
                if lhsMod != rhsMod { return lhsMod > rhsMod }
                return lhs.id < rhs.id
            } else {
                let lhsBase = remote.baseline(for: lhs.id) != nil
                let rhsBase = remote.baseline(for: rhs.id) != nil
                if lhsBase != rhsBase { return lhsBase }
                let lhsCreated = lhs.createdTime ?? ""
                let rhsCreated = rhs.createdTime ?? ""
                if lhsCreated != rhsCreated { return lhsCreated < rhsCreated }
                return lhs.id < rhs.id
            }
        }
        return (sorted[0], sorted.dropFirst().map(\.id), hasDivergent)
    }

    private func conflictCopy(_ file: File, conflict: Conflict) -> File {
        let name = file.name as NSString
        let suffix = name.pathExtension.isEmpty ? "" : "." + name.pathExtension
        let signature = [file.key, conflict.local.name, conflict.local.checksum, conflict.drive.name,
                         conflict.drive.checksum].joined(separator: "\u{0}")
        let hash = SHA256.hash(data: Data(signature.utf8)).map { String(format: "%02x", $0) }.joined()
        return file.renamed(key: "conflict-" + hash, name: name.deletingPathExtension + " (Local Conflict Copy)" + suffix)
    }

    private func keepBoth(_ file: File, conflict: Conflict, remote: DriveProjectRemote,
                          progress: @Sendable (String, Double?) async -> Void) async throws -> Version.Change {
        let copy = conflictCopy(file, conflict: conflict)
        let existing = try await remote.children(in: conflict.parent, key: copy.key)
            .filter { $0.mimeType != DriveProjectRemote.folderType }
        if !existing.isEmpty {
            guard existing.contains(where: { $0.sha256Checksum == conflict.local.checksum && $0.name == copy.name }) else {
                throw conflict
            }
            remote.clearReservation(parent: conflict.parent, key: copy.key)
            return .unchanged
        }
        let url = try await copy.materialize()
        let id = try await remote.reserveID(parent: conflict.parent, key: copy.key)
        let target = GoogleDriveUpload.Target(id: nil, reservedID: id, parent: conflict.parent, key: copy.key, mime: copy.mime)
        let name = copy.name
        await progress(name, 0)
        let uploader = GoogleDriveUpload(file: url, name: name, target: target, transport: remote.transport,
                                         checkPrivacy: remote.checkPrivacy, knownChecksum: copy.checksum,
                                         token: remote.token)
        _ = try await uploader.run { sent, total in
            await progress(name, Double(sent) / Double(total))
        }
        remote.clearReservation(parent: conflict.parent, key: copy.key)
        return .upload
    }
}

/// Bounded in-memory map from a deterministic fingerprint of local inputs to the checksum of the bytes Drive
/// receives, so unchanged recordings aren't re-exported and unchanged sources aren't re-hashed on every sync.
struct LocalChecksumCache {
    struct Entry: Sendable {
        let checksum: String
        /// Manifest file entries for recording packages; `nil` for plain source files.
        let manifestFiles: [RecordingPackageManifest.File]?
    }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let limit: Int

    init(limit: Int = 512) { self.limit = limit }

    var count: Int { entries.count }

    subscript(fingerprint: String) -> Entry? {
        get { entries[fingerprint] }
        set {
            if let newValue {
                if entries.updateValue(newValue, forKey: fingerprint) == nil { order.append(fingerprint) }
                while order.count > limit { entries[order.removeFirst()] = nil }
            } else if entries.removeValue(forKey: fingerprint) != nil {
                order.removeAll { $0 == fingerprint }
            }
        }
    }

    /// Changes whenever the exported package could change: format version, identity, title, transcript,
    /// and each included file's name, type, location, size, modification time and file number.
    static func fingerprint(of recording: RecordingPackageSnapshot) throws -> String {
        var hasher = SHA256()
        func add(_ text: String) { hasher.update(data: Data(text.utf8)); hasher.update(data: Data([0])) }
        add("soniquill-package-v1")
        add(recording.recordingID.uuidString)
        add(recording.title)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        hasher.update(data: try encoder.encode(recording.transcript))
        for file in recording.files {
            add(file.type.rawValue)
            add(file.name)
            add(fileStamp(file.url, attributes: try FileManager.default.attributesOfItem(atPath: file.url.path)))
        }
        return "r:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fingerprint(of url: URL, attributes: [FileAttributeKey: Any]) -> String {
        "s:" + fileStamp(url, attributes: attributes)
    }

    private static func fileStamp(_ url: URL, attributes: [FileAttributeKey: Any]) -> String {
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate.bitPattern ?? 0
        let number = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let type = (attributes[.type] as? FileAttributeType)?.rawValue ?? ""
        return [url.standardizedFileURL.path, type, String(size), String(modified), String(number)]
            .joined(separator: "\u{0}")
    }
}
