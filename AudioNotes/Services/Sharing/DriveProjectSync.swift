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

    @MainActor
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
                Source(id: $0.id, name: $0.originalFilename, url: storage.sourceURL($0), type: $0.type)
            }
    }
}

actor DriveProjectSync {
    static let shared = DriveProjectSync()
    private var running = false

    func importProject(_ folder: DriveProjectFolder, remote: DriveProjectRemote,
                       storage: LibraryStorage, container: ModelContainer) async throws -> Int {
        guard !running else { throw GoogleDriveSharingError.busy }
        running = true
        defer { running = false }
        let current = try await remote.validateFolder(id: folder.id)
        guard current == folder, let projectID = current.publishedProjectID else {
            throw DriveProjectError.selectPublishedProject
        }
        let items = try await remote.publishedItems(in: folder.id)
        let keys = items.compactMap { $0.appProperties?["soniquillKey"] }
        guard Set(keys).count == items.count else { throw DriveProjectError.conflictingFiles }
        let ids = items.compactMap { DriveProjectRemote.publishedID($0, prefix: "r-") }
        try remote.checkPrivacy()
        let existing = try await Self.prepareImport(projectID: projectID, name: folder.name,
                                                    recordingIDs: Set(ids), container: container)
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let codec = RecordingPackageCodec()
        var imported = 0
        for item in items {
            if let id = DriveProjectRemote.publishedID(item, prefix: "s-") {
                try await importSource(item, id: id, projectID: projectID, remote: remote,
                                       temporary: temporary, storage: storage, container: container)
                continue
            }
            guard let id = DriveProjectRemote.publishedID(item, prefix: "r-"), !existing.contains(id) else { continue }
            let file = temporary.appending(path: item.id + ".soniquill")
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
            try FileManager.default.removeItem(at: file)
            imported += 1
        }
        return imported
    }

    private func importSource(_ item: DriveProjectRemote.Item, id: UUID, projectID: UUID, remote: DriveProjectRemote,
                              temporary: URL, storage: LibraryStorage, container: ModelContainer) async throws {
        guard try await !Self.containsSource(id, projectID: projectID, container: container) else { return }
        let ext = (item.name as NSString).pathExtension.lowercased()
        guard ["pdf", "jpg", "jpeg", "png", "heif", "heic", "txt", "md", "markdown"].contains(ext) else {
            throw SourceImportError.unsupported
        }
        let file = temporary.appending(path: item.id + "." + ext)
        let limit: UInt64 = ["txt", "md", "markdown"].contains(ext) ? 64 : 512
        try await remote.download(item, to: file, limit: limit * 1_048_576)
        guard let type = SourceImportService.type(for: file), type != .audio else { throw SourceImportError.unsupported }
        try remote.checkPrivacy()
        try await Self.commitSource(item, id: id, projectID: projectID, file: file, type: type,
                                    storage: storage, container: container)
    }

    @MainActor
    private static func containsSource(_ id: UUID, projectID: UUID, container: ModelContainer) throws -> Bool {
        let context = ModelContext(container)
        guard let source = try context.fetch(FetchDescriptor<RecordingSource>(predicate: #Predicate { $0.id == id })).first
        else { return false }
        guard source.project?.id == projectID else { throw SourceImportError.duplicate }
        return true
    }

    @MainActor
    private static func commitSource(_ item: DriveProjectRemote.Item, id: UUID, projectID: UUID, file: URL,
                                     type: RecordingSourceType, storage: LibraryStorage, container: ModelContainer) throws {
        try Task.checkCancellation()
        guard try !containsSource(id, projectID: projectID, container: container) else { return }
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
    }

    @MainActor
    private static func prepareImport(projectID: UUID, name: String, recordingIDs: Set<UUID>,
                                      container: ModelContainer) throws -> Set<UUID> {
        let context = ModelContext(container)
        let projectQuery = FetchDescriptor<Project>(predicate: #Predicate { $0.id == projectID })
        let project = try context.fetch(projectQuery).first
        let existing = try context.fetch(FetchDescriptor<Recording>()).filter { recordingIDs.contains($0.id) }
        guard existing.allSatisfy({ $0.project?.id == projectID }) else { throw RecordingPackageError.duplicate }
        try Task.checkCancellation()
        if project == nil {
            context.insert(Project(id: projectID, name: name))
            try context.save()
        }
        return Set(existing.map(\.id))
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
        var unfinished = 0
        var failures: [String] = []
        var conflicts: [Conflict] = []
        var resolvedConflictIDs: Set<String> = []
    }

    struct Conflict: Equatable, Sendable, Identifiable, Error {
        let parent: String
        let key: String
        let id: String
        let local: Version
        let drive: Version
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
        let folder: DriveProjectFolder
        let projects: [UUID: Bool]
        let unfinished: Int
    }

    private struct File {
        let key: String
        let name: String
        let url: URL
        let mime: String
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
        let destination = try await remote.validateFolder(id: folder.id)
        guard destination == folder else { throw DriveProjectError.folderUnavailable }
        if destination.publishedProjectID != nil, projects.count != 1 { throw DriveProjectError.selectOneProject }
        var result = Result()
        for project in projects {
            try remote.checkPrivacy()
            result.unfinished += project.unfinished
            let projectID: String
            if destination.publishedProjectID != nil {
                projectID = destination.id
            } else if !activeResolutions.isEmpty {
                guard let existing = try await remote.projectFolder(in: destination.id, project: project) else { continue }
                projectID = existing.id
            } else {
                projectID = try await remote.ensureProjectFolder(in: destination.id, project: project)
            }
            if !activeResolutions.isEmpty, !resolvingParents.contains(projectID) { continue }
            for source in project.sources {
                try remote.checkPrivacy()
                let mime = UTType(filenameExtension: source.url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                let file = File(key: "s-" + source.id.uuidString, name: source.name, url: source.url, mime: mime)
                let itemResolution: Resolution?
                if !activeResolutions.isEmpty {
                    guard let matched = resolutionMap["\(projectID)/\(file.key)"] else { continue }
                    itemResolution = matched
                } else {
                    itemResolution = nil
                }
                try await attempt(label: source.name, resolvedID: itemResolution?.conflict.id, remote: remote, result: &result) {
                    let values = try FileManager.default.attributesOfItem(atPath: source.url.path)
                    guard values[.type] as? FileAttributeType == .typeRegular else {
                        throw RecordingPackageError.invalid
                    }
                    let limit = (source.type == .document ? 64 : 512) * 1_048_576
                    guard let bytes = values[.size] as? NSNumber, bytes.uint64Value <= UInt64(limit) else {
                        throw RecordingPackageError.sizeLimit
                    }
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
                    return try await withRecordingFile(recording) { file, manifest in
                        var receive: ((DriveProjectRemote.Item) async throws -> Void)?
                        if let storageRoot, let applyTranscript {
                            receive = { item in
                                let target = file.url.deletingLastPathComponent().appending(path: "Remote.soniquill")
                                try await remote.downloadPackage(item, to: target)
                                let staged = try await RecordingPackageCodec().stage(target, under: storageRoot)
                                defer { try? FileManager.default.removeItem(at: staged.directory) }
                                guard staged.manifest.files == manifest.files else {
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
        let destination = try await remote.validateFolder(id: folder.id)
        guard destination == folder else { throw DriveProjectError.folderUnavailable }
        if destination.publishedProjectID != nil, projects.count != 1 { throw DriveProjectError.selectOneProject }
        var verified: [UUID: Bool] = [:]
        for project in projects {
            try Task.checkCancellation()
            try remote.checkPrivacy()
            await progress(project.name)
            verified[project.id] = try await isCurrent(project, in: destination, remote: remote)
        }
        try Task.checkCancellation()
        return Verification(checkedAt: checkedAt, folder: destination, projects: verified, unfinished: projects.reduce(0) { $0 + $1.unfinished })
    }

    private func isCurrent(_ project: DriveProjectSnapshot, in destination: DriveProjectFolder,
                           remote: DriveProjectRemote) async throws -> Bool {
        let folderID: String
        if destination.publishedProjectID != nil {
            folderID = destination.id
        } else {
            guard let folder = try await remote.projectFolder(in: destination.id, project: project),
                  folder.name == project.name else { return false }
            folderID = folder.id
        }
        for source in project.sources {
            try Task.checkCancellation()
            let items = try await remote.children(in: folderID, key: "s-" + source.id.uuidString)
                .filter { $0.mimeType != DriveProjectRemote.folderType }
            guard !items.isEmpty, try items.allSatisfy({ try matches($0, name: source.name, url: source.url) }) else {
                return false
            }
        }
        for recording in project.recordings {
            try Task.checkCancellation()
            let items = try await remote.children(in: folderID, key: "r-" + recording.recordingID.uuidString)
                .filter { $0.mimeType != DriveProjectRemote.folderType }
            guard !items.isEmpty else { return false }
            let same = try await withRecordingFile(recording) { file, _ in
                try items.allSatisfy { try matches($0, name: file.name, url: file.url) }
            }
            if !same { return false }
        }
        return true
    }

    private func withRecordingFile<T>(_ recording: RecordingPackageSnapshot,
                                      operation: (File, RecordingPackageManifest) async throws -> T) async throws -> T {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SoniquillSync-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = File(key: "r-" + recording.recordingID.uuidString,
                        name: String(recording.title.prefix(100)) + ".soniquill",
                        url: folder.appending(path: "Recording.soniquill"), mime: "application/octet-stream")
        let manifest = try await RecordingPackageCodec().export(recording, to: file.url)
        return try await operation(file, manifest)
    }

    private func matches(_ item: DriveProjectRemote.Item, name: String, url: URL) throws -> Bool {
        guard item.mimeType != DriveProjectRemote.folderType, item.name == name,
              let checksum = item.sha256Checksum else { return false }
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values[.type] as? FileAttributeType == .typeRegular else { throw RecordingPackageError.invalid }
        return checksum == (try SourceImportService.hash(url))
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
            if let failure = error as? GoogleDriveSharingError {
                switch failure {
                case .localOnly, .signInRequired, .http(401): throw failure
                default: break
                }
            }
            try remote.checkPrivacy()
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
        let local = Version(name: file.name, checksum: try SourceImportService.hash(file.url))
        let selected = Self.selectPrimaryFile(from: files, local: local, remote: remote)
        let item = selected.primary
        let extraDuplicateIDs = selected.extraIDs
        let hasDivergentDriveCopies = selected.hasDivergentCopies
        if item == nil, resolution != nil { throw DriveProjectError.conflictingVersion }
        if let item {
            guard let checksum = item.sha256Checksum else { throw DriveProjectError.conflictingVersion }
            let current = Version(name: item.name, checksum: checksum)
            var conflict = Conflict(parent: parent, key: file.key, id: item.id, local: local, drive: current,
                                    canDownload: receive != nil)
            let change: Version.Change
            if let resolution {
                guard resolution.conflict.matchesVersions(of: conflict) else { throw conflict }
                switch resolution.choice {
                case .local: change = .upload
                case .drive:
                    guard resolution.conflict.canDownload else {
                        conflict = Conflict(parent: parent, key: file.key, id: item.id, local: local, drive: current,
                                            canDownload: false)
                        throw conflict
                    }
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
            }
            switch change {
            case .unchanged:
                for extraID in extraDuplicateIDs { try await remote.detachDuplicateKey(id: extraID) }
                remote.saveBaseline(local, for: item.id)
                remote.clearReservation(parent: parent, key: file.key)
                return .unchanged
            case .upload:
                break
            case .download:
                guard let receive else { throw DriveProjectError.remoteVersionChanged }
                do { try await receive(item) }
                catch DriveProjectError.conflictingVersion {
                    conflict = Conflict(parent: parent, key: file.key, id: item.id, local: local, drive: current,
                                        canDownload: false)
                    throw conflict
                }
                for extraID in extraDuplicateIDs { try await remote.detachDuplicateKey(id: extraID) }
                remote.saveBaseline(current, for: item.id)
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
        let reservedID = item == nil ? try await remote.reserveID(parent: parent, key: file.key) : nil
        let target = GoogleDriveUpload.Target(id: item?.id, reservedID: reservedID, parent: parent,
                                             key: file.key, mime: file.mime)
        await progress(file.name, 0)
        let uploader = GoogleDriveUpload(file: file.url, name: file.name, target: target,
                                         transport: remote.transport, checkPrivacy: remote.checkPrivacy,
                                         token: remote.token)
        _ = try await uploader.run { count, total in
            await progress(file.name, Double(count) / Double(total))
        }
        for extraID in extraDuplicateIDs { try await remote.detachDuplicateKey(id: extraID) }
        let finalID = await uploader.currentFileID
        if let id = item?.id ?? finalID ?? reservedID {
            remote.saveBaseline(local, for: id)
            if item == nil, finalID != reservedID {
                remote.saveReservation(id, parent: parent, key: file.key)
            }
        }
        if item != nil { remote.clearReservation(parent: parent, key: file.key) }
        return .upload
    }

    private static func selectPrimaryFile(
        from files: [DriveProjectRemote.Item],
        local: Version,
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
                let lhsDiffers = lhs.sha256Checksum.map { Version(name: lhs.name, checksum: $0) != local } ?? true
                let rhsDiffers = rhs.sha256Checksum.map { Version(name: rhs.name, checksum: $0) != local } ?? true
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
        return File(key: "conflict-" + hash,
                    name: name.deletingPathExtension + " (Local Conflict Copy)" + suffix, url: file.url, mime: file.mime)
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
        let id = try await remote.reserveID(parent: conflict.parent, key: copy.key)
        let target = GoogleDriveUpload.Target(id: nil, reservedID: id, parent: conflict.parent, key: copy.key, mime: copy.mime)
        await progress(copy.name, 0)
        let uploader = GoogleDriveUpload(file: copy.url, name: copy.name, target: target, transport: remote.transport,
                                         checkPrivacy: remote.checkPrivacy, token: remote.token)
        _ = try await uploader.run { sent, total in
            await progress(copy.name, Double(sent) / Double(total))
        }
        remote.clearReservation(parent: conflict.parent, key: copy.key)
        return .upload
    }
}
