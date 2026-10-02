#if DEBUG
import Foundation
import SwiftData

/// Explicitly launched, synthetic project. Uses the existing temporary managed root.
@MainActor enum ProjectChatFixtures {
    static let projectID = PerformanceFixtures.id("project-chat-operating-systems")
    static let longNamesProjectID = PerformanceFixtures.id("project-long-names")

    /// Worst-case strings for truncation checks (`--performance-long-names`): project, recording, source and filename.
    static func prepareLongNames(context: ModelContext) throws {
        let project = Project(id: longNamesProjectID,
            name: "Quarterly Product Planning, Roadmap Alignment and Cross-Team Dependency Review for the Next Fiscal Year",
            projectDescription: "A deliberately long synthetic description that keeps going so the header has to bound it to two lines instead of letting one string push the workspace controls out of the window or collapse the segmented navigation and search field.")
        context.insert(project)
        let recording = Recording(id: PerformanceFixtures.id("long-recording"),
            title: "Interview with the Head of Infrastructure about Migration Risks, Rollback Plans and the Disaster Recovery Exercise Scheduled After the Holidays",
            audioFileName: "", originalFileName: "interview-with-an-extremely-long-original-file-name.m4a", duration: 5400)
        recording.project = project
        context.insert(recording)
        let source = RecordingSource(type: .pdf, displayName: "Infrastructure Migration Risk Register and Rollback Procedure Handbook, Revision 14 (Final, Reviewed).pdf",
            originalFilename: "Infrastructure_Migration_Risk_Register_and_Rollback_Procedure_Handbook_Revision_14_Final_Reviewed.pdf",
            localFileReference: "original.pdf", status: .partial)
        source.metadata = .pdf(pageCount: 212, unreadablePages: [4, 7])
        source.project = project
        context.insert(source)
        try context.save()
    }

    static func prepare(context: ModelContext) throws {
        let project = Project(id: projectID, name: "Operating Systems", projectDescription: "Offline Project Chat fixture. All material is synthetic.")
        context.insert(project)
        let topics = [
            ("Processes", "Processes use fork to create a child. waitpid waits for child process completion."),
            ("Threads", "Threads coordinate with semaphores and mutexes."),
            ("Virtual Memory", "Paging maps virtual memory through page tables. Page faults load missing pages."),
            ("Kernel Modules", "Character device registration allocates major and minor device numbers with alloc_chrdev_region and registers cdev_add. Use copy_from_user and copy_to_user for user buffers. Module cleanup calls cdev_del and unregister_chrdev_region.")
        ]
        for (index, topic) in topics.enumerated() {
            let recording = Recording(id: PerformanceFixtures.id("project-chat-lecture-\(index)"), title: topic.0,
                audioFileName: "", originalFileName: "lecture-\(index + 1).m4a", duration: 3600)
            let transcript = Transcript()
            transcript.segments = [TranscriptSegment(position: 0, startTime: 3106, endTime: 3120, text: topic.1)]
            recording.transcript = transcript; recording.project = project; context.insert(recording)
        }
        let storage = LibraryStorage()
        let slides = RecordingSource(type: .pdf, displayName: "kernel-slides.pdf", originalFilename: "kernel-slides.pdf", localFileReference: "original.pdf", status: .ready)
        slides.metadata = .pdf(pageCount: 23, unreadablePages: [])
        slides.textUnits = [try SourceTextUnit(position: 22, text: "Character device registration uses alloc_chrdev_region and cdev_add. Major/minor numbers identify the device. Cleanup uses cdev_del.", origin: .nativeText, locator: .pdf(pageIndex: 22))]
        slides.project = project; context.insert(slides)
        try PerformanceFixtureAssets.write([.init(url: storage.sourceURL(slides), type: .pdf, pages: 23, thumbnailURL: storage.sourceDirectory(id: slides.id).appending(path: "thumbnail.jpg"))])
        let notes = RecordingSource(type: .document, displayName: "exam-notes.md", originalFilename: "exam-notes.md", localFileReference: "original.md", status: .ready)
        let text = "# Exam Topics\nProcesses and fork; threads and semaphores; paging and virtual memory; character device registration and cleanup."
        notes.textUnits = [try SourceTextUnit(position: 0, text: text, origin: .nativeText, locator: .document(section: "Exam Topics", start: 0, end: text.count))]
        notes.project = project; context.insert(notes)
        try FileManager.default.createDirectory(at: storage.sourceDirectory(id: notes.id), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: storage.sourceURL(notes), options: .atomic)
        try context.save()
    }
}
#endif
