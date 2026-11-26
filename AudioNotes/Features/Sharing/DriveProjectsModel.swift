import Foundation
import SwiftData

@MainActor @Observable
final class DriveProjectsModel {
    enum DestinationAvailability: Equatable {
        case available
        case failure(String)
    }

    enum SyncTrigger: Equatable { case manual, automatic }

    /// How a failed Drive operation affects what the user can do next.
    enum ErrorSeverity: Equatable {
        /// The Google authorization is missing, expired or rejected; offer Reconnect.
        case reconnect
        /// Retrying unchanged will not help (Local Only, build configuration, invalid selection).
        case fatal
        /// Network, rate limit, busy or a single unavailable item; the next attempt may succeed.
        case transient
    }

    /// What the last sync/check learned about one project in one Drive folder.
    struct ProjectState: Equatable {
        let folder: DriveProjectFolder
        let checkedAt: Date
        let isCurrent: Bool
        /// Recordings without a finished transcript; they are not shared yet.
        let unfinished: Int
    }

    private let connection = GoogleDriveConnection.shared
    private let registry = DriveProjectSyncRegistry.shared
    private let backgroundWork: any BackgroundWorkExtending
    var destinationAvailability: DestinationAvailability?
    private(set) var isDriveConnected = false
    /// Set after an authorization failure; cleared by a successful reconnect.
    private(set) var needsReconnect = false
    /// The last failure means periodic sync should stop instead of retrying.
    private(set) var stopsAutoSync = false
    /// Folders Drive no longer lets this app open after reconnecting; they must be chosen again.
    private(set) var unavailableFolderIDs: Set<String> = []
    private let source = DrivePackageFolder()
    private var work: Task<Void, Never>?
    private var isCloudWork = false
    var isBusy: Bool { work != nil }
    var sourceName: String?
    var packages: [URL] = []
    var error: String?
    var status: String?
    var progress: Double?
    private(set) var projectStates: [UUID: ProjectState] = [:]
    private(set) var lastCheckedAt: Date?
    var conflicts: [DriveProjectSync.Conflict] = []
    /// Conflict ID → Drive folder whose sync produced it, so resolutions run against the right destination.
    private var conflictFolders: [String: DriveProjectFolder] = [:]
    /// Conflict ID → local project that owns the conflicting item.
    private var conflictOwners: [String: UUID] = [:]

    init(backgroundWork: (any BackgroundWorkExtending)? = nil) {
        self.backgroundWork = backgroundWork ?? BackgroundWork.platform
    }

    var conflictProjectIDs: Set<UUID> { Set(conflicts.compactMap { conflictOwners[$0.id] }) }

    func clearConflicts() {
        conflicts = []
        conflictFolders = [:]
        conflictOwners = [:]
    }

    // MARK: Connection

    func checkDriveAvailability() async {
        do {
            isDriveConnected = try await connection.status()
            destinationAvailability = .available
        } catch {
            destinationAvailability = .failure("Drive sharing is unavailable in this build. Local package sharing is available.")
        }
    }

    private func refreshConnection() async {
        isDriveConnected = (try? await connection.status()) ?? false
        if !isDriveConnected { needsReconnect = true }
    }

    /// Re-runs Google authorization without choosing a folder, then checks the folders already in use.
    func reconnect(checking folders: [DriveProjectFolder]) {
        start("Waiting for Google Drive…", cloud: true) {
            try await self.connection.connect()
            try Task.checkCancellation()
            self.isDriveConnected = true
            self.needsReconnect = false
            self.status = "Checking Drive folders…"
            let token = try await self.connection.uploadToken()
            let remote = DriveProjectRemote(transport: .live, checkPrivacy: DriveSharingPrivacy.check, token: token)
            var unavailable: [DriveProjectFolder] = []
            for folder in folders {
                do { _ = try await remote.validateFolder(id: folder.id, access: .read) }
                catch DriveProjectError.folderUnavailable { unavailable.append(folder) }
                catch GoogleDriveSharingError.http(let code) where code == 403 || code == 404 { unavailable.append(folder) }
            }
            try Task.checkCancellation()
            self.unavailableFolderIDs = Set(unavailable.map(\.id))
            self.status = Self.reconnectSummary(unavailable: unavailable)
        }
    }

    nonisolated static func reconnectSummary(unavailable: [DriveProjectFolder]) -> String {
        switch unavailable.count {
        case 0: "Google Drive is connected again."
        case 1: "Google Drive is connected again, but “\(unavailable[0].name)” can’t be opened. Choose it again to keep syncing."
        default: "Google Drive is connected again, but \(unavailable.count) folders can’t be opened. Choose them again to keep syncing."
        }
    }

    func markAvailable(_ folder: DriveProjectFolder) { unavailableFolderIDs.remove(folder.id) }

    /// Signs out, revokes the grant and forgets every device-local Drive sharing setting.
    func disconnect(onDisconnected: @escaping () -> Void) async {
        if let running = work {
            running.cancel()
            await running.value
        }
        start("Disconnecting…") {
            try await self.connection.disconnect()
            self.isDriveConnected = false
            self.needsReconnect = false
            self.unavailableFolderIDs = []
            self.projectStates = [:]
            self.lastCheckedAt = nil
            self.clearConflicts()
            onDisconnected()
            self.status = "Google Drive disconnected. Sharing settings on this device were removed."
        }
    }

    // MARK: Local package folders

    func chooseSource(_ url: URL, remember: @escaping (Data?) -> Void) {
        start("Reading source folder…") {
            try await self.loadSource(url)
            remember(await self.source.remember(url))
        }
    }

    /// Reopens a remembered folder; `remember` receives a replacement bookmark when the stored one was stale.
    func restoreSource(_ bookmark: Data, remember: @escaping (Data) -> Void) {
        start("Reading source folder…") {
            do {
                let restored = try await self.source.resolve(bookmark)
                if let refreshed = restored.refreshedBookmark { remember(refreshed) }
                try await self.loadSource(restored.url)
            } catch {
                self.status = "Choose the source folder again to restore access."
            }
        }
    }

    private func loadSource(_ url: URL) async throws {
        let packages = try await source.packages(in: url)
        try Task.checkCancellation()
        sourceName = url.lastPathComponent
        self.packages = packages
        status = nil
    }

    func importPackage(_ url: URL, storage: LibraryStorage, container: ModelContainer, onImported: @escaping (UUID) -> Void) {
        start("Importing recording…") {
            let staged = try await self.source.stage(url, storage: storage)
            let id = try RecordingPackageImport.commit(staged, storage: storage, container: container)
            self.status = "Recording imported."
            onImported(id)
        }
    }

    // MARK: Drive folders

    func recoverSharingFolder(from folder: DriveProjectFolder) async throws -> DriveProjectFolder? {
        try await connection.sharingParent(of: folder)
    }

    func chooseDestination(access: DriveFolderAccess, requirePublishedProject: Bool = false,
                           _ selected: @escaping (DriveProjectFolder) -> Void) {
        start("Waiting for Google Drive…", cloud: true) {
            let folder = try await self.connection.chooseFolder(access: access)
            try Task.checkCancellation()
            self.isDriveConnected = true
            self.needsReconnect = false
            if requirePublishedProject, folder.publishedProjectID == nil {
                throw DriveProjectError.selectPublishedProject
            }
            self.unavailableFolderIDs.remove(folder.id)
            selected(folder)
            self.status = nil
        }
    }

    func importDriveProject(storage: LibraryStorage, container: ModelContainer,
                            onImported: @escaping (DriveProjectFolder, UUID) -> Void) {
        start("Choose a published project folder in Drive…", cloud: true) {
            let folder = try await self.connection.chooseFolder(access: .read)
            guard let id = folder.publishedProjectID else { throw DriveProjectError.selectPublishedProject }
            self.isDriveConnected = true
            self.needsReconnect = false
            self.status = "Importing Drive Project…"
            let token = try await self.connection.uploadToken()
            let remote = DriveProjectRemote(transport: .live, checkPrivacy: DriveSharingPrivacy.check, token: token)
            let result = try await DriveProjectSync.shared.importProject(folder, remote: remote, storage: storage, container: container)
            try Task.checkCancellation()
            onImported(folder, id)
            self.status = Self.importSummary(result, folderName: folder.name)
        }
    }

    nonisolated static func importSummary(_ result: DriveProjectSync.ImportResult, folderName: String) -> String {
        var lines: [String] = []
        var imported: [String] = []
        if result.importedRecordings > 0 {
            imported.append(result.importedRecordings == 1 ? "1 recording" : "\(result.importedRecordings) recordings")
        }
        if result.importedSources > 0 {
            imported.append(result.importedSources == 1 ? "1 document" : "\(result.importedSources) documents")
        }
        lines.append(imported.isEmpty
                     ? "Nothing new to import from “\(folderName)”."
                     : "Imported \(imported.joined(separator: " and ")) from “\(folderName)”.")
        if !result.skipped.isEmpty {
            let items = result.skipped.map { "\($0.name) (\(skipReason($0.reason)))" }
            lines.append("Skipped \(result.skipped.count): " + items.joined(separator: ", ") + ".")
        }
        if !result.failures.isEmpty {
            let items = result.failures.map { "\($0.name): \($0.message)" }
            lines.append("Couldn’t import \(result.failures.count): " + items.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }

    private nonisolated static func skipReason(_ reason: DriveProjectSync.ImportResult.SkipReason) -> String {
        switch reason {
        case .alreadyInProject: "already in this project"
        case .belongsToOtherProject: "already in another project"
        case .duplicateOnDrive: "duplicate copy on Drive"
        }
    }

    // MARK: Sync

    /// Checks whether each group's projects match Drive without changing anything.
    func verify(_ groups: [DriveProjectLinks.Group], storage: LibraryStorage, container: ModelContainer,
                refreshed: @escaping (DriveProjectFolder) -> Void) async {
        guard work == nil, !Task.isCancelled else { return }
        start("Checking Drive versions…", cloud: true) {
            let groups = await self.allowed(groups)
            let token = try await self.connection.uploadToken()
            let remote = DriveProjectRemote(transport: .live, checkPrivacy: DriveSharingPrivacy.check, token: token)
            var failures: [String] = []
            for group in groups {
                let snapshots = try await DriveProjectSnapshot.make(projectIDs: group.projectIDs, storage: storage,
                                                                    container: container)
                guard !snapshots.isEmpty else { continue }
                do {
                    let result = try await DriveProjectSync.shared.verify(projects: snapshots, folder: group.folder,
                                                                          remote: remote) { name in
                        await MainActor.run { self.status = "Checking \(name)…" }
                    }
                    try Task.checkCancellation()
                    refreshed(result.folder)
                    for snapshot in snapshots {
                        self.projectStates[snapshot.id] = .init(
                            folder: result.folder, checkedAt: result.checkedAt,
                            isCurrent: result.projects[snapshot.id] ?? false,
                            unfinished: result.unfinishedByProject[snapshot.id] ?? 0)
                    }
                } catch {
                    try Self.rethrowUnlessTransient(error)
                    failures.append("\(group.folder.name): \(error.localizedDescription)")
                }
            }
            self.lastCheckedAt = .now
            self.status = nil
            if !failures.isEmpty { self.error = failures.joined(separator: "\n") }
        }
        await awaitWork(projectIDs: groups.flatMap(\.projectIDs), name: "Google Drive check")
    }

    /// Syncs every group with its Drive folder, one run per destination.
    /// - Parameter synced: called with each folder as currently named on Drive and the projects synced into it.
    func sync(_ groups: [DriveProjectLinks.Group], storage: LibraryStorage, container: ModelContainer,
              resolutions: [DriveProjectSync.Resolution] = [], trigger: SyncTrigger = .manual,
              synced: @escaping (DriveProjectFolder, [UUID]) -> Void) async {
        guard work == nil, !Task.isCancelled else { return }
        start("Checking Drive…", cloud: true, quietTransientErrors: trigger == .automatic) {
            let groups = await self.allowed(groups)
            let token = try await self.connection.uploadToken()
            let remote = DriveProjectRemote(transport: .live, checkPrivacy: DriveSharingPrivacy.check, token: token)
            var total = DriveProjectSync.Result()
            var groupFailures: [String] = []
            var newConflicts: [DriveProjectSync.Conflict] = []
            for group in groups {
                let groupResolutions = resolutions.filter {
                    self.conflictFolders[$0.conflict.id]?.isSameFolder(as: group.folder) == true
                }
                if !resolutions.isEmpty && groupResolutions.isEmpty { continue }
                let snapshots = try await DriveProjectSnapshot.make(projectIDs: group.projectIDs, storage: storage,
                                                                    container: container)
                guard !snapshots.isEmpty else { continue }
                let result: DriveProjectSync.Result
                do {
                    result = try await DriveProjectSync.shared.run(
                        projects: snapshots, folder: group.folder, remote: remote, storageRoot: storage.rootURL,
                        applyTranscript: { incoming, snapshot, projectID in
                            try RecordingPackageImport.applySyncedTranscript(incoming, replacing: snapshot, projectID: projectID,
                                                                             storage: storage, container: container)
                        }, resolutions: groupResolutions
                    ) { name, fraction in
                        await MainActor.run {
                            self.status = name
                            self.progress = fraction
                        }
                    }
                } catch {
                    try Self.rethrowUnlessTransient(error)
                    groupFailures.append("\(group.folder.name): \(error.localizedDescription)")
                    for id in group.projectIDs { self.projectStates[id] = nil }
                    continue
                }
                try Task.checkCancellation()
                let folder = result.destination ?? group.folder
                synced(folder, snapshots.map(\.id))
                let owners = Self.owners(of: result.conflicts, in: snapshots)
                for conflict in result.conflicts {
                    self.conflictFolders[conflict.id] = folder
                    if let owner = owners[conflict.id] { self.conflictOwners[conflict.id] = owner }
                }
                newConflicts += result.conflicts
                total.uploaded += result.uploaded
                total.downloaded += result.downloaded
                total.unchanged += result.unchanged
                total.unfinished += result.unfinished
                total.failures += result.failures
                total.resolvedConflictIDs.formUnion(result.resolvedConflictIDs)
                if resolutions.isEmpty {
                    let conflicted = Set(owners.values)
                    for snapshot in snapshots {
                        let current = result.failures.isEmpty && !conflicted.contains(snapshot.id)
                        // Unattributed failures leave the state unknown rather than claiming "up to date".
                        if !current && !conflicted.contains(snapshot.id) { self.projectStates[snapshot.id] = nil; continue }
                        self.projectStates[snapshot.id] = .init(
                            folder: folder, checkedAt: .now, isCurrent: current,
                            unfinished: result.unfinishedByProject[snapshot.id] ?? 0)
                    }
                }
            }
            total.conflicts = newConflicts
            self.applyConflicts(total, resolutions: resolutions)
            self.lastCheckedAt = .now
            let nonConflictFailures = total.failures.filter {
                !$0.hasSuffix(DriveProjectError.conflictingVersion.localizedDescription)
            } + groupFailures
            self.status = Self.syncSummary(total, conflicts: self.conflicts.count, failures: nonConflictFailures.count,
                                           at: .now, trigger: trigger)
            if !nonConflictFailures.isEmpty, trigger == .manual {
                self.error = nonConflictFailures.joined(separator: "\n")
            }
        }
        await awaitWork(projectIDs: groups.flatMap(\.projectIDs), name: "Google Drive sync")
    }

    private func applyConflicts(_ result: DriveProjectSync.Result, resolutions: [DriveProjectSync.Resolution]) {
        guard !resolutions.isEmpty else {
            conflicts = result.conflicts
            let ids = Set(conflicts.map(\.id))
            conflictFolders = conflictFolders.filter { ids.contains($0.key) }
            conflictOwners = conflictOwners.filter { ids.contains($0.key) }
            return
        }
        let refreshedByID = Dictionary(result.conflicts.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var updated: [DriveProjectSync.Conflict] = []
        for existing in conflicts where !result.resolvedConflictIDs.contains(existing.id) {
            updated.append(refreshedByID[existing.id] ?? existing)
        }
        for refreshed in result.conflicts where !updated.contains(where: { $0.id == refreshed.id }) {
            updated.append(refreshed)
        }
        conflicts = updated
        if !result.conflicts.isEmpty {
            let driveChoices = Set(resolutions.filter { $0.choice == .drive }.map(\.conflict.id))
            if result.conflicts.contains(where: { driveChoices.contains($0.id) && !$0.canDownload }) {
                error = "One or more Drive versions changed audio, attachments, or transcript segments and cannot update the local recording in place. Choose Use Local or Keep Both."
            } else {
                error = "One or more files changed since these conflicts were detected. Review the updated conflicts and apply again."
            }
        }
    }

    nonisolated static func syncSummary(_ result: DriveProjectSync.Result, conflicts: Int, failures: Int,
                            at date: Date, trigger: SyncTrigger) -> String {
        var parts: [String] = []
        if result.uploaded > 0 { parts.append("\(result.uploaded) uploaded") }
        if result.downloaded > 0 { parts.append("\(result.downloaded) downloaded") }
        if result.unchanged > 0 { parts.append("\(result.unchanged) up to date") }
        if result.unfinished > 0 {
            parts.append(result.unfinished == 1 ? "1 recording not transcribed yet" : "\(result.unfinished) recordings not transcribed yet")
        }
        var text = "Synced at \(date.formatted(date: .omitted, time: .shortened))"
        if !parts.isEmpty { text += " · " + parts.joined(separator: ", ") }
        if conflicts > 0 { text += " · \(conflicts) \(conflicts == 1 ? "conflict needs" : "conflicts need") attention" }
        if failures > 0 {
            text += " · \(failures) \(failures == 1 ? "item" : "items") couldn’t sync"
            if trigger == .automatic { text += ", retrying in 5 minutes" }
        }
        return text + "."
    }

    /// Maps conflicts to the local project owning the conflicting recording (`r-`) or document (`s-`).
    nonisolated static func owners(of conflicts: [DriveProjectSync.Conflict], in snapshots: [DriveProjectSnapshot]) -> [String: UUID] {
        var byKey: [String: UUID] = [:]
        for snapshot in snapshots {
            for recording in snapshot.recordings { byKey["r-" + recording.recordingID.uuidString] = snapshot.id }
            for source in snapshot.sources { byKey["s-" + source.id.uuidString] = snapshot.id }
        }
        var owners: [String: UUID] = [:]
        for conflict in conflicts {
            if let owner = byKey[conflict.key] { owners[conflict.id] = owner }
        }
        return owners
    }

    /// Drops projects that are being deleted so no new Drive work starts for them.
    private func allowed(_ groups: [DriveProjectLinks.Group]) async -> [DriveProjectLinks.Group] {
        var result: [DriveProjectLinks.Group] = []
        for var group in groups {
            var kept: [UUID] = []
            for id in group.projectIDs where !(await registry.isDeleting(projectID: id)) { kept.append(id) }
            group.projectIDs = kept
            if !kept.isEmpty { result.append(group) }
        }
        return result
    }

    /// Registers the running work for project deletion, keeps it alive briefly in the background on iOS,
    /// and forwards cancellation of the caller.
    private func awaitWork(projectIDs: [UUID], name: String) async {
        guard let task = work else { return }
        await registry.register(projectIDs: Set(projectIDs), task: task)
        let end = backgroundWork.extend(name) { task.cancel() }
        defer { end() }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated static func severity(of error: any Error) -> ErrorSeverity {
        switch error {
        case GoogleDriveSharingError.signInRequired, GoogleDriveSharingError.consent, GoogleDriveSharingError.http(401):
            .reconnect
        case GoogleDriveSharingError.localOnly, GoogleDriveSharingError.configuration,
             DriveProjectError.selectOneProject, DriveProjectError.selectPublishedProject, DriveProjectError.noProjects,
             DriveProjectError.folderReadOnly, DriveProjectError.sharedDriveUnsupported, DriveProjectError.folderChanged:
            .fatal
        default:
            .transient
        }
    }

    private nonisolated static func rethrowUnlessTransient(_ error: any Error) throws {
        if error is CancellationError || Task.isCancelled || severity(of: error) != .transient { throw error }
    }

    func cancel() { work?.cancel() }
    func cancelCloud() { if isCloudWork { cancel() } }

    private func start(_ label: String, cloud: Bool = false, quietTransientErrors: Bool = false,
                       action: @escaping @MainActor () async throws -> Void) {
        guard work == nil else { return }
        status = label
        error = nil
        stopsAutoSync = false
        isCloudWork = cloud
        work = Task {
            defer { work = nil; isCloudWork = false; progress = nil }
            do { try await action() }
            catch {
                if Task.isCancelled || error is CancellationError { status = "Cancelled."; return }
                let severity = Self.severity(of: error)
                stopsAutoSync = severity != .transient
                if severity == .reconnect {
                    if error as? GoogleDriveSharingError == .consent { await refreshConnection() }
                    else { needsReconnect = true; await refreshConnection() }
                }
                if quietTransientErrors && severity == .transient {
                    let time = Date.now.formatted(date: .omitted, time: .shortened)
                    status = "Couldn’t sync at \(time). Retrying in 5 minutes. \(error.localizedDescription)"
                } else {
                    self.error = error.localizedDescription
                    status = nil
                }
            }
        }
    }
}
