import Foundation
import CryptoKit

struct WhisperModelDescriptor: Codable, Identifiable, Sendable {
    struct File: Codable, Sendable { let path: String; let url: URL; let size: Int64; let sha256: String? }
    let id: String
    let title: String
    let files: [File]
    var downloadBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    static var bundled: [Self] {
        guard let url = Bundle.main.url(forResource: "WhisperModels", withExtension: "json"),
              let bytes = try? Data(contentsOf: url), let models = try? JSONDecoder().decode([Self].self, from: bytes) else { return [] }
        return models
    }
}

struct LocalModelDownloadProgress: Sendable {
    var completedBytes: Int64
    var totalBytes: Int64
    var fraction: Double { totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 0 }
}

private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: @Sendable (Int64) -> Void
    init(report: @escaping @Sendable (Int64) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { report(totalBytesWritten) }
}

protocol WhisperModelFileDownloading: Sendable {
    func download(url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL
}

final class WhisperModelFileDownloader: WhisperModelFileDownloading, @unchecked Sendable {
    private let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil
        session = URLSession(configuration: config)
    }
    deinit { session.invalidateAndCancel() }
    func download(url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let delegate = ModelDownloadDelegate(report: progress)
        let (temporary, response) = try await session.download(from: url, delegate: delegate)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: temporary)
            throw LocalAIError.inference("Model download failed. Check your connection and retry.")
        }
        return temporary
    }
}

/// Owns only model files. A lease prevents deletion/download during native inference.
actor WhisperModelStore {
    let root: URL
    private var leased = false
    private let downloader: any WhisperModelFileDownloading
    private let capacity: @Sendable (URL) throws -> Int64?
    init(root: URL = LibraryStorage().rootURL.appending(path: "Models/Whisper", directoryHint: .isDirectory),
         downloader: any WhisperModelFileDownloading = WhisperModelFileDownloader(),
         capacity: @escaping @Sendable (URL) throws -> Int64? = { try $0.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage }) {
        self.root = root; self.downloader = downloader; self.capacity = capacity
    }
    func acquire() throws { if leased { throw LocalAIError.modelBusy }; leased = true }
    func release() { leased = false }
    func folder(_ model: WhisperModelDescriptor) -> URL { root.appendingPathComponent(model.id, isDirectory: true) }
    func isReady(_ model: WhisperModelDescriptor) -> Bool {
        let directory = folder(model)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(".ready").path) else { return false }
        return model.files.allSatisfy { file in
            let size = try? directory.appendingPathComponent(file.path).resourceValues(forKeys: [.fileSizeKey]).fileSize
            return size.map(Int64.init) == file.size
        }
    }
    func remove(_ model: WhisperModelDescriptor) throws {
        try acquire(); defer { release() }
        if FileManager.default.fileExists(atPath: folder(model).path) { try FileManager.default.removeItem(at: folder(model)) }
    }
    func install(_ model: WhisperModelDescriptor, progress: @escaping @Sendable (LocalModelDownloadProgress) -> Void) async throws {
        try acquire(); defer { release() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let capacity = try? capacity(root)
        if let capacity, capacity < model.downloadBytes + 256 * 1024 * 1024 { throw LocalAIError.insufficientDiskSpace }
        let staging = root.appendingPathComponent(".download-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var completed: Int64 = 0
        for file in model.files {
            try Task.checkCancellation()
            guard !file.path.hasPrefix("/"), !file.path.split(separator: "/").contains(".."), file.url.scheme == "https", file.url.host() == "huggingface.co" else { throw LocalAIError.invalidResponse }
            let baseline = completed
            let temporary = try await downloader.download(url: file.url) { written in
                progress(.init(completedBytes: baseline + min(written, file.size), totalBytes: model.downloadBytes))
            }
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(file.size) else { throw LocalAIError.invalidResponse }
            if let expected = file.sha256 { guard try Self.hash(temporary) == expected else { throw LocalAIError.inference("Model integrity verification failed. Retry the download.") } }
            let target = staging.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temporary, to: target)
            completed += file.size
            progress(.init(completedBytes: completed, totalBytes: model.downloadBytes))
        }
        try Task.checkCancellation()
        try Data(model.id.utf8).write(to: staging.appendingPathComponent(".ready"), options: .atomic)
        let destination = folder(model)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: staging, to: destination)
    }
    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var digest = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            try Task.checkCancellation(); digest.update(data: bytes)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
