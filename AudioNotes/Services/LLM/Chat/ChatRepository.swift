import Foundation
import SwiftData

@MainActor
protocol ChatStoring: Sendable {
    func record(_ generation: GenerationRecord) throws
    func ensureSession(for recording: Recording) throws -> ChatSession
    func ensureProjectSession(for project: Project) throws -> ChatSession
    func saveSession(_ session: ChatSession) throws
    func appendMessage(_ message: ChatMessage, to session: ChatSession) throws
    func updateMessage(_ message: ChatMessage, status: ChatMessageStatus, references: [TranscriptReference]) throws
    func deleteMessage(_ message: ChatMessage) throws
    func clearMessages(in session: ChatSession) throws
}

typealias ChatRepository = ChatStoring

extension ChatStoring {
    func record(_ generation: GenerationRecord) throws {}
    func ensureProjectSession(for project: Project) throws -> ChatSession { throw RetrievalError.scopeMissing }
    func saveSession(_ session: ChatSession) throws {}
    func getOrCreateSession(for recording: Recording) throws -> ChatSession {
        try ensureSession(for: recording)
    }
}

@MainActor
final class SwiftDataChatRepository: ChatStoring {
    private let container: ModelContainer
    private let context: ModelContext

    init(context: ModelContext) {
        self.container = context.container
        self.context = context
    }

    func record(_ generation: GenerationRecord) throws {
        context.insert(generation)
        try context.save()
    }

    func ensureSession(for recording: Recording) throws -> ChatSession {
        if let existing = recording.chatSessions.sorted(by: { $0.createdAt < $1.createdAt }).first {
            return existing
        }
        let session = ChatSession(title: "Chat")
        session.recording = recording
        recording.chatSessions.append(session)
        context.insert(session)
        try context.save()
        return session
    }

    func ensureProjectSession(for project: Project) throws -> ChatSession {
        if let existing = project.chatSessions.sorted(by: { $0.createdAt < $1.createdAt }).first { return existing }
        let session = ChatSession(title: "Project Chat")
        session.project = project
        context.insert(session)
        try context.save()
        return session
    }

    func saveSession(_ session: ChatSession) throws { try context.save() }

    func appendMessage(_ message: ChatMessage, to session: ChatSession) throws {
        if message.role == .assistant {
            let response = ChatContentNormalizer.validated(
                LLMChatResponse(content: message.text, references: message.references),
                against: session.recording?.transcript?.segmentSnapshots ?? []
            )
            message.text = response.content
            message.references = response.references
        }
        if let recording = session.recording, message.role == .assistant {
            message.sourceReferences = SourceReferenceResolver().validate(message.sourceReferences, recording: recording)
            message.text = ChatContentNormalizer.clean(message.text, internalSegmentIDs: message.sourceReferences.flatMap { [$0.sourceID, $0.chunkID] })
        }
        message.session = session
        session.messages.append(message)
        session.updatedAt = .now
        context.insert(message)
        try context.save()
    }

    func updateMessage(_ message: ChatMessage, status: ChatMessageStatus, references: [TranscriptReference]) throws {
        message.status = status
        if message.role == .assistant {
            let response = ChatContentNormalizer.validated(
                LLMChatResponse(content: message.text, references: references),
                against: message.session?.recording?.transcript?.segmentSnapshots ?? []
            )
            message.text = response.content
            message.references = response.references
        } else {
            message.references = references
        }
        message.session?.updatedAt = .now
        try context.save()
    }

    func deleteMessage(_ message: ChatMessage) throws {
        if let session = message.session {
            session.messages.removeAll { $0.id == message.id }
            session.updatedAt = .now
        }
        context.delete(message)
        try context.save()
    }

    func clearMessages(in session: ChatSession) throws {
        for message in session.messages {
            context.delete(message)
        }
        session.messages.removeAll()
        session.updatedAt = .now
        try context.save()
    }
}
