import AVFoundation
import Foundation
import UniformTypeIdentifiers

struct ImportedAudio: Sendable {
    let id: UUID
    let title: String
    let originalFileName: String
    let fileName: String
    let duration: TimeInterval
}

enum AudioImportError: LocalizedError {
    case notAudio, invalidAudio

    var errorDescription: String? {
        switch self {
        case .notAudio: "Choose a local audio file, such as M4A, MP3, WAV, or AIFF."
        case .invalidAudio: "This file does not contain playable audio."
        }
    }
}

protocol AudioImporting: Sendable {
    func importFile(at source: URL) async throws -> ImportedAudio
    func discard(_ imported: ImportedAudio) async throws
}

/// Owns file I/O; SwiftData objects stay on the main actor.
actor AudioImportService: AudioImporting {
    let storage: LibraryStorage

    init(storage: LibraryStorage = LibraryStorage()) { self.storage = storage }

    func importFile(at source: URL) async throws -> ImportedAudio {
        try Task.checkCancellation()
        guard source.isFileURL else { throw AudioImportError.notAudio }
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey])
        let type = values.contentType ?? UTType(filenameExtension: source.pathExtension)
        guard values.isRegularFile == true, type?.conforms(to: .audio) == true else {
            throw AudioImportError.notAudio
        }

        let id = UUID()
        let fileName = id.uuidString + "." + source.pathExtension.lowercased()
        try FileManager.default.createDirectory(at: storage.recordingsURL, withIntermediateDirectories: true)
        let destination = storage.recordingURL(fileName: fileName)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            try Task.checkCancellation()
            let asset = AVURLAsset(url: destination)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let duration = try await asset.load(.duration).seconds
            guard !tracks.isEmpty, duration.isFinite, duration > 0 else {
                throw AudioImportError.invalidAudio
            }
            try Task.checkCancellation()
            return ImportedAudio(id: id, title: source.deletingPathExtension().lastPathComponent,
                                 originalFileName: source.lastPathComponent, fileName: fileName, duration: duration)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            // AVFoundation describes undecodable files with text such as "Cannot Open".
            if (error as NSError).domain == AVFoundationErrorDomain { throw AudioImportError.invalidAudio }
            throw error
        }
    }

    /// Used to undo the copy if saving library metadata fails.
    func discard(_ imported: ImportedAudio) throws {
        try FileManager.default.removeItem(at: storage.recordingURL(fileName: imported.fileName))
    }
}
