import Foundation
import SQLite3

/// SQLite's online backup includes committed WAL pages without copying audio/models.
/// Source is read-only. Failed backups never replace either the source or a good backup.
struct MetadataBackup: Sendable {
    enum Failure: Error { case databaseUnavailable, snapshotFailed }

    func snapshot(database: URL, destination: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        let staging = destination.deletingLastPathComponent().appending(path: ".backup-\(UUID()).store")
        defer { try? files.removeItem(at: staging) }
        var source: OpaquePointer?
        guard sqlite3_open_v2(database.path, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let source { sqlite3_close(source) }
            throw Failure.databaseUnavailable
        }
        defer { sqlite3_close(source) }
        var output: OpaquePointer?
        guard sqlite3_open_v2(staging.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            if let output { sqlite3_close(output) }
            throw Failure.snapshotFailed
        }
        defer { if let output { sqlite3_close(output) } }
        guard let backup = sqlite3_backup_init(output, "main", source, "main") else { throw Failure.snapshotFailed }
        sqlite3_busy_timeout(source, 2000)
        sqlite3_busy_timeout(output, 2000)
        var status = sqlite3_backup_step(backup, -1)
        var retries = 0
        while (status == SQLITE_BUSY || status == SQLITE_LOCKED), retries < 100 {
            sqlite3_sleep(10)
            retries += 1
            status = sqlite3_backup_step(backup, -1)
        }
        let finished = sqlite3_backup_finish(backup)
        guard status == SQLITE_DONE, finished == SQLITE_OK else { throw Failure.snapshotFailed }
        // A portable single-file snapshot must not depend on WAL/SHM siblings.
        guard sqlite3_exec(output, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else { throw Failure.snapshotFailed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(output, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK else { throw Failure.snapshotFailed }
        defer { if let statement { sqlite3_finalize(statement) } }
        guard sqlite3_step(statement) == SQLITE_ROW, let result = sqlite3_column_text(statement, 0),
              String(cString: result) == "ok" else { throw Failure.snapshotFailed }
        sqlite3_finalize(statement)
        statement = nil
        guard sqlite3_close(output) == SQLITE_OK else { throw Failure.snapshotFailed }
        output = nil
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
        // Unique backup names prevent overwriting a recovery snapshot.
        guard !files.fileExists(atPath: destination.path) else { throw Failure.snapshotFailed }
        try files.moveItem(at: staging, to: destination)
    }

    func prepareBaseline(database: URL, backups: URL) throws {
        let baseline = backups.appending(path: "pre-v1.store")
        guard FileManager.default.fileExists(atPath: database.path),
              !FileManager.default.fileExists(atPath: baseline.path) else { return }
        try snapshot(database: database, destination: baseline)
    }
}
