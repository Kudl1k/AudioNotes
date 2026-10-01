import Foundation
import SQLite3
import SwiftData
import Testing
@testable import AudioNotes

@MainActor
struct ReleaseEngineeringTests {
    @Test func updateConfigurationRejectsUnsafeOrIncompleteValues() {
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        #expect(UpdateConfiguration(feed: "https://kudl1k.github.io/AudioNotes/appcast.xml", publicKey: key) != nil)
        for feed in [nil, "", "$(AUDIONOTES_UPDATE_FEED_URL)", "http://localhost/appcast.xml", "https://user:password@github.io/feed"] {
            #expect(UpdateConfiguration(feed: feed, publicKey: key) == nil)
        }
        #expect(UpdateConfiguration(feed: "https://example.org/feed", publicKey: "not-a-key") == nil)
    }

    @Test func diagnosticsContainOnlyAllowlistedFields() throws {
        let report = DiagnosticReport(updateConfigured: false, libraryOpenFailed: true)
        let data = try report.data()
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["application", "macOS", "architecture", "schema", "updateConfigured", "libraryOpenFailed"])
        let app = try #require(json["application"] as? [String: Any])
        #expect(Set(app.keys) == ["name", "bundleIdentifier", "version", "build", "copyright"])
        #expect(!String(decoding: data, as: UTF8.self).contains(NSHomeDirectory()))
    }

    @Test func backupIncludesCommittedWALAndRetainsOriginalOnFailure() throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        try FileManager.default.createDirectory(at: workspace.storage.rootURL, withIntermediateDirectories: true)
        let source = workspace.storage.rootURL.appending(path: "wal.sqlite")
        var db: OpaquePointer?
        #expect(sqlite3_open(source.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE sample(value TEXT); INSERT INTO sample VALUES ('český text');", nil, nil, nil) == SQLITE_OK)
        let backup = workspace.storage.rootURL.appending(path: "backup.sqlite")
        try MetadataBackup().snapshot(database: source, destination: backup)
        var copied: OpaquePointer?
        #expect(sqlite3_open_v2(backup.path, &copied, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(copied) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(copied, "SELECT value FROM sample", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(String(cString: try #require(sqlite3_column_text(statement, 0))) == "český text")
        let corrupt = workspace.storage.rootURL.appending(path: "corrupt.store")
        let original = Data("not a database; preserve me".utf8)
        try original.write(to: corrupt)
        #expect(throws: (any Error).self) { try MetadataBackup().snapshot(database: corrupt, destination: workspace.storage.rootURL.appending(path: "bad.sqlite")) }
        #expect(try Data(contentsOf: corrupt) == original)
        #expect(!FileManager.default.fileExists(atPath: workspace.storage.rootURL.appending(path: "bad.sqlite").path))
    }

    @Test func deletionRollbackAndCrashRecoveryPreserveFiles() throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let root = workspace.storage.rootURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appending(path: "Recordings/audio.wav")
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("owned original".utf8); try bytes.write(to: original)
        let deletion = ManagedFileDeletion(root: root)
        #expect(throws: CocoaError.self) {
            try deletion.stageAndCommit([original]) { throw CocoaError(.fileWriteUnknown) }
        }
        #expect(try Data(contentsOf: original) == bytes)
        let stage = root.appending(path: "Deletion-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let name = UUID().uuidString
        let journal = ManagedFileDeletion.Journal(entries: [.init(original: "Recordings/audio.wav", staged: name)])
        try JSONEncoder().encode(journal).write(to: stage.appending(path: "journal.json"))
        try FileManager.default.moveItem(at: original, to: stage.appending(path: name))
        try deletion.recover()
        try deletion.recover()
        #expect(try Data(contentsOf: original) == bytes)
        #expect(!FileManager.default.fileExists(atPath: stage.path))
        try deletion.stageAndCommit([original]) {}
        #expect(!FileManager.default.fileExists(atPath: original.path))
    }

    @Test func deletionRejectsPathsOutsideManagedRoot() throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let outside = workspace.storage.rootURL.deletingLastPathComponent().appending(path: UUID().uuidString)
        #expect(throws: ManagedFileDeletion.Failure.self) {
            try ManagedFileDeletion(root: workspace.storage.rootURL).stageAndCommit([outside]) { Issue.record("must not commit") }
        }
    }

    @Test func newIdentityRetainsDevelopmentSandboxAndNonSecretPreferences() throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let home = workspace.storage.rootURL
        let oldRoot = home.appending(path: "Library/Containers/cz.kudladev.AudioNotes/Data/Library/Application Support")
        try FileManager.default.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: oldRoot.appending(path: "default.store"))
        #expect(AppStorageLocations.applicationSupport(home: home, bundleID: "cz.stepankudlacek.audionotes", fallback: home) == oldRoot)
        let preferences = home.appending(path: "Library/Preferences/cz.kudladev.AudioNotes.plist")
        try FileManager.default.createDirectory(at: preferences.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["ai.localOnly": true, "llm.access_token": "never-copy", "llm.chat.provider": "ollama"], format: .binary, options: 0).write(to: preferences)
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        AppStorageLocations.restorePreferences(home: home, bundleID: "cz.stepankudlacek.audionotes", defaults: defaults)
        #expect(defaults.bool(forKey: "ai.localOnly"))
        #expect(defaults.string(forKey: "llm.chat.provider") == "ollama")
        #expect(defaults.object(forKey: "llm.access_token") == nil)
    }

    @Test func corruptStartupOffersRecoveryWithoutWipingStore() throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        // Test LibraryStorage directly: XCTest host intentionally uses in-memory startup.
        try FileManager.default.createDirectory(at: workspace.storage.rootURL, withIntermediateDirectories: true)
        let database = workspace.storage.rootURL.appending(path: "Library.store")
        let bytes = Data("corrupt but retained".utf8); try bytes.write(to: database)
        #expect(throws: (any Error).self) { try workspace.storage.makeContainer() }
        #expect(try Data(contentsOf: database) == bytes)
    }
}
