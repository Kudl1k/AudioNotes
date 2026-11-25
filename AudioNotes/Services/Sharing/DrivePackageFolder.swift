import Foundation

actor DrivePackageFolder {
    private var selected: URL?
    private var listed: Set<URL> = []

    func remember(_ folder: URL) -> Data? {
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
#if os(macOS)
        return (try? folder.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess]))
            ?? (try? folder.bookmarkData())
#else
        return try? folder.bookmarkData(options: [.minimalBookmark])
#endif
    }

    func restore(_ bookmark: Data) throws -> URL {
        var stale = false
#if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
        if let scoped = try? URL(resolvingBookmarkData: bookmark, options: options.union(.withSecurityScope),
                                 relativeTo: nil, bookmarkDataIsStale: &stale) {
            return scoped
        }
#else
        let options: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
#endif
        return try URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
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
