import Foundation
import SwiftData
import Testing
@testable import AudioNotes

@MainActor
struct DriveProjectSyncTests {
    @Test func detectsIndependentEditsFromTheLastCommonVersion() {
        let baseline = DriveProjectSync.Version(name: "Recording.soniquill", checksum: "baseline")
        let mac = DriveProjectSync.Version(name: baseline.name, checksum: "mac")
        let phone = DriveProjectSync.Version(name: baseline.name, checksum: "phone")
        #expect(mac.change(comparedTo: baseline, baseline: baseline) == .upload)
        #expect(baseline.change(comparedTo: phone, baseline: baseline) == .download)
        #expect(mac.change(comparedTo: phone, baseline: baseline) == .conflict)
        #expect(mac.change(comparedTo: phone, baseline: nil) == .conflict)
        #expect(mac.change(comparedTo: mac, baseline: nil) == .unchanged)
    }

    @Test func publishesProjectOriginalsAndReusesDriveIDsOnLaterRuns() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let project = Project(name: "Shared project")
        let source = RecordingSource(type: .document, displayName: "Notes", originalFilename: "Notes.txt",
                                     localFileReference: "original.txt")
        let image = RecordingSource(type: .image, displayName: "Image", originalFilename: "Image.png",
                                    localFileReference: "original.png")
        project.sources = [source, image]
        let sourceURL = workspace.storage.sourceURL(source)
        let imageURL = workspace.storage.sourceURL(image)
        for url in [sourceURL, imageURL] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data("project notes".utf8).write(to: sourceURL)
        try Data([137, 80, 78, 71]).write(to: imageURL)
        let audio = try workspace.makeAudio()
        try FileManager.default.createDirectory(at: workspace.storage.recordingsURL, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: audio, to: workspace.storage.recordingURL(fileName: audio.lastPathComponent))
        let completed = Recording(title: "Completed", audioFileName: audio.lastPathComponent,
                                  originalFileName: audio.lastPathComponent, duration: 1)
        let transcript = Transcript(languageCode: "cs")
        transcript.segments = [TranscriptSegment(position: 0, startTime: 0, endTime: 1, text: "Hotovo", speaker: "Eva")]
        completed.transcript = transcript
        project.recordings = [completed, Recording(title: "Waiting", audioFileName: "pending.wav",
                                                   originalFileName: "pending.wav", duration: 1)]
        let mocked = MockDrive(root: "root_" + UUID().uuidString)
        let root = mocked.root
        let remote = DriveProjectRemote(transport: DriveHTTPTransport(send: { try await mocked.send($0) }),
                                        checkPrivacy: {}, token: { _ in "token" })
        let sync = DriveProjectSync()
        let snapshot = try DriveProjectSnapshot(project: project, storage: workspace.storage)
        let folder = DriveProjectFolder(id: root, name: "Shared folder")
        let missing = try await sync.verify(projects: [snapshot], folder: folder, remote: remote) { _ in }
        #expect(missing.projects[project.id] == false)
        #expect(await mocked.folderCreates == 0)
        let first = try await sync.run(projects: [snapshot], folder: folder, remote: remote) { _, _ in }
        #expect(first.uploaded == 3)
        #expect(first.unfinished == 1)
        #expect(first.failures.isEmpty)
        let second = try await sync.run(projects: [snapshot], folder: folder, remote: remote) { _, _ in }
        #expect(second.unchanged == 3)
        let current = try await sync.verify(projects: [snapshot], folder: folder, remote: remote) { _ in }
        #expect(current.projects[project.id] == true)
        #expect(current.unfinished == 1)
        try Data("updated project notes".utf8).write(to: sourceURL)
        let changed = try await sync.verify(projects: [snapshot], folder: folder, remote: remote) { _ in }
        #expect(changed.projects[project.id] == false)
        #expect(await mocked.updates == 0)
        let third = try await sync.run(projects: [snapshot], folder: folder, remote: remote) { _, _ in }
        #expect(third.uploaded == 1, Comment(rawValue: third.failures.joined(separator: "\n")))
        #expect(third.unchanged == 2)
        #expect(await mocked.creates == 3)
        #expect(await mocked.updates == 1)
        #expect(await mocked.folderCreates == 1)

        transcript.segments[0].text = "Opravený přepis"
        let editedSnapshot = try DriveProjectSnapshot(project: project, storage: workspace.storage)
        let edited = try await sync.verify(projects: [editedSnapshot], folder: folder, remote: remote) { _ in }
        #expect(edited.projects[project.id] == false)
        let fourth = try await sync.run(projects: [editedSnapshot], folder: folder, remote: remote) { _, _ in }
        #expect(fourth.uploaded == 1, Comment(rawValue: fourth.failures.joined(separator: "\n")))
        #expect(fourth.unchanged == 2)
        #expect(await mocked.creates == 3)
        #expect(await mocked.updates == 2)

        await mocked.modifyRecordingOnDrive()
        let remoteEdit = try await sync.run(projects: [editedSnapshot], folder: folder, remote: remote) { _, _ in }
        #expect(remoteEdit.failures.count == 1)
        #expect(remoteEdit.failures.first?.contains(DriveProjectError.remoteVersionChanged.localizedDescription) == true)
        transcript.segments[0].text = "Lokální úprava"
        let localEdit = try DriveProjectSnapshot(project: project, storage: workspace.storage)
        let conflict = try await sync.run(projects: [localEdit], folder: folder, remote: remote) { _, _ in }
        #expect(conflict.failures.count == 1)
        #expect(conflict.failures.first?.contains(DriveProjectError.conflictingVersion.localizedDescription) == true)
        #expect(await mocked.updates == 2)
        transcript.segments[0].text = "Opravený přepis"

        let container = try workspace.storage.makeContainer(inMemory: true)
        container.mainContext.insert(project)
        try container.mainContext.save()
        let changedPackage = workspace.root.appending(path: "Remote.soniquill")
        transcript.segments[0].text = "Úprava z druhého zařízení"
        let changedRecording = try RecordingPackageSnapshot(recording: completed, selected: [], storage: workspace.storage)
        try await RecordingPackageCodec().export(changedRecording, to: changedPackage)
        transcript.segments[0].text = "Opravený přepis"
        try container.mainContext.save()
        try await mocked.replaceRecordingOnDrive(with: changedPackage)
        let storage = workspace.storage
        let apply: DriveProjectSync.ApplyTranscript = { incoming, snapshot, projectID in
            try RecordingPackageImport.applySyncedTranscript(incoming, replacing: snapshot, projectID: projectID,
                                                             storage: storage, container: container)
        }
        let pull = try await sync.run(
            projects: [editedSnapshot], folder: folder, remote: remote, storageRoot: storage.rootURL,
            applyTranscript: apply
        ) { _, _ in }
        #expect(pull.downloaded == 1, Comment(rawValue: pull.failures.joined(separator: "\n")))
        #expect(pull.uploaded == 0)
        let saved = try ModelContext(container).fetch(FetchDescriptor<TranscriptSegment>())
        #expect(saved.first?.id == transcript.segments[0].id)
        #expect(saved.first?.text == "Úprava z druhého zařízení")
        #expect(await mocked.updates == 2)

        let linkedFolderID = try #require(await mocked.projectFolderID())
        let linkedFolder = try await remote.validateFolder(id: linkedFolderID)
        #expect(linkedFolder.publishedProjectID == project.id)
        let receiver = try TestWorkspace()
        defer { receiver.cleanUp() }
        let receiverContainer = try receiver.storage.makeContainer(inMemory: true)
        let imported = try await sync.importProject(linkedFolder, remote: remote, storage: receiver.storage,
                                                    container: receiverContainer)
        #expect(imported == 1)
        let received = try #require(receiverContainer.mainContext.fetch(FetchDescriptor<Project>()).first)
        #expect(received.id == project.id)
        #expect(received.recordings.map(\.id) == [completed.id])
        #expect(Set(received.sources.map(\.id)) == [source.id, image.id])
        #expect(received.recordings.first?.transcript?.segments.first?.text == "Úprava z druhého zařízení")
        let retried = try await sync.importProject(linkedFolder, remote: remote, storage: receiver.storage,
                                                   container: receiverContainer)
        #expect(retried == 0)
        let otherProject = Project(name: "Local project on another device")
        let pulledRecording = Recording(id: completed.id, title: completed.title,
                                        audioFileName: completed.audioFileName, originalFileName: completed.originalFileName,
                                        duration: completed.duration)
        let pulledTranscript = Transcript(languageCode: transcript.languageCode, createdAt: transcript.createdAt)
        pulledTranscript.segments = [TranscriptSegment(id: transcript.segments[0].id, position: 0,
            startTime: 0, endTime: 1, text: "Úprava z druhého zařízení", speaker: "Eva")]
        pulledRecording.transcript = pulledTranscript
        otherProject.recordings = [pulledRecording]
        let linked = try DriveProjectSnapshot(project: otherProject, storage: workspace.storage)
        let linkedResult = try await sync.run(projects: [linked], folder: linkedFolder, remote: remote) { _, _ in }
        #expect(linkedResult.unchanged == 1, Comment(rawValue: linkedResult.failures.joined(separator: "\n")))
        #expect(linkedResult.uploaded == 0)
        #expect(await mocked.folderCreates == 1)

        await mocked.modifyRecordingOnDrive()
        pulledTranscript.segments[0].text = "Lokální konflikt"
        let divergent = try DriveProjectSnapshot(project: otherProject, storage: workspace.storage)
        let found = try await sync.run(projects: [divergent], folder: linkedFolder, remote: remote) { _, _ in }
        let pending = try #require(found.conflicts.first)
        let kept = try await sync.run(projects: [divergent], folder: linkedFolder, remote: remote,
                                      resolution: .init(conflict: pending, choice: .both)) { _, _ in }
        #expect(kept.uploaded == 1)
        #expect(await mocked.creates == 4)
        #expect(await mocked.updates == 2)
        let repeated = try await sync.run(projects: [divergent], folder: linkedFolder, remote: remote) { _, _ in }
        #expect(repeated.unchanged == 1)
        #expect(repeated.conflicts.isEmpty)

        pulledTranscript.segments[0].text = "Změna po zobrazení konfliktu"
        let newer = try DriveProjectSnapshot(project: otherProject, storage: workspace.storage)
        let stale = try await sync.run(projects: [newer], folder: linkedFolder, remote: remote,
                                       resolution: .init(conflict: pending, choice: .local)) { _, _ in }
        #expect(stale.conflicts.count == 1)
        #expect(await mocked.updates == 2)
        let refreshed = try #require(stale.conflicts.first)
        let overwritten = try await sync.run(projects: [newer], folder: linkedFolder, remote: remote,
                                             resolution: .init(conflict: refreshed, choice: .local)) { _, _ in }
        #expect(overwritten.uploaded == 1)
        #expect(await mocked.updates == 3)
        #expect(await mocked.creates == 4)

        let currentContext = ModelContext(container)
        let completedID = completed.id
        let localRecording = try #require(
            currentContext.fetch(FetchDescriptor<Recording>(predicate: #Predicate { $0.id == completedID })).first
        )
        let localProject = try #require(localRecording.project)
        localRecording.transcript?.segments[0].text = "Rozhodnutí pro Drive"
        try currentContext.save()
        try await mocked.replaceRecordingOnDrive(with: changedPackage)
        let choosingDrive = try DriveProjectSnapshot(project: localProject, storage: storage)
        let detected = try await sync.run(projects: [choosingDrive], folder: linkedFolder, remote: remote,
                                          storageRoot: storage.rootURL, applyTranscript: apply) { _, _ in }
        let downloadConflict = try #require(detected.conflicts.first)
        let chosen = try await sync.run(projects: [choosingDrive], folder: linkedFolder, remote: remote,
                                        storageRoot: storage.rootURL, applyTranscript: apply,
                                        resolution: .init(conflict: downloadConflict, choice: .drive)) { _, _ in }
        #expect(chosen.downloaded == 1, Comment(rawValue: chosen.failures.joined(separator: "\n")))
        #expect(await mocked.updates == 3)
        let resolved = try ModelContext(container).fetch(FetchDescriptor<TranscriptSegment>())
        #expect(resolved.first?.text == "Úprava z druhého zařízení")

        let attachmentPackage = workspace.root.appending(path: "RemoteWithAttachment.soniquill")
        let extraAttachment = RecordingSource(type: .document, displayName: "Extra", originalFilename: "extra.txt",
                                              localFileReference: "original.txt")
        try FileManager.default.createDirectory(at: storage.sourceDirectory(id: extraAttachment.id), withIntermediateDirectories: true)
        try Data("extra".utf8).write(to: storage.sourceURL(extraAttachment))
        let remoteCopy = Recording(id: completed.id, title: completed.title, audioFileName: completed.audioFileName,
                                   originalFileName: completed.originalFileName, duration: completed.duration)
        let remoteCopyTranscript = Transcript(languageCode: transcript.languageCode, createdAt: transcript.createdAt)
        remoteCopyTranscript.segments = [TranscriptSegment(id: transcript.segments[0].id, position: 0,
            startTime: 0, endTime: 1, text: "Vzdálená změna s přílohou", speaker: "Eva")]
        remoteCopy.transcript = remoteCopyTranscript
        remoteCopy.sources = [extraAttachment]
        let incompatibleRecording = try RecordingPackageSnapshot(recording: remoteCopy, selected: [extraAttachment.id], storage: storage)
        try await RecordingPackageCodec().export(incompatibleRecording, to: attachmentPackage)
        try await mocked.replaceRecordingOnDrive(with: attachmentPackage)

        localRecording.transcript?.segments[0].text = "Lokální verze před nekompatibilním stažením"
        try currentContext.save()
        let incompatibleLocal = try DriveProjectSnapshot(project: localProject, storage: storage)
        let incompatibleDetected = try await sync.run(projects: [incompatibleLocal], folder: linkedFolder, remote: remote,
                                                      storageRoot: storage.rootURL, applyTranscript: apply) { _, _ in }
        let initialIncompatible = try #require(incompatibleDetected.conflicts.first)
        #expect(initialIncompatible.canDownload == true)
        let rejectedDrive = try await sync.run(projects: [incompatibleLocal], folder: linkedFolder, remote: remote,
                                               storageRoot: storage.rootURL, applyTranscript: apply,
                                               resolution: .init(conflict: initialIncompatible, choice: .drive)) { _, _ in }
        let updatedIncompatible = try #require(rejectedDrive.conflicts.first)
        #expect(updatedIncompatible.canDownload == false)
        let afterRejected = try ModelContext(container).fetch(FetchDescriptor<TranscriptSegment>())
        #expect(afterRejected.first?.text == "Lokální verze před nekompatibilním stažením")

        let resolvedWithLocal = try await sync.run(projects: [incompatibleLocal], folder: linkedFolder, remote: remote,
                                                   storageRoot: storage.rootURL, applyTranscript: apply,
                                                   resolution: .init(conflict: updatedIncompatible, choice: .local)) { _, _ in }
        #expect(resolvedWithLocal.uploaded == 1)
        #expect(resolvedWithLocal.conflicts.isEmpty)
        #expect(resolvedWithLocal.resolvedConflictIDs == [updatedIncompatible.id])

        try Data("local conflict notes".utf8).write(to: sourceURL)
        await mocked.modifySourceOnDrive(id: source.id)
        localRecording.transcript?.segments[0].text = "Lokální změna pro dávku"
        try currentContext.save()
        try await mocked.replaceRecordingOnDrive(with: changedPackage)
        let batchSnapshot = try DriveProjectSnapshot(project: localProject, storage: storage)
        let batchDetected = try await sync.run(projects: [batchSnapshot], folder: folder, remote: remote,
                                               storageRoot: storage.rootURL, applyTranscript: apply) { _, _ in }
        #expect(batchDetected.conflicts.count == 2)
        let sourceConflict = try #require(batchDetected.conflicts.first { $0.key.hasPrefix("s-") })
        let recordingConflict = try #require(batchDetected.conflicts.first { $0.key.hasPrefix("r-") })
        let batchResolved = try await sync.run(
            projects: [batchSnapshot], folder: folder, remote: remote,
            storageRoot: storage.rootURL, applyTranscript: apply,
            resolutions: [
                .init(conflict: sourceConflict, choice: .both),
                .init(conflict: recordingConflict, choice: .drive)
            ]
        ) { _, _ in }
        #expect(batchResolved.uploaded == 1, Comment(rawValue: batchResolved.failures.joined(separator: "\n")))
        #expect(batchResolved.downloaded == 1, Comment(rawValue: batchResolved.failures.joined(separator: "\n")))
        #expect(batchResolved.conflicts.isEmpty)
        #expect(batchResolved.resolvedConflictIDs == Set([sourceConflict.id, recordingConflict.id]))
    }

    @Test func ordersRecordingAttachmentsDeterministicallyAcrossDevices() async throws {
        let firstWorkspace = try TestWorkspace(); defer { firstWorkspace.cleanUp() }
        let secondWorkspace = try TestWorkspace(); defer { secondWorkspace.cleanUp() }
        let audio = try firstWorkspace.makeAudio()
        try FileManager.default.createDirectory(at: firstWorkspace.storage.recordingsURL, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: audio, to: firstWorkspace.storage.recordingURL(fileName: audio.lastPathComponent))
        let recording = Recording(title: "Attachments", audioFileName: audio.lastPathComponent,
                                  originalFileName: "Audio.wav", duration: 1)
        let transcript = Transcript(languageCode: "cs")
        transcript.segments = [TranscriptSegment(position: 0, startTime: 0, endTime: 1, text: "Test", speaker: nil)]
        recording.transcript = transcript
        let highID = RecordingSource(id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
                                     type: .document, displayName: "Alpha", originalFilename: "alpha.txt",
                                     localFileReference: "original.txt")
        let lowID = RecordingSource(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                    type: .document, displayName: "Zeta", originalFilename: "zeta.txt",
                                    localFileReference: "original.txt")
        for (source, text) in [(highID, "alpha"), (lowID, "zeta")] {
            try FileManager.default.createDirectory(at: firstWorkspace.storage.sourceDirectory(id: source.id), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: firstWorkspace.storage.sourceURL(source))
        }
        recording.sources = [lowID, highID]
        let codec = RecordingPackageCodec()
        let firstURL = firstWorkspace.root.appending(path: "First.soniquill")
        let firstSnapshot = try RecordingPackageSnapshot(recording: recording, selected: [lowID.id, highID.id],
                                                         storage: firstWorkspace.storage)
        let firstManifest = try await codec.export(firstSnapshot, to: firstURL)
        #expect(firstManifest.files.dropFirst().map(\.name) == ["alpha.txt", "zeta.txt"])

        let staged = try await codec.stage(firstURL, under: secondWorkspace.storage.rootURL)
        let secondContainer = try secondWorkspace.storage.makeContainer(inMemory: true)
        _ = try RecordingPackageImport.commit(staged, storage: secondWorkspace.storage, container: secondContainer)
        let imported = try #require(secondContainer.mainContext.fetch(FetchDescriptor<Recording>()).first)
        let secondURL = secondWorkspace.root.appending(path: "Second.soniquill")
        let secondSnapshot = try RecordingPackageSnapshot(recording: imported, selected: Set(imported.sources.map(\.id)),
                                                          storage: secondWorkspace.storage)
        try await codec.export(secondSnapshot, to: secondURL)
        #expect(try SourceImportService.hash(firstURL) == SourceImportService.hash(secondURL))
    }

    @Test func sourceFolderListsOnlyDirectPackageFiles() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let fm = FileManager.default
        let package = workspace.root.appending(path: "Recording.soniquill")
        try Data([0]).write(to: package)
        try Data([1]).write(to: workspace.root.appending(path: "Notes.txt"))
        try fm.createDirectory(at: workspace.root.appending(path: "Folder.soniquill"), withIntermediateDirectories: false)
        try fm.createSymbolicLink(at: workspace.root.appending(path: "Link.soniquill"), withDestinationURL: package)
        let source = DrivePackageFolder()
        let packages = try await source.packages(in: workspace.root)
        #expect(packages.map(\.lastPathComponent) == ["Recording.soniquill"])
    }

    @Test func recoversFromDuplicateDriveCopiesAndLinksSameNamedProjectInRootFolder() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let storage = workspace.storage
        let audio = try workspace.makeAudio()
        try FileManager.default.createDirectory(at: storage.recordingsURL, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: audio, to: storage.recordingURL(fileName: audio.lastPathComponent))

        let macProject = Project(name: "SUS")
        let macRecording = Recording(title: "Základy DNS", audioFileName: audio.lastPathComponent,
                                     originalFileName: "dns.wav", duration: 1)
        let macTranscript = Transcript(languageCode: "cs")
        let segmentID = UUID()
        macTranscript.segments = [TranscriptSegment(id: segmentID, position: 0, startTime: 0, endTime: 1,
                                                    text: "Verze z Macu", speaker: "Eva")]
        macRecording.transcript = macTranscript
        macProject.recordings = [macRecording]

        let mocked = MockDrive(root: "root_" + UUID().uuidString)
        let rootFolder = DriveProjectFolder(id: mocked.root, name: "Shared folder")
        let remote = DriveProjectRemote(transport: DriveHTTPTransport(send: { try await mocked.send($0) }),
                                        checkPrivacy: {}, token: { _ in "token" })
        let sync = DriveProjectSync()

        let macSnapshot = try DriveProjectSnapshot(project: macProject, storage: storage)
        let initial = try await sync.run(projects: [macSnapshot], folder: rootFolder, remote: remote) { _, _ in }
        #expect(initial.uploaded == 1)
        #expect(await mocked.folderCreates == 1)

        // Second device created its own Project("SUS") with a different Project.id, pointing at the same root "soniquill" folder.
        let phoneProject = Project(name: "SUS")
        let phoneRecording = Recording(id: macRecording.id, title: macRecording.title,
                                       audioFileName: macRecording.audioFileName,
                                       originalFileName: macRecording.originalFileName, duration: 1)
        let phoneTranscript = Transcript(languageCode: "cs", createdAt: macTranscript.createdAt)
        phoneTranscript.segments = [TranscriptSegment(id: segmentID, position: 0, startTime: 0, endTime: 1,
                                                      text: "Verze z iPhonu", speaker: "Eva")]
        phoneRecording.transcript = phoneTranscript
        phoneProject.recordings = [phoneRecording]
        let phoneSnapshot = try DriveProjectSnapshot(project: phoneProject, storage: storage)

        // Add a second conflicting copy with the same soniquillKey on Drive (which previously threw conflictingFiles).
        let duplicateURL = workspace.root.appending(path: "Duplicate.soniquill")
        try await RecordingPackageCodec().export(
            RecordingPackageSnapshot(recording: phoneRecording, selected: [], storage: storage),
            to: duplicateURL
        )
        try await mocked.addDuplicateRecordingOnDrive(from: duplicateURL, modifiedTime: "2026-11-25T18:05:00.000Z")

        // Check Drive Versions must report Sync Needed (false), never throw conflictingFiles.
        let checkBefore = try await sync.verify(projects: [phoneSnapshot], folder: rootFolder, remote: remote) { _ in }
        #expect(checkBefore.projects[phoneProject.id] == false)
        #expect(await mocked.folderCreates == 1)

        // Sync must link to the existing SUS folder and surface the duplicate collision in conflicts for the bottom sheet.
        let conflicted = try await sync.run(projects: [phoneSnapshot], folder: rootFolder, remote: remote) { _, _ in }
        #expect(await mocked.folderCreates == 1)
        #expect(conflicted.conflicts.count == 1)
        let conflict = try #require(conflicted.conflicts.first)

        let resolved = try await sync.run(
            projects: [phoneSnapshot], folder: rootFolder, remote: remote,
            resolutions: [.init(conflict: conflict, choice: .local)]
        ) { _, _ in }
        #expect(resolved.uploaded == 1, Comment(rawValue: resolved.failures.joined(separator: "\n")))
        #expect(resolved.conflicts.isEmpty)
        #expect(await mocked.totalFileCount() == 2) // Duplicate copy remains safely on Drive with detached key.

        let checkAfter = try await sync.verify(projects: [phoneSnapshot], folder: rootFolder, remote: remote) { _ in }
        #expect(checkAfter.projects[phoneProject.id] == true)
        let nextSync = try await sync.run(projects: [phoneSnapshot], folder: rootFolder, remote: remote) { _, _ in }
        #expect(nextSync.unchanged == 1)
        #expect(nextSync.conflicts.isEmpty)
    }

    @Test func recoversWhenReservedFolderOrFileIDWasMovedToDriveTrash() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let storage = workspace.storage
        let audio = try workspace.makeAudio()
        try FileManager.default.createDirectory(at: storage.recordingsURL, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: audio, to: storage.recordingURL(fileName: audio.lastPathComponent))

        let project = Project(name: "SUS")
        let recording = Recording(title: "Základy DNS zón a SOA", audioFileName: audio.lastPathComponent,
                                  originalFileName: "dns.wav", duration: 1)
        let transcript = Transcript(languageCode: "cs")
        transcript.segments = [TranscriptSegment(position: 0, startTime: 0, endTime: 1, text: "DNS", speaker: nil)]
        recording.transcript = transcript
        project.recordings = [recording]

        let mocked = MockDrive(root: "root_" + UUID().uuidString)
        let rootFolder = DriveProjectFolder(id: mocked.root, name: "Shared folder")
        let remote = DriveProjectRemote(transport: DriveHTTPTransport(send: { try await mocked.send($0) }),
                                        checkPrivacy: {}, token: { _ in "token" })
        let sync = DriveProjectSync()
        let snapshot = try DriveProjectSnapshot(project: project, storage: storage)

        // First sync creates folder + recording (leaving reservations in UserDefaults just like first sync on iPhone).
        let first = try await sync.run(projects: [snapshot], folder: rootFolder, remote: remote) { _, _ in }
        #expect(first.uploaded == 1)
        let firstFolderID = try #require(await mocked.projectFolderID())

        // User moves the folder and file to Trash in Google Drive Web UI; stale reservations still point to trashed IDs!
        // Also simulate a stale file reservation inside the next folder ID so file 409 recovery is exercised too.
        await mocked.trashAllEntries()
        let staleRecordingID = await mocked.insertTrashedEntry(id: "\(mocked.root)_trashed_file")
        remote.saveReservation(staleRecordingID, parent: "\(mocked.root)_3", key: "r-" + recording.id.uuidString)

        // Sync must recover from 409 on both trashed folder ID and trashed file ID without throwing conflictingFiles.
        let recovered = try await sync.run(projects: [snapshot], folder: rootFolder, remote: remote) { _, _ in }
        #expect(recovered.uploaded == 1, Comment(rawValue: recovered.failures.joined(separator: "\n")))
        #expect(recovered.failures.isEmpty)
        let newFolderID = try #require(await mocked.projectFolderID())
        #expect(newFolderID != firstFolderID)

        let verified = try await sync.verify(projects: [snapshot], folder: rootFolder, remote: remote) { _ in }
        #expect(verified.projects[project.id] == true)
    }
}

private actor MockDrive {
    private struct Entry {
        let id: String
        var name: String
        let mime: String
        let parent: String
        var key: String
        var hash: String?
        var modifiedTime: String?
        var trashed: Bool = false
    }

    let root: String
    private var entries: [String: Entry] = [:]
    private var pending: [String: Entry] = [:]
    private var downloads: [String: Data] = [:]
    private var generated = 0
    private(set) var creates = 0
    private(set) var updates = 0
    private(set) var folderCreates = 0

    init(root: String) { self.root = root }

    func projectFolderID() -> String? {
        entries.values.first { $0.mime == DriveProjectRemote.folderType && !$0.trashed }?.id
    }

    func trashAllEntries() {
        for id in Array(entries.keys) {
            entries[id]?.trashed = true
        }
    }

    func insertTrashedEntry(id: String) -> String {
        entries[id] = Entry(id: id, name: "Trashed.soniquill", mime: "application/octet-stream",
                            parent: root, key: "r-trashed", hash: String(repeating: "0", count: 64), trashed: true)
        return id
    }

    func modifyRecordingOnDrive() {
        for id in entries.values.filter({ $0.key.hasPrefix("r-") }).map(\.id) {
            entries[id]?.hash = String(repeating: "a", count: 64)
        }
    }

    func modifySourceOnDrive(id sourceID: UUID) {
        let targetKey = "s-" + sourceID.uuidString
        for id in entries.values.filter({ $0.key == targetKey }).map(\.id) {
            entries[id]?.hash = String(repeating: "b", count: 64)
        }
    }

    func replaceRecordingOnDrive(with file: URL) throws {
        let entry = try #require(entries.values.first { $0.key.hasPrefix("r-") })
        downloads[entry.id] = try Data(contentsOf: file)
        entries[entry.id]?.hash = try SourceImportService.hash(file)
    }

    func addDuplicateRecordingOnDrive(from file: URL, modifiedTime: String) throws {
        let existing = try #require(entries.values.first { $0.key.hasPrefix("r-") })
        generated += 1
        let dupID = "\(root)_dup_\(generated)"
        let data = try Data(contentsOf: file)
        downloads[dupID] = data
        entries[dupID] = Entry(id: dupID, name: existing.name, mime: existing.mime, parent: existing.parent,
                               key: existing.key, hash: try SourceImportService.hash(file), modifiedTime: modifiedTime)
    }

    func totalFileCount() -> Int {
        entries.values.filter { $0.mime != DriveProjectRemote.folderType && !$0.trashed }.count
    }

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let method = request.httpMethod
        if url.path == "/drive/v3/files/\(root)" {
            return try respond(url, json: folder(id: root, name: "Shared folder"))
        }
        if method == "GET", query["alt"] != "media", url.path.hasPrefix("/drive/v3/files/"),
           url.lastPathComponent != "generateIds", let entry = entries[url.lastPathComponent] {
            var item = metadata(entry)
            if let data = downloads[entry.id] { item["size"] = String(data.count) }
            else if entry.mime != DriveProjectRemote.folderType { item["size"] = "1" }
            return try respond(url, json: item)
        }
        if method == "PATCH", url.path.hasPrefix("/drive/v3/files/"), let body = request.httpBody,
           let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
            let id = url.lastPathComponent
            var entry = try #require(entries[id])
            if let newName = json["name"] as? String { entry.name = newName }
            if let props = json["appProperties"] as? [String: String], let newKey = props["soniquillKey"] {
                entry.key = newKey
            }
            entries[id] = entry
            return try respond(url, json: metadata(entry))
        }
        if url.path == "/drive/v3/files/generateIds" {
            generated += 1
            return try respond(url, json: ["ids": ["\(root)_\(generated)"]])
        }
        if query["alt"] == "media", method == "GET" {
            let data = try #require(downloads[url.lastPathComponent])
            #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-\(data.count - 1)")
            let response = try #require(HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil,
                headerFields: ["Content-Range": "bytes 0-\(data.count - 1)/\(data.count)"]))
            return (data, response)
        }
        if url.path == "/drive/v3/files", method == "GET" {
            let q = try #require(query["q"])
            let matching = entries.values.filter { entry in
                if q.contains("trashed = false") && entry.trashed { return false }
                guard q.contains("'\(entry.parent)' in parents") else { return false }
                if q.contains("mimeType = '\(DriveProjectRemote.folderType)'") {
                    return entry.mime == DriveProjectRemote.folderType
                }
                return !q.contains("appProperties") || q.contains("value='\(entry.key)'")
            }
            return try respond(url, json: ["files": matching.map { entry in
                var item = metadata(entry)
                if let data = downloads[entry.id] { item["size"] = String(data.count) }
                return item
            }])
        }
        if url.path == "/drive/v3/files", method == "POST" {
            let entry = try readCreate(request)
            if entries[entry.id] != nil {
                return try respond(url, status: 409, json: [:])
            }
            #expect(entry.parent == root)
            entries[entry.id] = entry
            folderCreates += 1
            return try respond(url, json: metadata(entry))
        }
        if url.path.hasPrefix("/upload/drive/v3/files"), method == "POST" || method == "PATCH" {
            let entry: Entry
            if method == "POST" {
                entry = try readCreate(request)
                if entries[entry.id] != nil {
                    return try respond(url, status: 409, json: [:])
                }
                #expect(entries[entry.parent]?.mime == DriveProjectRemote.folderType)
                creates += 1
            } else {
                entry = try #require(entries[url.lastPathComponent])
                updates += 1
            }
            pending[entry.id] = entry
            let session = "https://www.googleapis.com/upload/drive/v3/files?upload_id=\(entry.id)"
            return try respond(url, json: [:], headers: ["Location": session])
        }
        if method == "PUT" {
            let id = try #require(query["upload_id"])
            let pendingEntry = pending.removeValue(forKey: id)
            var entry = try #require(pendingEntry)
            let bytes = try #require(request.httpBody)
            if entry.key.hasPrefix("r-") { #expect(bytes.starts(with: Data("SONIQUILL".utf8))) }
            let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try bytes.write(to: temporary)
            entry.hash = try SourceImportService.hash(temporary)
            entries[id] = entry
            downloads[id] = bytes
            var data = metadata(entry)
            data["size"] = String(bytes.count)
            return try respond(url, json: data)
        }
        Issue.record("Unexpected Drive request: \(method ?? "") \(url.path)")
        throw GoogleDriveSharingError.invalidResponse
    }

    private func readCreate(_ request: URLRequest) throws -> Entry {
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let id = try #require(json["id"] as? String)
        let name = try #require(json["name"] as? String)
        let mime = try #require(json["mimeType"] as? String)
        let parent = try #require((json["parents"] as? [String])?.first)
        let key = try #require((json["appProperties"] as? [String: String])?["soniquillKey"])
        return Entry(id: id, name: name, mime: mime, parent: parent, key: key)
    }

    private func metadata(_ entry: Entry) -> [String: Any] {
        if entry.mime == DriveProjectRemote.folderType {
            var item = folder(id: entry.id, name: entry.name)
            item["appProperties"] = ["soniquillKey": entry.key]
            item["parents"] = [entry.parent]
            item["trashed"] = entry.trashed
            return item
        }
        var result: [String: Any] = ["id": entry.id, "name": entry.name, "mimeType": entry.mime,
                                     "appProperties": ["soniquillKey": entry.key],
                                     "parents": [entry.parent], "trashed": entry.trashed]
        result["sha256Checksum"] = entry.hash
        result["modifiedTime"] = entry.modifiedTime
        return result
    }

    private func folder(id: String, name: String) -> [String: Any] {
        ["id": id, "name": name, "mimeType": DriveProjectRemote.folderType,
         "ownedByMe": true, "capabilities": ["canAddChildren": true]]
    }

    private func respond(_ url: URL, status: Int = 200, json: [String: Any], headers: [String: String] = [:]) throws -> (Data, HTTPURLResponse) {
        (try JSONSerialization.data(withJSONObject: json),
         try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)))
    }
}
