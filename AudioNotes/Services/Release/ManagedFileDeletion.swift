import Foundation

/// Durable journal before moving owned originals. A crash before the commit
/// marker restores files on launch; a crash after it only removes committed trash.
/// If metadata committed but the marker did not, restore conservatively (orphans
/// are preferable to losing files). Never infer ownership from imported names.
struct ManagedFileDeletion {
    struct Entry: Codable { let original: String; let staged: String }
    struct Journal: Codable { var committed = false; let entries: [Entry] }
    enum Failure: Error { case outsideManagedRoot, invalidJournal, restorationConflict }
    let root: URL

    func stageAndCommit(_ urls: [URL], commit: () throws -> Void) throws {
        let files = FileManager.default
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let owned = try urls.map { try relative($0, within: root) }
        let entries = Set(owned).sorted().filter { files.fileExists(atPath: root.appending(path: $0).path) }
            .map { Entry(original: $0, staged: UUID().uuidString) }
        guard !entries.isEmpty else { try commit(); return }
        let staging = root.appending(path: "Deletion-" + UUID().uuidString)
        try files.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var journal = Journal(entries: entries)
        let manifest = staging.appending(path: "journal.json")
        do {
            try JSONEncoder().encode(journal).write(to: manifest, options: .atomic)
            for entry in entries {
                try files.moveItem(at: root.appending(path: entry.original), to: staging.appending(path: entry.staged))
            }
            try commit()
        } catch {
            try restore(journal, staging: staging, root: root)
            try files.removeItem(at: staging)
            throw error
        }
        journal.committed = true
        do {
            try JSONEncoder().encode(journal).write(to: manifest, options: .atomic)
            try files.removeItem(at: staging)
        } catch { throw WorkspaceDeletionError.cleanupFailed(error) }
    }

    func recover() throws {
        let files = FileManager.default
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        guard files.fileExists(atPath: root.path) else { return }
        for staging in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            where staging.lastPathComponent.hasPrefix("Deletion-") {
            let values = try staging.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw Failure.invalidJournal }
            let manifest = staging.appending(path: "journal.json")
            if !files.fileExists(atPath: manifest.path), try files.contentsOfDirectory(atPath: staging.path).isEmpty {
                try files.removeItem(at: staging)
                continue
            }
            let bytes = try Data(contentsOf: manifest)
            guard bytes.count < 8 * 1024 * 1024 else { throw Failure.invalidJournal }
            let journal = try JSONDecoder().decode(Journal.self, from: bytes)
            for entry in journal.entries {
                guard UUID(uuidString: entry.staged) != nil,
                      try relative(root.appending(path: entry.original), within: root) == entry.original else { throw Failure.invalidJournal }
            }
            if !journal.committed { try restore(journal, staging: staging, root: root) }
            try files.removeItem(at: staging)
        }
    }

    private func relative(_ url: URL, within root: URL) throws -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = root.path + "/"
        guard path.hasPrefix(prefix) else { throw Failure.outsideManagedRoot }
        let relative = String(path.dropFirst(prefix.count))
        guard !relative.isEmpty, !relative.split(separator: "/").contains("..") else { throw Failure.outsideManagedRoot }
        return relative
    }

    private func restore(_ journal: Journal, staging: URL, root: URL) throws {
        let files = FileManager.default
        for entry in journal.entries.reversed() {
            let original = root.appending(path: entry.original)
            let staged = staging.appending(path: entry.staged)
            guard files.fileExists(atPath: staged.path) else { continue }
            guard !files.fileExists(atPath: original.path) else { throw Failure.restorationConflict }
            try files.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.moveItem(at: staged, to: original)
        }
    }
}
