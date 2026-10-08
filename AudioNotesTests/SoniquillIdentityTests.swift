import Foundation
import SwiftData
import Testing
@testable import AudioNotes

@MainActor
struct SoniquillIdentityTests {
    @Test func credentialLookupServicesRetainLegacyIdentity() {
        #expect(KeychainService.defaultService == "cz.kudladev.AudioNotes.provider-credentials")
        #expect(GoogleOAuthKeychainStore.defaultService == KeychainService.defaultService)
        #expect(ChatGPTCredentialStore.defaultService == "cz.kudladev.AudioNotes.chatgpt-credentials")
    }

    @Test func builtProductHasSharedSoniquillIdentity() {
        #expect(Bundle.main.bundleIdentifier == "cz.kudladev.soniquill")
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == "Soniquill")
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String == "Soniquill")
        #expect(ReleaseIdentity().name == "Soniquill")
        #expect(ReleaseSupportViewModel.diagnosticsFileName == "Soniquill-Diagnostics.json")
    }

#if os(macOS)
    @Test(arguments: ["cz.kudladev.AudioNotes", "cz.stepankudlacek.audionotes"])
    func renamedIdentityReopensExistingSandboxLibrary(legacyID: String) throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let home = workspace.root
        let support = home.appending(path: "Library/Containers/\(legacyID)/Data/Library/Application Support")
        let storage = LibraryStorage(rootURL: support.appending(path: "AudioNotes"))
        let database = support.appending(path: "default.store")
        let recordingID = UUID()
        do {
            let container = try storage.makeContainer(databaseURL: database)
            let context = ModelContext(container)
            let recording = Recording(id: recordingID, title: "Existing library", audioFileName: "existing.wav", originalFileName: "existing.wav", duration: 1)
            context.insert(recording)
            try context.save()
        }
        try FileManager.default.createDirectory(at: storage.recordingsURL, withIntermediateDirectories: true)
        let original = Data("managed audio".utf8)
        try original.write(to: storage.recordingURL(fileName: "existing.wav"))
        let resolved = AppStorageLocations.applicationSupport(home: home, bundleID: "cz.kudladev.soniquill", fallback: home.appending(path: "empty"))
        #expect(resolved == support)
        let reopened = try LibraryStorage(rootURL: resolved.appending(path: "AudioNotes")).makeContainer(databaseURL: resolved.appending(path: "default.store"))
        let recordings = try ModelContext(reopened).fetch(FetchDescriptor<Recording>())
        #expect(recordings.map(\.id) == [recordingID])
        #expect(recordings.first?.title == "Existing library")
        #expect(try Data(contentsOf: storage.recordingURL(fileName: "existing.wav")) == original)
        #expect(!FileManager.default.fileExists(atPath: support.appending(path: "Soniquill").path))
    }

    @Test func renamedPreferencesPreserveChoicesAndDoNotCopySecrets() throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let preferences = workspace.root.appending(path: "Library/Preferences/cz.stepankudlacek.audionotes.plist")
        try FileManager.default.createDirectory(at: preferences.deletingLastPathComponent(), withIntermediateDirectories: true)
        let values: [String: Any] = [
            "llm.summary.provider": "mock", "llm.chat.provider": "openai", "llm.summary.openai.model": "gpt-4o",
            "llm.summary.preset": "meeting", "llm.summary.settings.max_tokens": 1234,
            "transcription.provider": "openai", "ai.localOnly": true, "libraryShowsCost": true,
            "onboarding.completed.v1": true, "chatgpt.ext_agent_host_id": "urn:uuid:fixture",
            "storage.desktopPreferencesRestored": true, "llm.api_key": "test-secret", "llm.access_token": "test-token",
            "unrelated": "do not copy"
        ]
        try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0).write(to: preferences)
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("ollama", forKey: "llm.chat.provider")
        AppStorageLocations.restorePreferences(home: workspace.root, bundleID: "cz.kudladev.soniquill", defaults: defaults)
        let configuration = LLMConfiguration(defaults: defaults)
        #expect(configuration.chatProvider == .ollama)
        #expect(configuration.summaryProvider == .mock)
        #expect(configuration.defaultPreset == .meeting)
        #expect(defaults.string(forKey: "llm.summary.openai.model") == "gpt-4o")
        #expect(defaults.integer(forKey: "llm.summary.settings.max_tokens") == 1234)
        #expect(defaults.string(forKey: "transcription.provider") == "openai")
        #expect(configuration.localAI.localOnly)
        #expect(defaults.bool(forKey: "libraryShowsCost"))
        #expect(defaults.bool(forKey: "onboarding.completed.v1"))
        #expect(ChatGPTHostManager.hostID(defaults: defaults) == "urn:uuid:fixture")
        for key in ["llm.api_key", "llm.access_token", "unrelated"] { #expect(defaults.object(forKey: key) == nil) }
        defaults.removeObject(forKey: "libraryShowsCost")
        AppStorageLocations.restorePreferences(home: workspace.root, bundleID: "cz.kudladev.soniquill", defaults: defaults)
        #expect(defaults.object(forKey: "libraryShowsCost") == nil)
    }

    @Test func renamedIdentityPreservesDesktopRootAndPreviousDomainPrecedence() throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        #expect(AppStorageLocations.applicationSupport(home: workspace.root, bundleID: "cz.kudladev.soniquill", fallback: workspace.root) == workspace.root)
        let folder = workspace.root.appending(path: "Library/Preferences")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (id, provider) in [("cz.kudladev.AudioNotes", "mock"), ("cz.stepankudlacek.audionotes", "ollama")] {
            try PropertyListSerialization.data(fromPropertyList: ["llm.chat.provider": provider], format: .binary, options: 0)
                .write(to: folder.appending(path: "\(id).plist"))
        }
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        AppStorageLocations.restorePreferences(home: workspace.root, bundleID: "cz.kudladev.soniquill", defaults: defaults)
        #expect(defaults.string(forKey: "llm.chat.provider") == "ollama")
    }
#endif
}
