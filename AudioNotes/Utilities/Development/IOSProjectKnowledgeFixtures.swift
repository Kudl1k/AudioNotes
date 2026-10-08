#if DEBUG && os(iOS)
import Foundation
import SwiftData
import UIKit

/// Opt-in in-memory synthetic corpus for iOS project/source/chat review. Never runs in Release.
@MainActor
enum IOSProjectKnowledgeFixtures {
    static let projectID = stableID(1)
    private static let storage = LibraryStorage()

    static func prepare(context: ModelContext) throws {
        guard try context.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.id == projectID })).isEmpty else { return }
        let project = Project(id: projectID, name: "Operating Systems",
            projectDescription: "Synthetic material for Project Sources and Chat review.")
        context.insert(project)
        for index in 0..<20 {
            let recording = Recording(id: stableID(100 + index), title: String(format: "Lecture %02d · Kernel and Memory", index + 1),
                audioFileName: "", originalFileName: String(format: "lecture-%02d.m4a", index + 1), duration: 3_600)
            let transcript = Transcript()
            transcript.segments = (0..<20).map { segment in
                TranscriptSegment(id: stableID(1_000 + index * 20 + segment), position: segment,
                    startTime: Double(segment * 90) + (segment == 0 ? 761 : 0), endTime: Double(segment * 90 + 42) + (segment == 0 ? 761 : 0),
                    text: "Lecture \(index + 1) discusses kernel modules, process scheduling, virtual memory, and safe user-space copies. Segment \(segment + 1) compares the lecture explanation with the system notes and assignment requirements.")
            }
            recording.transcript = transcript
            recording.project = project
            context.insert(recording)
        }

        let sourceCount = ProcessInfo.processInfo.arguments.contains("--ios-project-empty-sources") ? 0 : 30
        for index in 0..<sourceCount {
            let type: RecordingSourceType = index < 10 ? .pdf : (index < 20 ? .document : .image)
            let ext = type == .pdf ? "pdf" : (type == .document ? (index.isMultiple(of: 2) ? "md" : "txt") : "png")
            let filename = String(format: "project-reference-%02d.%@", index + 1, ext)
            let args = ProcessInfo.processInfo.arguments
            let failedFixture = args.contains("--ios-project-processing-failure") && index == 0
            let processingFixture = args.contains("--ios-project-processing-state") && index == 0
            let source = RecordingSource(id: stableID(2_000 + index), type: type, displayName: filename,
                originalFilename: filename, localFileReference: "original.\(ext)",
                status: failedFixture ? .failed : (processingFixture ? .processing : .ready))
            if failedFixture { source.processingError = SourceImportError.invalidFile.localizedDescription }
            source.project = project
            let unitCount = type == .pdf ? 3 : (type == .image ? 2 : 1)
            source.metadata = type == .pdf ? .pdf(pageCount: unitCount, unreadablePages: []) :
                (type == .image ? .image(width: 900, height: 600) : .document(characterCount: 6_000))
            source.textUnits = try (0..<unitCount).map { unit in
                let text = (0..<8).map { paragraph in
                    "Reference \(index + 1), section \(unit + 1): kernel modules use explicit initialization and cleanup. Validate user pointers with copy_from_user, preserve page boundaries, and compare the assignment requirements with lecture coverage. Paragraph \(paragraph + 1)."
                }.joined(separator: "\n\n")
                let locator: SourceLocator
                switch type {
                case .pdf: locator = .pdf(pageIndex: unit)
                case .image: locator = .image(region: nil)
                case .document: locator = .document(section: "Section \(unit + 1)", start: 0, end: text.count)
                case .audio: locator = .audio(segmentIDs: [], start: 0, end: 0)
                }
                return try SourceTextUnit(id: stableID(3_000 + index * 10 + unit), position: unit,
                    text: text, origin: type == .image ? .ocr : .nativeText, locator: locator)
            }
            context.insert(source)
            try writeOriginal(for: source, ext: ext, index: index)
        }

        let pdfCitation: ProjectCitation? = project.sources.first(where: { $0.type == .pdf }).map { pdf in
            let pdfChunk = SourceChunk(id: stableID(6_001), sourceID: pdf.id, sourceName: pdf.displayName,
                sourceType: .pdf, text: "Kernel module declarations", locator: .pdf(pageIndex: 1), origin: .nativeText)
            let pdfDoc = RetrievalDocument(id: pdfChunk.id, projectID: project.id, recordingID: nil, recordingTitle: nil,
                contentType: .pdfText, chunk: pdfChunk, unitIDs: [pdf.textUnits[1].id], contentRevision: stableID(6_101))
            return ProjectCitation(projectID: project.id, entry: ContextEntry(document: pdfDoc, relevance: 1))
        }
        let recording = project.recordings[0]
        let segment = recording.transcript!.segments[0]
        let audioChunk = SourceChunk(id: stableID(6_002), sourceID: recording.id, sourceName: recording.title,
            sourceType: .audio, text: segment.text, locator: .audio(segmentIDs: [segment.id], start: segment.startTime, end: segment.endTime), origin: .transcript)
        let audioDoc = RetrievalDocument(id: audioChunk.id, projectID: project.id, recordingID: recording.id, recordingTitle: recording.title,
            contentType: .transcript, chunk: audioChunk, unitIDs: [segment.id], contentRevision: stableID(6_102))
        let audioCitation = ProjectCitation(projectID: project.id, entry: ContextEntry(document: audioDoc, relevance: 1))

        let session = ChatSession(id: stableID(4_000), title: "250-message history fixture")
        session.project = project
        let args = ProcessInfo.processInfo.arguments
        let messageCount = args.contains("--ios-project-empty-chat") ? 0 : (args.contains("--ios-project-chat-compact-review") ? 8 : 250)
        for index in 0..<messageCount {
            let role: ChatRole = index.isMultiple(of: 2) ? .user : .assistant
            let text: String
            switch index {
            case let value where value == messageCount - 2: text = "How does copy_from_user work, and where does the lecture explain it?"
            case let value where value == messageCount - 1: text = "The assignment explains that user-space pointers must not be dereferenced directly from kernel code. Validate and copy the requested bytes into a kernel buffer before using them. The lecture compares the safe copy path with the assignment requirements.\n\n- Validate the user address.\n- Copy data into kernel-owned memory.\n- Check the returned byte count."
            default:
                text = role == .user ? "Earlier project question \(index / 2)." : "Earlier project answer \(index / 2)."
            }
            let message = ChatMessage(id: stableID(5_000 + index), role: index.isMultiple(of: 2) ? .user : .assistant,
                text: text,
                createdAt: Date(timeIntervalSince1970: Double(index)))
            // Set both sides of the SwiftData relationship before saving. This fixture is
            // deliberately persisted and then loaded through ProjectChatViewModel.attach.
            message.session = session
            session.messages.append(message)
            context.insert(message)
        }
        if messageCount > 0 {
            if args.contains("--ios-project-recording-citation") {
                session.messages[messageCount - 1].projectCitations = [audioCitation]
            } else if args.contains("--ios-project-pdf-citation"), let pdfCitation {
                session.messages[messageCount - 1].projectCitations = [pdfCitation]
            } else {
                session.messages[messageCount - 1].projectCitations = [audioCitation] + (pdfCitation.map { [$0] } ?? [])
            }
        }
        context.insert(session)
        project.chatSessions = [session]
        try context.save()
    }

    private static func writeOriginal(for source: RecordingSource, ext: String, index: Int) throws {
        let url = storage.sourceURL(source)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if ext == "pdf" {
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
            let data = renderer.pdfData { context in
                for page in 0..<3 {
                    context.beginPage()
                    ("Synthetic Project PDF \(index + 1) · Page \(page + 1)\nKernel modules, user buffers, memory management.")
                        .draw(in: CGRect(x: 42, y: 70, width: 520, height: 180), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
                }
            }
            try data.write(to: url, options: .atomic)
        } else if ext == "png" {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 600)).image { ctx in
                UIColor.systemBackground.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
                ("Whiteboard \(index + 1): copy_from_user")
                    .draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 32), .foregroundColor: UIColor.label])
            }
            try image.pngData()?.write(to: url, options: .atomic)
        } else {
            let body = source.textUnits.map(\.text).joined(separator: "\n\n")
            try Data(body.utf8).write(to: url, options: .atomic)
        }
    }

    private static func stableID(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", number))!
    }
}
#endif
