import Darwin
import Foundation
import Testing
@testable import AudioNotes

@Suite(.serialized)
struct RetrievalPerformanceTests {
    private func fixture(hours: Int) -> RetrievalSnapshot {
        let projectID = StableSourceID.make("performance-project-\(hours)")
        var sources: [RetrievalSnapshot.Source] = []
        for hour in 0..<hours {
            let recordingID = StableSourceID.make("performance-recording-\(hour)")
            let topic = hour % 4 == 0 ? "character device copy_from_user major minor" : hour % 4 == 1 ? "paging virtual memory" : hour % 4 == 2 ? "semaphores mutex threads" : "fork processes waitpid"
            let segments: [RetrievalSnapshot.Segment] = (0..<360).map { position in
                .init(id: StableSourceID.make("performance-segment-\(hour)-\(position)"), start: Double(position * 10), end: Double(position * 10 + 10),
                      text: "Lecture \(hour) section \(position). \(topic). " + String(repeating: "This local deterministic fixture explains concepts and implementation details. ", count: 3))
            }
            sources.append(.init(id: recordingID, projectID: projectID, recordingID: recordingID, recordingTitle: "Lecture \(hour)",
                name: "Lecture \(hour)", filename: "lecture.m4a", type: .audio, segments: segments, units: []))
            // Two PDFs per hour, one attached to a recording and one project-owned. 4,000 pages at stress size.
            for document in 0..<2 {
                let sourceID = StableSourceID.make("performance-pdf-\(hour)-\(document)")
                let units: [RetrievalSnapshot.Unit] = (0..<20).map { page in
                    .init(id: StableSourceID.make("performance-page-\(hour)-\(document)-\(page)"), position: page,
                        text: "\(topic). " + String(repeating: "Document explanations contain local reference material. ", count: 18),
                        locator: .pdf(pageIndex: page), origin: .nativeText)
                }
                sources.append(.init(id: sourceID, projectID: projectID, recordingID: document == 0 ? recordingID : nil,
                    recordingTitle: document == 0 ? "Lecture \(hour)" : nil, name: "Slides \(hour)-\(document)",
                    filename: "slides.pdf", type: .pdf, segments: [], units: units))
            }
        }
        return .init(scope: .project(projectID), sources: sources,
            coverage: .init(searchableRecordings: hours, searchableSources: hours * 2))
    }

    @Test(arguments: [20, 100]) func representativeAndStressProject(hours: Int) async throws {
        let snapshot = fixture(hours: hours)
        let engine = ContextRetriever()
        var baseline = rusage(); getrusage(RUSAGE_SELF, &baseline)
        let first = try await engine.retrieve(query: "copy_from_user", snapshot: snapshot)
        let cached = try await engine.retrieve(query: "copy_from_user", snapshot: snapshot)
        var peak = rusage(); getrusage(RUSAGE_SELF, &peak)
        print("M12.2 \(hours)-hour fixture: \(hours * 360) segments, \(hours * 2) PDFs, \(hours * 40) pages, \(first.statistics.documentCount) chunks; cold build \(first.statistics.indexBuildDuration), cold query \(first.statistics.queryDuration), warm snapshot comparison \(cached.statistics.indexBuildDuration), warm query \(cached.statistics.queryDuration); process high-water RSS before/after \(baseline.ru_maxrss)/\(peak.ru_maxrss) bytes")
        #expect(first.statistics.documentCount > hours * 40)
        #expect(first.statistics.rebuiltIndex && !cached.statistics.rebuiltIndex)
        #expect(first.matches.map(\.document.id) == cached.matches.map(\.document.id))
        #expect(first.matches.first?.document.text.contains("copy_from_user") == true)
        #expect(first.context.estimatedTokenCount <= 12_000)
        #expect(first.coverage.searchableRecordings == hours)
        #expect(snapshot.sources.filter { $0.recordingID == nil }.count == hours)
        await engine.removeAll()
        #expect(await engine.cachedScopeCount == 0)
    }
}
