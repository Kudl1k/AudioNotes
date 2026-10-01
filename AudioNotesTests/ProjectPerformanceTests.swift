import Foundation
import SwiftData
import Testing
@testable import AudioNotes

@MainActor
struct ProjectPerformanceTests {
    @Test func projectMetadataScaleFixture() throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer()
        let context = ModelContext(container)
        for index in 0..<100 { context.insert(Project(name: String(format: "Project %03d", index))) }
        let projects = try context.fetch(FetchDescriptor<Project>(sortBy: [SortDescriptor(\Project.name)]))
        for index in 0..<500 {
            let recording = Recording(title: "Recording \(index)", audioFileName: "", originalFileName: "", duration: 3600)
            recording.project = projects[index < 100 ? 0 : 1 + (index % 99)]
            context.insert(recording)
        }
        for index in 0..<200 {
            let source = RecordingSource(type: .pdf, displayName: "Slides \(index)", originalFilename: "slides.pdf", localFileReference: "original.pdf", status: .ready)
            source.project = projects[0]
            source.metadata = .pdf(pageCount: 100, unreadablePages: [])
            context.insert(source)
        }
        try context.save()
        let fetched = ModelContext(container)
        let clock = ContinuousClock()
        let start = clock.now
        let metadata = try fetched.fetch(FetchDescriptor<Project>(sortBy: [SortDescriptor(\Project.name)]))
        let names = metadata.map(\.name)
        let first = try #require(metadata.first)
        let recordings = first.recordings.map { ($0.id, $0.title, $0.duration) }
        let sources = first.sources.map { ($0.id, $0.displayName, $0.statusRaw) }
        let elapsed = start.duration(to: clock.now)
        print("M12 project metadata: 100 projects / 500 recordings / 200 sources; fetch + first workspace metadata: \(elapsed)")
        #expect(names.count == 100)
        #expect(recordings.count == 100)
        #expect(sources.count == 200)
        #expect(try fetched.fetchCount(FetchDescriptor<Recording>()) == 500)
    }
}
