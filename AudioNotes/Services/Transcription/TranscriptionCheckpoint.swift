import CryptoKit
import Foundation

/// Disposable results belong to the managed audio file and are removed after a successful save.
struct TranscriptionCheckpoint: Sendable {
    private let directory: URL

    static func directory(for audioURL: URL) -> URL {
        audioURL.deletingLastPathComponent().appendingPathComponent(
            "." + audioURL.lastPathComponent + ".transcription", isDirectory: true)
    }

    init?(audioURL: URL, configuration: [String]) {
        var url = audioURL
        url.removeAllCachedResourceValues()
        guard let revision = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileIdentifierKey]),
              let size = revision.fileSize, let modified = revision.contentModificationDate,
              let identifier = revision.fileIdentifier,
              let key = try? JSONEncoder().encode(configuration + [
                String(size), String(modified.timeIntervalSinceReferenceDate), String(identifier)
              ]) else { return nil }
        let digest = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
        directory = Self.directory(for: url).appendingPathComponent(digest, isDirectory: true)
    }

    private func partURL(start: TimeInterval, duration: TimeInterval) -> URL {
        directory.appendingPathComponent("\(start.bitPattern)-\(duration.bitPattern).json")
    }

    func read<Value: Decodable>(_ type: Value.Type, start: TimeInterval, duration: TimeInterval) -> Value? {
        guard let data = try? Data(contentsOf: partURL(start: start, duration: duration)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func save<Value: Encodable>(_ value: Value, start: TimeInterval, duration: TimeInterval) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(value).write(to: partURL(start: start, duration: duration), options: .atomic)
        } catch {
            // Caching is best-effort. A failed write must not discard the transcription result.
        }
    }

    static func hasSavedProgress(for audioURL: URL) -> Bool {
        let root = directory(for: audioURL)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "json" {
            return true
        }
        return false
    }

    static func clear(for audioURL: URL) {
        try? FileManager.default.removeItem(at: directory(for: audioURL))
    }
}
