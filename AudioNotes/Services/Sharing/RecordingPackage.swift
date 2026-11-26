import AVFoundation
import CryptoKit
import Foundation
import SwiftData
import UniformTypeIdentifiers

extension UTType {
    static let recordingPackage = UTType(exportedAs: "cz.kudladev.soniquill.recording-package", conformingTo: .data)
}

enum RecordingPackageError: LocalizedError, Equatable {
    case invalid, unsupportedVersion, sizeLimit, duplicate, missingTranscript

    var errorDescription: String? {
        switch self {
        case .invalid: "The Soniquill package is incomplete, damaged, or contains invalid recording data."
        case .unsupportedVersion: "This Soniquill package requires a different version of the app."
        case .sizeLimit: "The recording or its attachments exceed the Soniquill package limits."
        case .duplicate: "This recording or part of its transcript already exists in the library."
        case .missingTranscript: "A completed transcript is required to share this recording."
        }
    }
}

struct RecordingPackageManifest: Codable, Sendable {
    struct File: Codable, Sendable, Equatable {
        let type: RecordingSourceType
        let name: String
        let ext: String
        let bytes: UInt64
        let sha256: String
    }
    struct Segment: Codable, Sendable, Equatable {
        let id: UUID
        let position: Int
        let start: Double
        let end: Double
        let text: String
        let speaker: String?
    }
    struct Text: Codable, Sendable, Equatable {
        let date: Date
        let language: String?
        let sourceName: String?
        let isMock: Bool
        let segments: [Segment]
    }
    let version: Int
    let recordingID: UUID
    let title: String
    let transcript: Text
    let files: [File]
}

struct RecordingPackageSnapshot: Sendable {
    struct File: Sendable, Equatable {
        let type: RecordingSourceType
        let name: String
        let url: URL
    }
    let recordingID: UUID
    let title: String
    let transcript: RecordingPackageManifest.Text
    let files: [File]

    /// Copies `recording` on the caller's actor, which must own the recording's model context.
    init(recording: Recording, selected: Set<UUID>, storage: LibraryStorage) throws {
        guard let transcript = recording.transcript, !transcript.segments.isEmpty else {
            throw RecordingPackageError.missingTranscript
        }
        recordingID = recording.id
        title = recording.title
        self.transcript = .init(date: transcript.createdAt, language: transcript.languageCode,
                                sourceName: transcript.sourceName, isMock: transcript.isMock,
                                segments: transcript.orderedSegments.map {
            .init(id: $0.id, position: $0.position, start: $0.startTime, end: $0.endTime,
                  text: $0.text, speaker: $0.speaker)
        })
        files = [.init(type: .audio, name: recording.originalFileName,
                       url: storage.recordingURL(fileName: recording.audioFileName))]
            + recording.sources.filter { !$0.isPrimaryAudio && selected.contains($0.id) }
                .sorted {
                    ($0.originalFilename, $0.type.rawValue, $0.contentHash ?? "", $0.id.uuidString) <
                    ($1.originalFilename, $1.type.rawValue, $1.contentHash ?? "", $1.id.uuidString)
                }
                .map {
                    .init(type: $0.type, name: $0.originalFilename,
                          url: storage.sourceURL(id: $0.id, filename: $0.localFileReference))
                }
    }
}

actor RecordingPackageCodec {
    private static let magic = Data("SONIQUILL".utf8)
    private static let manifestLimit = 32 * 1_048_576
    private static let totalLimit: UInt64 = 8 * 1024 * 1_048_576
    private let fm = FileManager.default

    struct Staged: Sendable {
        let manifest: RecordingPackageManifest
        let directory: URL
        let urls: [URL]
        let durations: [Int: Double]
    }

    @discardableResult
    func export(_ snapshot: RecordingPackageSnapshot, to destination: URL) throws -> RecordingPackageManifest {
        guard snapshot.files.count <= 101 else { throw RecordingPackageError.sizeLimit }
        let prepared = try snapshot.files.enumerated().map { index, item in
            let size = try regularFileSize(item.url)
            let ext = item.url.pathExtension.lowercased()
            try validateFile(type: item.type, ext: ext, size: size, primary: index == 0)
            let entry = RecordingPackageManifest.File(type: item.type, name: item.name,
                ext: ext, bytes: size, sha256: try SourceImportService.hash(item.url))
            return (source: item, entry: entry)
        }
        let ordered: [(source: RecordingPackageSnapshot.File, entry: RecordingPackageManifest.File)]
        if let primary = prepared.first {
            ordered = [primary] + prepared.dropFirst().sorted {
                ($0.entry.name, $0.entry.type.rawValue, $0.entry.sha256) <
                ($1.entry.name, $1.entry.type.rawValue, $1.entry.sha256)
            }
        } else {
            ordered = []
        }
        let files = ordered.map(\.entry)
        let manifest = RecordingPackageManifest(version: 1, recordingID: snapshot.recordingID,
                                                 title: snapshot.title, transcript: snapshot.transcript, files: files)
        try validate(manifest)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(manifest)
        guard json.count <= Self.manifestLimit else { throw RecordingPackageError.sizeLimit }
        try withNewFile(destination) { output in
            try output.write(contentsOf: Self.magic)
            var length = UInt64(json.count).bigEndian
            try output.write(contentsOf: withUnsafeBytes(of: &length) { Data($0) })
            try output.write(contentsOf: json)
            for item in ordered {
                let input = try FileHandle(forReadingFrom: item.source.url)
                defer { try? input.close() }
                try transfer(item.entry, from: input, to: output)
                guard try input.read(upToCount: 1)?.isEmpty != false else { throw RecordingPackageError.invalid }
            }
        }
        return manifest
    }

    func savePrepared(_ source: URL, to destination: URL) throws {
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID()).soniquill")
        defer { try? fm.removeItem(at: temporary) }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        try withNewFile(temporary) { output in
            while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: data)
            }
        }
        try Task.checkCancellation()
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fm.moveItem(at: temporary, to: destination)
        }
    }

    func stage(_ source: URL, under root: URL) async throws -> Staged {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard source.isFileURL,
              try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw RecordingPackageError.invalid
        }
        let coordinator = NSFileCoordinator()
        var accessError: NSError?
        var extracted: Result<(RecordingPackageManifest, URL, [URL]), Error>?
        coordinator.coordinate(readingItemAt: source, options: [], error: &accessError) { coordinated in
            extracted = Result { try unpack(coordinated, under: root) }
        }
        if let accessError {
            if let extracted, case .success((_, let directory, _)) = extracted { try? fm.removeItem(at: directory) }
            throw accessError
        }
        guard let extracted else { throw RecordingPackageError.invalid }
        let (manifest, directory, urls) = try extracted.get()
        do {
            var durations: [Int: Double] = [:]
            for (index, file) in manifest.files.enumerated() where file.type == .audio {
                let asset = AVURLAsset(url: urls[index])
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                let duration = try await asset.load(.duration).seconds
                guard !tracks.isEmpty, duration.isFinite, duration > 0 else {
                    throw RecordingPackageError.invalid
                }
                durations[index] = duration
            }
            guard let duration = durations[0],
                  manifest.transcript.segments.allSatisfy({ $0.end <= duration + 1 }) else {
                throw RecordingPackageError.invalid
            }
            try Task.checkCancellation()
            return Staged(manifest: manifest, directory: directory, urls: urls, durations: durations)
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    private func unpack(_ source: URL, under root: URL) throws -> (RecordingPackageManifest, URL, [URL]) {
        let size = try regularFileSize(source)
        guard size <= Self.totalLimit + UInt64(Self.manifestLimit + 17) else {
            throw RecordingPackageError.sizeLimit
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard try read(Self.magic.count, from: input) == Self.magic else {
            throw RecordingPackageError.invalid
        }
        let length = try read(8, from: input).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard length > 0, length <= Self.manifestLimit else { throw RecordingPackageError.sizeLimit }
        let bytes = try read(Int(length), from: input)
        struct Version: Decodable { let version: Int }
        let decoder = JSONDecoder()
        guard let version = try? decoder.decode(Version.self, from: bytes) else {
            throw RecordingPackageError.invalid
        }
        guard version.version == 1 else { throw RecordingPackageError.unsupportedVersion }
        guard let manifest = try? decoder.decode(RecordingPackageManifest.self, from: bytes) else {
            throw RecordingPackageError.invalid
        }
        try validate(manifest)
        let expectedSize = UInt64(Self.magic.count + 8) + length + manifest.files.reduce(0) { $0 + $1.bytes }
        guard expectedSize == size else { throw RecordingPackageError.invalid }

        let directory = root.appendingPathComponent("SharingImport-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            var urls: [URL] = []
            for (index, file) in manifest.files.enumerated() {
                let url = directory.appendingPathComponent("\(index).\(file.ext)")
                try withNewFile(url) { try transfer(file, from: input, to: $0) }
                urls.append(url)
            }
            guard try input.read(upToCount: 1)?.isEmpty != false else { throw RecordingPackageError.invalid }
            try Task.checkCancellation()
            return (manifest, directory, urls)
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    private func validate(_ manifest: RecordingPackageManifest) throws {
        guard !manifest.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              manifest.title.utf8.count <= 4096, manifest.files.first?.type == .audio,
              !manifest.transcript.segments.isEmpty,
              manifest.transcript.segments.count <= 200_000,
              Set(manifest.transcript.segments.map(\.id)).count == manifest.transcript.segments.count,
              manifest.transcript.segments.allSatisfy({
                  $0.position >= 0 && $0.start.isFinite && $0.end.isFinite &&
                  $0.start >= 0 && $0.end >= $0.start
              }) else { throw RecordingPackageError.invalid }
        guard manifest.files.count <= 101 else { throw RecordingPackageError.sizeLimit }
        var total: UInt64 = 0
        for (index, file) in manifest.files.enumerated() {
            try validateFile(type: file.type, ext: file.ext, size: file.bytes, primary: index == 0)
            total += file.bytes
            guard total <= Self.totalLimit else { throw RecordingPackageError.sizeLimit }
            guard !file.name.isEmpty, file.name.utf8.count <= 1024,
                  !file.name.contains("/"), !file.name.contains("\0"),
                  file.sha256.utf8.count == 64,
                  file.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw RecordingPackageError.invalid
            }
        }
    }

    private func validateFile(type: RecordingSourceType, ext: String, size: UInt64, primary: Bool) throws {
        guard !ext.isEmpty, ext.utf8.count <= 12,
              ext.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }),
              let uti = UTType(filenameExtension: ext) else { throw RecordingPackageError.invalid }
        let recognized = switch type {
        case .audio: uti.conforms(to: .audio)
        case .pdf: ext == "pdf"
        case .image: ["jpg", "jpeg", "png", "heic", "heif"].contains(ext)
        case .document: ["txt", "md", "markdown"].contains(ext)
        }
        guard recognized else { throw RecordingPackageError.invalid }
        let maximum = primary ? Self.totalLimit : UInt64(type == .document ? 64 : 512) * 1_048_576
        guard size > 0, size <= maximum else { throw RecordingPackageError.sizeLimit }
    }

    private func regularFileSize(_ url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0 else { throw RecordingPackageError.invalid }
        return UInt64(size)
    }

    private func withNewFile(_ url: URL, write: (FileHandle) throws -> Void) throws {
        guard !fm.fileExists(atPath: url.path), fm.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteFileExists)
        }
        do {
            let output = try FileHandle(forWritingTo: url)
            defer { try? output.close() }
            try write(output)
            try output.synchronize()
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }
    }

    private func read(_ count: Int, from input: FileHandle) throws -> Data {
        var result = Data()
        while result.count < count {
            try Task.checkCancellation()
            guard let part = try input.read(upToCount: count - result.count), !part.isEmpty else {
                throw RecordingPackageError.invalid
            }
            result.append(part)
        }
        return result
    }

    private func transfer(_ file: RecordingPackageManifest.File, from input: FileHandle, to output: FileHandle) throws {
        var digest = SHA256()
        var remaining = file.bytes
        while remaining > 0 {
            let part = try read(Int(min(remaining, 1_048_576)), from: input)
            try output.write(contentsOf: part)
            digest.update(data: part)
            remaining -= UInt64(part.count)
        }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard hash == file.sha256 else { throw RecordingPackageError.invalid }
    }
}

@MainActor
enum RecordingPackageImport {
    private struct Journal: Codable {
        let recordingID: UUID
        let audioName: String
        let sourceIDs: [UUID]
    }

    static func recover(storage: LibraryStorage, context: ModelContext) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storage.rootURL.path) else { return }
        let directories = try fm.contentsOfDirectory(at: storage.rootURL,
                                                      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        for directory in directories {
            let name = directory.lastPathComponent
            let prefix = "SharingImport-"
            guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else { continue }
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let journalURL = directory.appendingPathComponent("publication.json")
            if fm.fileExists(atPath: journalURL.path) {
                let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
                let parts = journal.audioName.split(separator: ".", omittingEmptySubsequences: false)
                guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil,
                      !parts[1].isEmpty, parts[1].utf8.count <= 12,
                      parts[1].utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }),
                      journal.sourceIDs.count <= 100 else { throw RecordingPackageError.invalid }
                let id = journal.recordingID
                let request = FetchDescriptor<Recording>(predicate: #Predicate { $0.id == id })
                if try !context.fetch(request).contains(where: { $0.audioFileName == journal.audioName }) {
                    try removeIfPresent(storage.recordingURL(fileName: journal.audioName))
                    for sourceID in journal.sourceIDs { try removeIfPresent(storage.sourceDirectory(id: sourceID)) }
                }
            }
            try fm.removeItem(at: directory)
        }
    }

    private static func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    static func applySyncedTranscript(_ incoming: RecordingPackageManifest,
                                      replacing snapshot: RecordingPackageSnapshot,
                                      projectID: UUID,
                                      storage: LibraryStorage, container: ModelContainer) throws {
        try Task.checkCancellation()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let id = snapshot.recordingID
        let request = FetchDescriptor<Recording>(predicate: #Predicate { $0.id == id })
        guard incoming.recordingID == id, let recording = try context.fetch(request).first,
              recording.project?.id == projectID,
              let transcript = recording.transcript else { throw DriveProjectError.conflictingVersion }
        let current = try RecordingPackageSnapshot(recording: recording, selected: Set(recording.sources.map(\.id)), storage: storage)
        guard current.title == snapshot.title, current.transcript == snapshot.transcript,
              current.files == snapshot.files,
              Set(incoming.transcript.segments.map(\.id)) == Set(snapshot.transcript.segments.map(\.id)) else {
            throw DriveProjectError.conflictingVersion
        }
        let segments = Dictionary(uniqueKeysWithValues: transcript.segments.map { ($0.id, $0) })
        for item in incoming.transcript.segments {
            guard let segment = segments[item.id] else { throw DriveProjectError.conflictingVersion }
            segment.position = item.position
            segment.startTime = item.start
            segment.endTime = item.end
            segment.text = item.text
            segment.speaker = item.speaker
        }
        recording.title = incoming.title
        transcript.createdAt = incoming.transcript.date
        transcript.languageCode = incoming.transcript.language
        transcript.sourceName = incoming.transcript.sourceName
        transcript.isMock = incoming.transcript.isMock
        try context.save()
    }

    static func commit(_ staged: RecordingPackageCodec.Staged, storage: LibraryStorage,
                       container: ModelContainer, projectID: UUID? = nil) throws -> UUID {
        let fm = FileManager.default
        var retainJournal = false
        defer { if !retainJournal { try? fm.removeItem(at: staged.directory) } }
        try Task.checkCancellation()
        let manifest = staged.manifest
        let id = manifest.recordingID
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var project: Project?
        if let projectID {
            project = try context.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.id == projectID })).first
            guard project != nil else { throw DriveProjectError.noProjects }
        }
        var duplicate = FetchDescriptor<Recording>(predicate: #Predicate { $0.id == id })
        duplicate.fetchLimit = 1
        guard try context.fetch(duplicate).isEmpty else { throw RecordingPackageError.duplicate }
        let ids = manifest.transcript.segments.map(\.id)
        for start in stride(from: 0, to: ids.count, by: 400) {
            try Task.checkCancellation()
            let batch = Array(ids[start..<min(start + 400, ids.count)])
            var request = FetchDescriptor<TranscriptSegment>(predicate: #Predicate { batch.contains($0.id) })
            request.fetchLimit = 1
            guard try context.fetch(request).isEmpty else { throw RecordingPackageError.duplicate }
        }
        guard let duration = staged.durations[0] else { throw RecordingPackageError.invalid }
        let audio = manifest.files[0]
        let filename = "\(UUID()).\(audio.ext)"
        let recording = Recording(id: id, title: manifest.title, audioFileName: filename,
                                  originalFileName: audio.name, duration: duration)
        let text = manifest.transcript
        let transcript = Transcript(languageCode: text.language, createdAt: text.date,
                                    sourceName: text.sourceName, isMock: text.isMock)
        transcript.segments = text.segments.map {
            TranscriptSegment(id: $0.id, position: $0.position, startTime: $0.start,
                              endTime: $0.end, text: $0.text, speaker: $0.speaker)
        }
        recording.transcript = transcript
        let sources = manifest.files.enumerated().map { index, entry in
            let primary = index == 0
            let source = RecordingSource(type: entry.type, displayName: entry.name,
                                         originalFilename: entry.name,
                                         localFileReference: primary ? filename : "original.\(entry.ext)",
                                         status: primary ? .ready : .imported)
            source.isPrimaryAudio = primary
            source.contentHash = entry.sha256
            if let duration = staged.durations[index] { source.metadata = .audio(duration: duration) }
            return source
        }
        recording.sources = sources
        let journal = Journal(recordingID: id, audioName: filename, sourceIDs: sources.dropFirst().map(\.id))
        let journalURL = staged.directory.appendingPathComponent("publication.json")
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        let handle = try FileHandle(forWritingTo: journalURL)
        defer { try? handle.close() }
        try handle.synchronize()

        var published: [URL] = []
        do {
            try fm.createDirectory(at: storage.recordingsURL, withIntermediateDirectories: true)
            for (index, source) in sources.enumerated() {
                try Task.checkCancellation()
                let target: URL
                if source.isPrimaryAudio {
                    target = storage.recordingURL(fileName: filename)
                } else {
                    let directory = storage.sourceDirectory(id: source.id)
                    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                    published.append(directory)
                    target = storage.sourceURL(id: source.id, filename: source.localFileReference)
                }
                try fm.moveItem(at: staged.urls[index], to: target)
                if source.isPrimaryAudio { published.append(target) }
            }
            try Task.checkCancellation()
            context.insert(recording)
            recording.project = project
            try context.save()
            return id
        } catch {
            for url in published.reversed() {
                do { try removeIfPresent(url) }
                catch { retainJournal = true }
            }
            throw error
        }
    }
}
