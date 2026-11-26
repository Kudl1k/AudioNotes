import Foundation

actor DrivePackageFolder {
    private var selected: URL?
    private var listed: Set<URL> = []

    struct RestoredFolder: Sendable {
        let url: URL
        /// A replacement bookmark when the stored one was stale; callers should persist it.
        let refreshedBookmark: Data?
    }

    /// Creates a bookmark for a folder the user picked in a system panel/document picker.
    func remember(_ folder: URL) -> Data? {
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
#if os(macOS)
        // Sandboxed builds need a security-scoped bookmark to reopen the folder after relaunch.
        // The unscoped form is only a last resort for unsandboxed (e.g. test) hosts.
        return (try? folder.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess]))
            ?? (try? folder.bookmarkData(options: [.withSecurityScope]))
            ?? (try? folder.bookmarkData())
#else
        return try? folder.bookmarkData(options: [.minimalBookmark])
#endif
    }

    func restore(_ bookmark: Data) throws -> URL {
        try resolve(bookmark).url
    }

    /// Resolves a stored bookmark and, when the system reports it stale, re-creates it while access is held.
    func resolve(_ bookmark: Data) throws -> RestoredFolder {
        var stale = false
        let options: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
        let url: URL
#if os(macOS)
        if let scoped = try? URL(resolvingBookmarkData: bookmark, options: options.union(.withSecurityScope),
                                 relativeTo: nil, bookmarkDataIsStale: &stale) {
            url = scoped
        } else {
            stale = false
            url = try URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
        }
#else
        url = try URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
#endif
        return .init(url: url, refreshedBookmark: stale ? remember(url) : nil)
    }

    func packages(in folder: URL) throws -> [URL] {
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<[URL], Error>?
        coordinator.coordinate(readingItemAt: folder, options: [], error: &coordinationError) { url in
            result = Result {
                let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
                let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                                           options: [.skipsHiddenFiles])
                return children.filter {
                    guard $0.pathExtension.lowercased() == "soniquill",
                          let values = try? $0.resourceValues(forKeys: Set(keys)) else { return false }
                    return values.isRegularFile == true && values.isSymbolicLink != true
                }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw RecordingPackageError.invalid }
        let packages = try result.get()
        selected = folder
        listed = Set(packages)
        return packages
    }

    func stage(_ url: URL, storage: LibraryStorage) async throws -> RecordingPackageCodec.Staged {
        guard let selected, listed.contains(url) else { throw RecordingPackageError.invalid }
        let access = selected.startAccessingSecurityScopedResource()
        defer { if access { selected.stopAccessingSecurityScopedResource() } }
        return try await RecordingPackageCodec().stage(url, under: storage.rootURL)
    }
}
