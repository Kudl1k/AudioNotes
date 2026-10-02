#if DEBUG
import Foundation
import SwiftData

/// Small deterministic data for SwiftUI previews. In-memory store, temporary storage root, mock providers:
/// no Keychain, network, provider, preference or production-library access.
@MainActor
enum PreviewFixtures {
    /// A throwaway root that nothing writes to; previews never import or process files.
    static let storage = LibraryStorage(rootURL: FileManager.default.temporaryDirectory
        .appending(path: "AudioNotes-Previews", directoryHint: .isDirectory))

    static func container() -> ModelContainer {
        // The in-memory configuration never touches the file system.
        do { return try LibraryStorage(rootURL: storage.rootURL).makeContainer(inMemory: true) }
        catch { fatalError("Preview container failed: \(error)") }
    }

    static let planningMarkdown = """
    ## Decisions

    The team agreed on three things:

    1. Ship the **beta** in March.
    2. Hire two designers and one audio engineer.
    3. Keep the engineering budget growth at ten percent.

    | Area | Owner | Due |
    | --- | --- | --- |
    | Roadmap | Alex | Friday |
    | Vendor contract | Sam | March |

    ```swift
    let release = Release(name: "Beta", month: 3)
    ```

    Český přepis zachovává diakritiku: příliš žluťoučký kůň.
    """

    static let citations: [SourceReference] = [
        SourceReference(sourceID: id("pdf"), chunkID: id("chunk-pdf"), sourceName: "Lecture Slides", sourceType: .pdf,
            locator: .pdf(pageIndex: 22), excerpt: "Release schedule for the next quarter."),
        SourceReference(sourceID: id("audio"), chunkID: id("chunk-audio"), sourceName: "Planning meeting", sourceType: .audio,
            locator: .audio(segmentIDs: [], start: 754, end: 790), excerpt: "We will ship the beta in March.")
    ]

    static func id(_ name: String) -> UUID { StableSourceID.make("preview-" + name) }

    /// A project with two recordings and three shared sources, or an empty project.
    @discardableResult
    static func project(populated: Bool, in context: ModelContext) -> Project {
        let project = Project(id: id("project"), name: populated ? "Quarterly Planning" : "New Product Launch",
            projectDescription: populated ? "Meetings, slides and notes for the Q3 planning cycle." : nil, createdAt: PerformanceFixtures.epoch)
        context.insert(project)
        guard populated else { return project }
        let transcribed = (try? PerformanceFixtures.recording(.small)) ?? Recording(title: "Planning meeting", audioFileName: "", originalFileName: "", duration: 300)
        transcribed.title = "Planning meeting with a deliberately long title that must truncate instead of breaking the row layout"
        transcribed.project = project
        context.insert(transcribed)
        let untranscribed = Recording(id: id("recording-2"), title: "Hallway conversation", audioFileName: "", originalFileName: "",
            duration: 95, importedAt: PerformanceFixtures.epoch.addingTimeInterval(-3600))
        untranscribed.project = project
        context.insert(untranscribed)
        let kinds: [(RecordingSourceType, String, String, SourceProcessingStatus)] = [
            (.pdf, "Lecture Slides.pdf", "slides.pdf", .ready), (.image, "Whiteboard.png", "board.png", .partial),
            (.document, "Notes.md", "notes.md", .failed)
        ]
        for (index, kind) in kinds.enumerated() {
            let source = RecordingSource(id: id("source-\(index)"), type: kind.0, displayName: kind.1, originalFilename: kind.2,
                localFileReference: kind.2, status: kind.3, importedAt: PerformanceFixtures.epoch.addingTimeInterval(Double(index)))
            if kind.0 == .pdf { source.metadata = .pdf(pageCount: 24, unreadablePages: []) }
            source.project = project
            context.insert(source)
        }
        return project
    }
}
#endif
