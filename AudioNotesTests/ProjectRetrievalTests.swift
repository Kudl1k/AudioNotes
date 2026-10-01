import Foundation
import SwiftData
import Testing
@testable import AudioNotes

@MainActor
struct ProjectRetrievalTests {
    private func recording(_ title: String, text: String?) -> Recording {
        let recording = Recording(title: title, audioFileName: "lecture.m4a", originalFileName: "lecture.m4a", duration: 3600)
        if let text {
            let transcript = Transcript()
            transcript.segments = [TranscriptSegment(position: 0, startTime: 3106, endTime: 3120, text: text)]
            recording.transcript = transcript
        }
        return recording
    }
    private func source(_ name: String, text: String, type: RecordingSourceType = .pdf,
                        locator: SourceLocator = .pdf(pageIndex: 22), origin: SourceTextOrigin = .nativeText) throws -> RecordingSource {
        let source = RecordingSource(type: type, displayName: name, originalFilename: name, localFileReference: "original", status: .ready)
        source.textUnits = [try SourceTextUnit(position: 0, text: text, origin: origin, locator: locator)]
        return source
    }

    @Test func scopesFiltersCoverageAndRecordingChatStayStrict() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let context = ModelContext(try workspace.storage.makeContainer(inMemory: true))
        let project = Project(name: "Operating Systems"), other = Project(name: "Other")
        context.insert(project); context.insert(other)
        let lecture = recording("Lecture 04 — Kernel Modules", text: "Character device drivers use copy_from_user and major numbers.")
        lecture.project = project; context.insert(lecture)
        let foreign = recording("Foreign", text: "forbiddenprojecttoken drivers")
        foreign.project = other; context.insert(foreign)
        let pending = recording("Untranscribed", text: nil); pending.project = project; context.insert(pending)
        let attachment = try source("notes.md", text: "driverattachmenttoken major minor", type: .document, locator: .document(section: "Devices", start: 0, end: 40))
        attachment.recording = lecture; context.insert(attachment)
        let shared = try source("kernel-slides.pdf", text: "projectsharedtoken character device registration")
        shared.project = project; context.insert(shared)
        let ocr = try source("whiteboard.png", text: "Ovladač zařízení major minor", type: .image, locator: .image(region: nil), origin: .ocr)
        ocr.project = project; context.insert(ocr)
        let processing = try source("processing.pdf", text: "halfprocessedtoken"); processing.status = .processing; processing.project = project; context.insert(processing)
        let failed = try source("failed.pdf", text: "failedtoken"); failed.status = .failed; failed.project = project; context.insert(failed)
        try context.save()
        let defaultsName = "retrieval-local-only-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let privacy = LocalAIConfiguration(defaults: defaults)
        privacy.localOnly = true
        #expect(privacy.policy.localOnly)
        let service = RetrievalService()
        let result = try await service.retrieve(query: "drivers character device major minor", scope: .project(project.id), context: context)
        let actualSourceIDs = Set<UUID>(result.matches.map { $0.document.sourceID })
        let expectedSourceIDs: Set<UUID> = [lecture.id, attachment.id, shared.id, ocr.id]
        #expect(actualSourceIDs == expectedSourceIDs)
        #expect(result.recordings.contains { $0.id == pending.id && $0.title == "Untranscribed" && !$0.hasTranscript })
        #expect(result.coverage == RetrievalCoverage(searchableRecordings: 1, untranscribedRecordings: 1, searchableSources: 3, processingSources: 1, failedSources: 1))
        #expect(result.matches.allSatisfy { $0.document.projectID == project.id })
        #expect(result.matches.contains { $0.document.chunk.locator == .pdf(pageIndex: 22) })
        #expect(result.matches.contains { $0.document.chunk.locator.locationLabel == "51:46" })
        #expect(result.matches.contains { $0.document.contentType == .markdown && $0.document.chunk.locator.locationLabel == "Devices" })
        #expect(result.matches.contains { $0.document.contentType == .imageOCR })
        for hidden in ["forbiddenprojecttoken", "halfprocessedtoken", "failedtoken"] {
            #expect(try await service.retrieve(query: hidden, scope: .project(project.id), context: context).matches.isEmpty)
        }
        var options = RetrievalOptions(); options.recordingIDs = [lecture.id]
        let selected = try await service.retrieve(query: "major device", scope: .project(project.id), context: context, options: options)
        #expect(selected.matches.allSatisfy { $0.document.recordingID == lecture.id })
        options.recordingIDs = nil; options.sourceIDs = [shared.id]
        #expect(try await service.retrieve(query: "device", scope: .project(project.id), context: context, options: options).matches.map(\.document.sourceID) == [shared.id])
        options.sourceIDs = []; #expect(try await service.retrieve(query: "device", scope: .project(project.id), context: context, options: options).matches.isEmpty)
        options.sourceIDs = nil; options.ownership = .projectSources; options.contentTypes = [.imageOCR]
        #expect(try await service.retrieve(query: "major", scope: .project(project.id), context: context, options: options).matches.map(\.document.sourceID) == [ocr.id])
        options.ownership = .recordings; options.contentTypes = nil
        #expect(try await service.retrieve(query: "major", scope: .project(project.id), context: context, options: options).matches.allSatisfy { $0.document.recordingID != nil })
        let scoped = try await service.retrieve(query: "projectsharedtoken driverattachmenttoken copy_from_user", scope: .recording(lecture.id), context: context)
        #expect(Set(scoped.matches.map(\.document.sourceID)) == [lecture.id, attachment.id])
        let chat = try await SourceContextPreparation().prepareChat(recording: lecture, selectedSourceIDs: nil,
            history: [.init(role: .user, content: "device")], provider: MockLLMProvider(delayNanoseconds: 0), settings: .init(), allowImages: false)
        #expect(Set(chat.sourceChunks?.map(\.sourceID) ?? []) == [lecture.id, attachment.id])
        #expect(try context.fetchCount(FetchDescriptor<GenerationRecord>()) == 0)
    }

    @Test func membershipMovesRemovalReplacementAndOCRRefreshNeverLeaveStaleResults() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let context = ModelContext(try workspace.storage.makeContainer(inMemory: true))
        let a = Project(name: "A"), b = Project(name: "B"); context.insert(a); context.insert(b)
        let lecture = recording("Lecture", text: "oldtranscripttoken"); lecture.project = b; context.insert(lecture)
        let pdf = try source("slides.pdf", text: "deleteduniquetoken"); pdf.project = a; context.insert(pdf)
        let image = try source("image.png", text: "oldocrtoken", type: .image, locator: .image(region: nil), origin: .ocr)
        image.project = a; context.insert(image); try context.save()
        let service = RetrievalService()
        #expect(try await service.retrieve(query: "oldtranscripttoken", scope: .project(a.id), context: context).matches.isEmpty)
        let repository = SwiftDataProjectRepository(context: context, storage: workspace.storage)
        try repository.move(lecture, to: a)
        #expect(try await service.retrieve(query: "oldtranscripttoken", scope: .project(a.id), context: context).matches.count == 1)
        try repository.move(lecture, to: nil)
        #expect(try await service.retrieve(query: "oldtranscripttoken", scope: .project(a.id), context: context).matches.isEmpty)
        try repository.move(lecture, to: a)
        lecture.transcript?.segments[0].text = "newtranscripttoken"
        #expect(try await service.retrieve(query: "oldtranscripttoken", scope: .project(a.id), context: context).matches.isEmpty)
        #expect(try await service.retrieve(query: "newtranscripttoken", scope: .project(a.id), context: context).matches.count == 1)
        let old = try #require(lecture.transcript)
        let replacement = Transcript(); replacement.segments = [TranscriptSegment(position: 0, startTime: 1, endTime: 10, text: "replacementtoken")]
        context.insert(replacement); lecture.transcript = replacement; context.delete(old)
        #expect(try await service.retrieve(query: "newtranscripttoken", scope: .project(a.id), context: context).matches.isEmpty)
        #expect(try await service.retrieve(query: "replacementtoken", scope: .project(a.id), context: context).matches.count == 1)
        image.textUnits[0].text = "newocrtoken"
        #expect(try await service.retrieve(query: "oldocrtoken", scope: .project(a.id), context: context).matches.isEmpty)
        #expect(try await service.retrieve(query: "newocrtoken", scope: .project(a.id), context: context).matches.count == 1)
        try repository.deleteSource(pdf, from: a)
        #expect(try await service.retrieve(query: "deleteduniquetoken", scope: .project(a.id), context: context).matches.isEmpty)
        let unchanged = try await service.retrieve(query: "newocrtoken", scope: .project(a.id), context: context)
        #expect(!unchanged.statistics.rebuiltIndex)
        lecture.duration = 4000
        a.projectDescription = "metadata only"
        #expect(try await !service.retrieve(query: "newocrtoken", scope: .project(a.id), context: context).statistics.rebuiltIndex)
    }

    @Test func backgroundIndexingAllowsMainActorProgressAndSupersededQueriesCancel() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let context = ModelContext(try workspace.storage.makeContainer(inMemory: true))
        let project = Project(name: "Background fixture"); context.insert(project)
        let lecture = recording("Lecture", text: nil); lecture.project = project; context.insert(lecture)
        let transcript = Transcript()
        transcript.segments = (0..<7200).map { index in
            TranscriptSegment(position: index, startTime: Double(index * 10), endTime: Double(index * 10 + 10),
                text: "drivers " + String(repeating: "native background retrieval fixture ", count: 8))
        }
        lecture.transcript = transcript
        let service = RetrievalService()
        var ticks = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                ticks += 1
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        defer { heartbeat.cancel() }
        let first = Task { try await service.retrieve(query: "drivers", scope: .project(project.id), context: context) }
        // First request has copied its snapshot and yielded to the worker before supersession.
        while !service.isRetrieving(.project(project.id)) { await Task.yield() }
        let second = try await service.retrieve(query: "background", scope: .project(project.id), context: context)
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(!second.matches.isEmpty)
        #expect(ticks > 1)
        #expect(!service.isRetrieving(.project(project.id)))
    }

    @Test func emptyMissingRestartAndDeletionDuringBuild() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let context = ModelContext(try workspace.storage.makeContainer(inMemory: true))
        let project = Project(name: "Empty"); context.insert(project); try context.save()
        let engine = ContextRetriever(), service = RetrievalService(retriever: engine)
        let empty = try await service.retrieve(query: "drivers", scope: .project(project.id), context: context)
        #expect(empty.matches.isEmpty && empty.context.entries.isEmpty)
        #expect(try await RetrievalService().retrieve(query: "drivers", scope: .project(project.id), context: context).statistics.rebuiltIndex)
        let source = try source("large.txt", text: String(repeating: "private fixture driver\n", count: 200_000), type: .document)
        source.project = project; context.insert(source); try context.save()
        let build = Task { try await service.retrieve(query: "driver", scope: .project(project.id), context: context) }
        await Task.yield()
        await service.beginDeletion(.project(project.id))
        await #expect(throws: (any Error).self) { try await build.value }
        #expect(await engine.cachedScopeCount == 0)
        context.delete(project); try context.save(); service.endDeletion(.project(project.id))
        await #expect(throws: RetrievalError.self) { try await service.retrieve(query: "driver", scope: .project(project.id), context: context) }
        #expect(await engine.cachedScopeCount == 0)
    }
}
