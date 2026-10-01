import AVFoundation
import CryptoKit
import Foundation
import UniformTypeIdentifiers

struct ImportedSource: Sendable {
    let id: UUID
    let type: RecordingSourceType
    let filename: String
    let originalFilename: String
    let hash: String
    let duration: TimeInterval?
}

enum SourceImportError: LocalizedError, Sendable {
    case unsupported, invalidFile, tooLarge, duplicate, noText, encryptedPDF
    var errorDescription: String? {
        switch self {
        case .unsupported: "Supported sources: audio, PDF, JPEG, PNG, HEIC, TXT, and Markdown."
        case .invalidFile: "This source is damaged or is not a regular local file."
        case .tooLarge: "This file exceeds the local processing limit (512 MB; text documents 64 MB)."
        case .duplicate: "This source is already attached."
        case .noText: "No readable text was found. Open the original or try reprocessing."
        case .encryptedPDF: "This PDF is locked. Import an unlocked copy."
        }
    }
}

protocol SourceImporting: Sendable {
    func importFile(_ url: URL, existingHashes: Set<String>) async throws -> ImportedSource
    func discard(_ source: ImportedSource) async throws
}

actor SourceImportService: SourceImporting {
    let storage: LibraryStorage
    init(storage: LibraryStorage = LibraryStorage()) { self.storage = storage }

    static var supportedTypes: [UTType] { [.audio, .pdf, .jpeg, .png, .heic, .plainText, UTType(filenameExtension: "md") ?? .plainText, UTType(filenameExtension: "markdown") ?? .plainText, UTType(filenameExtension: "heif") ?? .heic] }
    static func type(for url: URL) -> RecordingSourceType? {
        guard url.isFileURL else { return nil }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let native = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        let type = native ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { return nil }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .pdf) { return .pdf }
        let images: [UTType] = [.jpeg, .png, .heic, UTType(filenameExtension: "heif") ?? .heic]
        if images.contains(where: { type.conforms(to: $0) }) { return .image }
        let documents: [UTType] = [.plainText, UTType(filenameExtension: "md") ?? .plainText,
                                  UTType(filenameExtension: "markdown") ?? .plainText]
        if documents.contains(where: { type.conforms(to: $0) }) { return .document }
        return nil
    }

    func importFile(_ url: URL, existingHashes: Set<String>) async throws -> ImportedSource {
        try Task.checkCancellation()
        guard url.isFileURL else { throw SourceImportError.unsupported }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw SourceImportError.invalidFile }
        guard let type = Self.type(for: url) else { throw SourceImportError.unsupported }
        guard let size = values.fileSize, size <= (type == .document ? 64 : 512) * 1024 * 1024 else { throw SourceImportError.tooLarge }
        let id = UUID()
        let filename = "original." + url.pathExtension.lowercased()
        let directory = storage.sourceDirectory(id: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let destination = storage.sourceURL(id: id, filename: filename)
            try FileManager.default.copyItem(at: url, to: destination)
            // Hash the owned copy, so identity is independent of external edits and names.
            let hash = try Self.hash(destination)
            guard !existingHashes.contains(hash) else { throw SourceImportError.duplicate }
            var duration: TimeInterval?
            if type == .audio {
                let asset = AVURLAsset(url: destination)
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                let seconds = try await asset.load(.duration).seconds
                guard !tracks.isEmpty, seconds.isFinite, seconds > 0 else { throw SourceImportError.invalidFile }
                duration = seconds
            }
            try Task.checkCancellation()
            return ImportedSource(id: id, type: type, filename: filename, originalFilename: url.lastPathComponent,
                                  hash: hash, duration: duration)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
    func discard(_ source: ImportedSource) throws { try FileManager.default.removeItem(at: storage.sourceDirectory(id: source.id)) }

    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
