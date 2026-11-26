import Foundation
import Testing
@testable import AudioNotes

struct DriveProjectLinksTests {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "DriveProjectLinksTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    private func encode(_ folder: DriveProjectFolder) throws -> Data { try JSONEncoder().encode(folder) }

    @Test func migratesLegacyLinkAndSharingFolderThenRemovesLegacyKeys() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let local = UUID()
        let linked = DriveProjectFolder(id: "linked", name: "Team Project", publishedProjectID: UUID())
        let sharing = DriveProjectFolder(id: "sharing", name: "Shared")
        defaults.set(local.uuidString, forKey: DriveProjectLinks.Legacy.linkedLocalID)
        defaults.set(try encode(linked), forKey: DriveProjectLinks.Legacy.destination)
        defaults.set(try encode(sharing), forKey: DriveProjectLinks.Legacy.sharingDestination)

        let links = DriveProjectLinks.load(from: defaults)

        #expect(links[local] == DriveProjectLink(folder: linked, role: .linked))
        let storedSharing = try #require(defaults.data(forKey: DriveProjectLinks.sharingFolderKey))
        #expect(try JSONDecoder().decode(DriveProjectFolder.self, from: storedSharing) == sharing)
        #expect(defaults.object(forKey: DriveProjectLinks.Legacy.linkedLocalID) == nil)
        #expect(defaults.object(forKey: DriveProjectLinks.Legacy.destination) == nil)
        #expect(defaults.object(forKey: DriveProjectLinks.Legacy.sharingDestination) == nil)
        // Idempotent.
        #expect(DriveProjectLinks.load(from: defaults) == links)
    }

    @Test func migratesUnlinkedLegacyDestinationAsSharingFolder() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let sharing = DriveProjectFolder(id: "sharing", name: "Shared")
        defaults.set(try encode(sharing), forKey: DriveProjectLinks.Legacy.destination)

        #expect(DriveProjectLinks.load(from: defaults).isEmpty)
        let stored = try #require(defaults.data(forKey: DriveProjectLinks.sharingFolderKey))
        #expect(try JSONDecoder().decode(DriveProjectFolder.self, from: stored) == sharing)
        #expect(defaults.object(forKey: DriveProjectLinks.Legacy.destination) == nil)
    }

    @Test func secondLinkDoesNotReplaceTheFirstAndRoundTrips() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = UUID(), second = UUID()
        var links = DriveProjectLinks()
        links.set(.init(id: "a", name: "A", publishedProjectID: first), role: .linked, for: first)
        links.set(.init(id: "b", name: "B", publishedProjectID: second), role: .linked, for: second)
        links.save(to: defaults)

        let loaded = DriveProjectLinks.load(from: defaults)
        #expect(loaded.entries.count == 2)
        #expect(loaded[first]?.folderID == "a")
        #expect(loaded[second]?.folderID == "b")

        DriveProjectLinks.remove(projectID: first, from: defaults)
        #expect(DriveProjectLinks.load(from: defaults)[first] == nil)
        #expect(DriveProjectLinks.load(from: defaults)[second] != nil)
    }

    @Test func groupsSelectedProjectsByDestination() {
        let sharing = DriveProjectFolder(id: "sharing", name: "Shared")
        let a = UUID(), b = UUID(), linked = UUID(), pinned = UUID()
        var links = DriveProjectLinks()
        links.set(.init(id: "team", name: "Team", publishedProjectID: UUID()), role: .linked, for: linked)
        links.set(.init(id: "old", name: "Old"), role: .shared, for: pinned)

        let groups = links.groups(for: [a, linked, b, pinned], sharingFolder: sharing)

        #expect(groups.map(\.folder.id) == ["sharing", "team", "old"])
        #expect(groups[0].projectIDs == [a, b])
        #expect(groups[1].projectIDs == [linked])
        #expect(links.groups(for: [a], sharingFolder: nil).isEmpty)
    }

    @Test func refreshKeepsIdentityAndUpdatesRenamedFolders() {
        let id = UUID(), published = UUID()
        var links = DriveProjectLinks()
        links.set(.init(id: "team", name: "Old Name", publishedProjectID: published), role: .linked, for: id)
        links.refresh(.init(id: "team", name: "New Name", publishedProjectID: published))
        #expect(links[id]?.name == "New Name")
        links.refresh(.init(id: "team", name: "Other", publishedProjectID: nil))
        #expect(links[id]?.name == "New Name")
        #expect(links.project(linkedTo: .init(id: "team", name: "Anything", publishedProjectID: published)) == id)
    }

    @Test func importSummaryListsImportedSkippedAndFailedItems() {
        var result = DriveProjectSync.ImportResult()
        result.importedRecordings = 2
        result.importedSources = 1
        result.skipped = [.init(name: "Notes.pdf", reason: .alreadyInProject),
                          .init(name: "Call", reason: .belongsToOtherProject)]
        result.failures = [.init(name: "Broken", message: "Unreadable.")]

        let text = DriveProjectsModel.importSummary(result, folderName: "Team")

        #expect(text.contains("Imported 2 recordings and 1 document from “Team”."))
        #expect(text.contains("Skipped 2: Notes.pdf (already in this project), Call (already in another project)."))
        #expect(text.contains("Couldn’t import 1: Broken: Unreadable."))
        #expect(DriveProjectsModel.importSummary(.init(), folderName: "Team") == "Nothing new to import from “Team”.")
    }

    @Test func classifiesErrorsForReconnectAndAutoSync() {
        #expect(DriveProjectsModel.severity(of: GoogleDriveSharingError.signInRequired) == .reconnect)
        #expect(DriveProjectsModel.severity(of: GoogleDriveSharingError.http(401)) == .reconnect)
        #expect(DriveProjectsModel.severity(of: GoogleDriveSharingError.consent) == .reconnect)
        #expect(DriveProjectsModel.severity(of: GoogleDriveSharingError.localOnly) == .fatal)
        #expect(DriveProjectsModel.severity(of: GoogleDriveSharingError.http(503)) == .transient)
        #expect(DriveProjectsModel.severity(of: URLError(.notConnectedToInternet)) == .transient)
        #expect(DriveProjectsModel.severity(of: DriveProjectError.folderUnavailable) == .transient)
    }

    @Test func syncSummaryReportsUnfinishedConflictsAndRetries() {
        var result = DriveProjectSync.Result()
        result.uploaded = 1
        result.unfinished = 2
        let date = Date(timeIntervalSince1970: 0)
        let text = DriveProjectsModel.syncSummary(result, conflicts: 1, failures: 1, at: date, trigger: .automatic)
        #expect(text.contains("1 uploaded, 2 recordings not transcribed yet"))
        #expect(text.contains("1 conflict needs attention"))
        #expect(text.hasSuffix("1 item couldn’t sync, retrying in 5 minutes."))
    }

    @Test func deletionBlocksNewRegistrations() async {
        let registry = DriveProjectSyncRegistry()
        let project = UUID()
        await registry.beginDeletion(projectID: project)
        let task = Task<Void, Never> { while !Task.isCancelled { await Task.yield() } }
        await registry.register(projectIDs: [project], task: task)
        await task.value
        #expect(task.isCancelled)
        #expect(await registry.isDeleting(projectID: project))
        await registry.endDeletion(projectID: project)
        #expect(await !registry.isDeleting(projectID: project))
    }
}
