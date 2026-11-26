import CryptoKit
import Foundation

struct DriveProjectFolder: Codable, Sendable, Equatable {
    let id: String
    let name: String
    var publishedProjectID: UUID? = nil

    var webURL: URL? {
        guard DriveProjectRemote.validID(id) else { return nil }
        return URL(string: "https://drive.google.com/drive/folders/\(id)")
    }

    /// Identity check that survives renames: the Drive ID and published project are stable, the name is not.
    func isSameFolder(as other: DriveProjectFolder) -> Bool {
        id == other.id && publishedProjectID == other.publishedProjectID
    }
}

/// What a validated Drive folder must permit.
/// - `publish`: a writable folder outside shared drives (a new sharing folder). Ownership is not required,
///   so an Editor of a folder someone else shared may use it.
/// - `linkPublished`: the same write rule for syncing into an already published project folder.
/// - `read`: any readable, non-trashed folder (import/listing/verification).
/// Shared drives need `supportsAllDrives` on every request, which this client does not send, so they are
/// rejected for writing.
enum DriveFolderAccess: Sendable {
    case publish, linkPublished, read
}

struct DriveProjectRemote: Sendable {
    static let folderType = "application/vnd.google-apps.folder"
    private static let files = URL(string: "https://www.googleapis.com/drive/v3/files")!
    private static let fields = "id,name,mimeType,size,sha256Checksum,createdTime,modifiedTime,trashed,parents,driveId,ownedByMe,appProperties,capabilities(canAddChildren)"
    let transport: DriveHTTPTransport
    let checkPrivacy: @Sendable () throws -> Void
    let token: GoogleDriveUpload.Token
    private let store: DefaultsBox
    /// Store for baselines, ID reservations and folder pairings. Tests inject a dedicated suite.
    var defaults: UserDefaults { store.value }

    /// `UserDefaults` is documented as thread-safe but not annotated `Sendable`.
    private struct DefaultsBox: @unchecked Sendable { let value: UserDefaults }

    init(transport: DriveHTTPTransport, checkPrivacy: @escaping @Sendable () throws -> Void,
         token: @escaping GoogleDriveUpload.Token, defaults: UserDefaults = .standard) {
        self.transport = transport
        self.checkPrivacy = checkPrivacy
        self.token = token
        self.store = DefaultsBox(value: defaults)
    }
    private static let baselineIndexLimit = 4096

    struct Item: Decodable, Sendable {
        struct Capabilities: Decodable, Sendable { let canAddChildren: Bool? }
        let id: String
        let name: String
        let mimeType: String
        let size: String?
        let appProperties: [String: String]?
        let sha256Checksum: String?
        let createdTime: String?
        let modifiedTime: String?
        let trashed: Bool?
        let parents: [String]?
        let driveId: String?
        let ownedByMe: Bool?
        let capabilities: Capabilities?
    }

    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 256 && id.utf8.allSatisfy {
            $0 == 45 || $0 == 95 || (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
    }

    func validateFolder(id: String, access: DriveFolderAccess = .publish) async throws -> DriveProjectFolder {
        let item = try await folderItem(id: id, access: access)
        return .init(id: item.id, name: item.name, publishedProjectID: publishedProjectID(in: item))
    }

    /// A shared parent can be used for import when it identifies exactly one visible published project.
    /// Picked files stand for their (single) parent folder; a picked folder stands for itself.
    func importFolder(picked ids: [String]) async throws -> DriveProjectFolder {
        var folders: Set<String> = []
        for id in ids {
            guard Self.validID(id) else { throw GoogleDriveSharingError.invalidResponse }
            let item: Item = try await get(Self.files.appendingPathComponent(id), fields: Self.fields)
            if item.mimeType == Self.folderType {
                folders.insert(item.id)
            } else if let parents = item.parents, parents.count == 1 {
                folders.insert(parents[0])
            } else {
                throw DriveProjectError.selectPublishedProject
            }
        }
        guard folders.count == 1, let folder = folders.first else { throw DriveProjectError.selectPublishedProject }
        return try await validateFolder(id: folder, access: .read)
    }

    func projectFolderForImport(_ selected: DriveProjectFolder) async throws -> DriveProjectFolder {
        if selected.publishedProjectID != nil { return selected }
        guard Self.validID(selected.id) else { throw GoogleDriveSharingError.invalidResponse }
        let query = "'\(selected.id)' in parents and trashed = false and mimeType = '\(Self.folderType)'"
        let projects = try await listFiles(query: query).compactMap { item -> DriveProjectFolder? in
            guard item.mimeType == Self.folderType, item.trashed != true,
                  item.parents?.contains(selected.id) == true,
                  let projectID = publishedProjectID(in: item) else { return nil }
            return .init(id: item.id, name: item.name, publishedProjectID: projectID)
        }
        guard projects.count == 1, let project = projects.first else {
            throw DriveProjectError.selectPublishedProject
        }
        return project
    }

    func sharingParent(of folder: DriveProjectFolder) async throws -> DriveProjectFolder? {
        guard let projectID = folder.publishedProjectID else { return nil }
        let item = try await folderItem(id: folder.id, access: .read)
        guard publishedProjectID(in: item) == projectID,
              let parents = item.parents, parents.count == 1, let parentID = parents.first,
              parentID != folder.id else { return nil }
        let parent = try await validateFolder(id: parentID)
        return parent.publishedProjectID == nil ? parent : nil
    }

    private func publishedProjectID(in item: Item) -> UUID? {
        guard let key = item.appProperties?["soniquillKey"], key.hasPrefix("p-") else { return nil }
        return UUID(uuidString: String(key.dropFirst(2)))
    }

    /// Current metadata of one Drive file, used to re-check its version immediately before an update.
    func metadata(id: String) async throws -> Item {
        guard Self.validID(id) else { throw GoogleDriveSharingError.invalidResponse }
        let item: Item = try await get(Self.files.appendingPathComponent(id), fields: Self.fields)
        guard item.id == id else { throw GoogleDriveSharingError.invalidResponse }
        return item
    }

    private func folderItem(id: String, access: DriveFolderAccess = .publish) async throws -> Item {
        guard Self.validID(id) else { throw GoogleDriveSharingError.invalidResponse }
        let item: Item = try await get(Self.files.appendingPathComponent(id), fields: Self.fields)
        guard item.id == id, item.mimeType == Self.folderType, item.trashed != true else {
            throw DriveProjectError.folderUnavailable
        }
        if let denial = Self.denial(access, item) { throw denial }
        return item
    }

    static func allows(_ access: DriveFolderAccess, _ item: Item) -> Bool {
        denial(access, item) == nil
    }

    /// Why `item` cannot be used for `access`, or nil when it can.
    static func denial(_ access: DriveFolderAccess, _ item: Item) -> DriveProjectError? {
        switch access {
        case .read:
            return nil
        case .publish, .linkPublished:
            if item.driveId != nil { return .sharedDriveUnsupported }
            if item.capabilities?.canAddChildren != true { return .folderReadOnly }
            return nil
        }
    }

    func children(in parent: String, key: String) async throws -> [Item] {
        guard Self.validID(parent), Self.validID(key) else { throw GoogleDriveSharingError.invalidResponse }
        let query = "'\(parent)' in parents and trashed = false and appProperties has { key='soniquillKey' and value='\(key)' }"
        return try await listFiles(query: query)
    }

    func child(in parent: String, key: String) async throws -> Item? {
        let matches = try await children(in: parent, key: key)
        guard matches.count <= 1 else { throw DriveProjectError.conflictingFiles }
        return matches.first
    }

    func publishedItems(in parent: String) async throws -> [Item] {
        guard Self.validID(parent) else { throw GoogleDriveSharingError.invalidResponse }
        return try await listFiles(query: "'\(parent)' in parents and trashed = false").filter { item in
            (item.name.hasSuffix(".soniquill") && Self.publishedID(item, prefix: "r-") != nil)
                || Self.publishedID(item, prefix: "s-") != nil
        }
    }

    static func publishedID(_ item: Item, prefix: String) -> UUID? {
        guard let key = item.appProperties?["soniquillKey"], key.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(key.dropFirst(2)))
    }

    /// Finds the Drive folder of `project` inside the sharing folder `parent`.
    ///
    /// Order: the folder carrying the project's own key, then a previously confirmed pairing, then
    /// (only when the project has recordings) a one-time scan of same-named project folders that already
    /// hold one of its recordings. Folders whose key belongs to another project of the same run are never
    /// paired. A scan match is persisted so later runs don't repeat the scan.
    func projectFolder(in parent: String, project: DriveProjectSnapshot,
                       access: DriveFolderAccess = .linkPublished,
                       excluding: Set<String> = []) async throws -> Item? {
        let key = "p-" + project.id.uuidString
        let direct = try await children(in: parent, key: key)
            .filter { $0.mimeType == Self.folderType && Self.allows(access, $0) }
        if let canonical = Self.canonicalFolder(from: direct, preferredName: project.name) {
            return canonical
        }
        let excluded = excluding.subtracting([key])
        if let paired = try await pairedFolder(in: parent, project: project, access: access, excluding: excluded) {
            return paired
        }
        guard !project.recordings.isEmpty else { return nil }
        let folderQuery = "'\(parent)' in parents and trashed = false and mimeType = '\(Self.folderType)'"
        let target = Self.normalizedName(project.name)
        let candidates = try await listFiles(query: folderQuery).filter {
            guard $0.mimeType == Self.folderType, $0.trashed != true, Self.allows(access, $0),
                  let candidateKey = $0.appProperties?["soniquillKey"], candidateKey.hasPrefix("p-"),
                  !excluded.contains(candidateKey) else { return false }
            return Self.normalizedName($0.name).localizedCaseInsensitiveCompare(target) == .orderedSame
        }
        var matched: [Item] = []
        for candidate in candidates.prefix(20) {
            for recording in project.recordings {
                try Task.checkCancellation()
                let items = try await children(in: candidate.id, key: "r-" + recording.recordingID.uuidString)
                if items.contains(where: { $0.mimeType != Self.folderType }) {
                    matched.append(candidate)
                    break
                }
            }
        }
        guard matched.count == 1 else { return nil }
        savePairing(matched[0].id, parent: parent, projectID: project.id)
        return matched[0]
    }

    private func pairedFolder(in parent: String, project: DriveProjectSnapshot,
                              access: DriveFolderAccess, excluding: Set<String>) async throws -> Item? {
        let preference = Self.pairingKey(parent: parent, projectID: project.id)
        guard let id = defaults.string(forKey: preference) else { return nil }
        guard Self.validID(id) else {
            defaults.removeObject(forKey: preference)
            return nil
        }
        let item: Item
        do {
            item = try await metadata(id: id)
        } catch GoogleDriveSharingError.http(let status) where status == 404 || status == 403 {
            defaults.removeObject(forKey: preference)
            return nil
        }
        let ownKey = "p-" + project.id.uuidString
        let itemKey = item.appProperties?["soniquillKey"]
        let keyAcceptable: Bool
        if let itemKey {
            keyAcceptable = itemKey == ownKey || (itemKey.hasPrefix("p-") && !excluding.contains(itemKey))
        } else {
            keyAcceptable = true
        }
        guard item.mimeType == Self.folderType, item.trashed != true, item.parents?.contains(parent) == true,
              keyAcceptable else {
            // A pairing that no longer fits (moved, trashed, re-keyed or claimed by another project) is dropped.
            defaults.removeObject(forKey: preference)
            return nil
        }
        // Still a valid pairing, but possibly not usable at this access level (e.g. read-only for an upload).
        return Self.allows(access, item) ? item : nil
    }

    static func pairingKey(parent: String, projectID: UUID) -> String {
        "drive.project.pairing.\(parent).\(projectID.uuidString)"
    }

    func savePairing(_ folderID: String, parent: String, projectID: UUID) {
        guard Self.validID(folderID) else { return }
        defaults.set(folderID, forKey: Self.pairingKey(parent: parent, projectID: projectID))
    }

    private static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func ensureProjectFolder(in parent: String, project: DriveProjectSnapshot,
                             excluding: Set<String> = []) async throws -> String {
        let key = "p-" + project.id.uuidString
        let name = project.name
        if let match = try await projectFolder(in: parent, project: project, access: .linkPublished,
                                               excluding: excluding) {
            if match.name != name, match.appProperties?["soniquillKey"] == key {
                var request = Self.request(Self.files.appendingPathComponent(match.id),
                                           items: [.init(name: "fields", value: Self.fields)])
                request.httpMethod = "PATCH"
                try request.setJSON(["name": name])
                let _: Item = try await send(request)
            }
            clearReservation(parent: parent, key: key)
            return match.id
        }
        let id = try await reserveID(parent: parent, key: key)
        if let created = try await createProjectFolder(id: id, name: name, parent: parent, key: key) {
            return created
        }
        clearReservation(parent: parent, key: key)
        let freshID = try await reserveID(parent: parent, key: key)
        guard let recovered = try await createProjectFolder(id: freshID, name: name, parent: parent, key: key) else {
            throw DriveProjectError.conflictingFiles
        }
        return recovered
    }

    private func createProjectFolder(id: String, name: String, parent: String, key: String) async throws -> String? {
        var request = Self.request(Self.files, items: [.init(name: "fields", value: Self.fields)])
        request.httpMethod = "POST"
        try request.setJSON(["id": id, "name": name, "mimeType": Self.folderType, "parents": [parent],
                             "appProperties": ["soniquillKey": key]])
        do {
            let folder: Item = try await send(request)
            guard folder.id == id, folder.mimeType == Self.folderType else {
                throw GoogleDriveSharingError.invalidResponse
            }
            return id
        } catch GoogleDriveSharingError.http(409) {
            if let item: Item = try? await get(Self.files.appendingPathComponent(id), fields: Self.fields),
               item.id == id,
               item.mimeType == Self.folderType,
               item.trashed != true,
               item.capabilities?.canAddChildren == true,
               item.parents?.contains(parent) ?? true {
                return id
            }
            let existing = try await children(in: parent, key: key)
            if existing.contains(where: { $0.id == id && $0.mimeType == Self.folderType }) {
                return id
            }
            return nil
        }
    }

    func detachDuplicateKey(id: String) async throws {
        guard Self.validID(id) else { throw GoogleDriveSharingError.invalidResponse }
        let digest = SHA256.hash(data: Data(id.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        var request = Self.request(Self.files.appendingPathComponent(id),
                                   items: [.init(name: "fields", value: Self.fields)])
        request.httpMethod = "PATCH"
        try request.setJSON(["appProperties": ["soniquillKey": "copy-" + digest]])
        let _: Item = try await send(request)
    }

    private func listFiles(query: String) async throws -> [Item] {
        struct Page: Decodable {
            let files: [Item]
            let nextPageToken: String?
        }
        var cursor: String?
        var seen: Set<String> = []
        var collected: [Item] = []
        repeat {
            var items = [URLQueryItem(name: "q", value: query), .init(name: "pageSize", value: "100"),
                         .init(name: "fields", value: "nextPageToken,files(\(Self.fields))")]
            if let cursor { items.append(.init(name: "pageToken", value: cursor)) }
            let page: Page = try await send(Self.request(Self.files, items: items))
            for file in page.files {
                guard Self.validID(file.id) else { throw GoogleDriveSharingError.invalidResponse }
                collected.append(file)
            }
            cursor = page.nextPageToken
            if let cursor, !seen.insert(cursor).inserted { throw GoogleDriveSharingError.invalidResponse }
        } while cursor != nil
        return collected
    }

    private static func canonicalFolder(from folders: [Item], preferredName: String) -> Item? {
        folders.sorted { lhs, rhs in
            let lhsMatches = lhs.name == preferredName
            let rhsMatches = rhs.name == preferredName
            if lhsMatches != rhsMatches { return lhsMatches }
            let lhsCreated = lhs.createdTime ?? ""
            let rhsCreated = rhs.createdTime ?? ""
            if lhsCreated != rhsCreated { return lhsCreated < rhsCreated }
            return lhs.id < rhs.id
        }.first
    }

    func saveReservation(_ id: String, parent: String, key: String) {
        guard Self.validID(id) else { return }
        defaults.set(id, forKey: "drive.project.fileID.\(parent).\(key)")
    }

    func clearReservation(parent: String, key: String) {
        defaults.removeObject(forKey: "drive.project.fileID.\(parent).\(key)")
    }

    func baseline(for id: String) -> DriveProjectSync.Version? {
        guard let data = defaults.data(forKey: "drive.project.baseline.\(id)") else { return nil }
        return try? JSONDecoder().decode(DriveProjectSync.Version.self, from: data)
    }

    func saveBaseline(_ version: DriveProjectSync.Version, for id: String, parent: String? = nil) {
        guard let data = try? JSONEncoder().encode(version) else { return }
        defaults.set(data, forKey: "drive.project.baseline.\(id)")
        guard let parent, Self.validID(parent) else { return }
        let indexKey = "drive.project.baselineIndex.\(parent)"
        var index = defaults.stringArray(forKey: indexKey) ?? []
        guard !index.contains(id) else { return }
        index.append(id)
        if index.count > Self.baselineIndexLimit { index.removeFirst(index.count - Self.baselineIndexLimit) }
        defaults.set(index, forKey: indexKey)
    }

    /// Drops baselines and ID reservations recorded for `parent` whose Drive items are no longer listed there.
    /// One paged listing of the folder; only entries tracked for this folder are touched.
    func pruneLocalState(parent: String) async throws {
        guard Self.validID(parent) else { return }
        let present = Set(try await listFiles(query: "'\(parent)' in parents and trashed = false").map(\.id))
        let indexKey = "drive.project.baselineIndex.\(parent)"
        if let index = defaults.stringArray(forKey: indexKey) {
            let kept = index.filter { present.contains($0) }
            for id in index where !present.contains(id) {
                defaults.removeObject(forKey: "drive.project.baseline.\(id)")
            }
            if kept.count != index.count {
                if kept.isEmpty { defaults.removeObject(forKey: indexKey) } else { defaults.set(kept, forKey: indexKey) }
            }
        }
        let prefix = "drive.project.fileID.\(parent)."
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(prefix) {
            guard let id = value as? String, !present.contains(id) else { continue }
            defaults.removeObject(forKey: key)
        }
    }

    func reserveID(parent: String, key: String) async throws -> String {
        struct IDs: Decodable { let ids: [String] }
        let preference = "drive.project.fileID.\(parent).\(key)"
        if let saved = defaults.string(forKey: preference), Self.validID(saved) { return saved }
        let url = Self.files.appendingPathComponent("generateIds")
        let result: IDs = try await send(Self.request(url, items: [
            .init(name: "count", value: "1"), .init(name: "space", value: "drive"), .init(name: "type", value: "files")
        ]))
        guard let id = result.ids.first, Self.validID(id) else { throw GoogleDriveSharingError.invalidResponse }
        defaults.set(id, forKey: preference)
        return id
    }

    private func get<T: Decodable>(_ url: URL, fields: String) async throws -> T {
        try await send(Self.request(url, items: [.init(name: "fields", value: fields)]))
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, _) = try await authorized(request)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func downloadPackage(_ item: Item, to target: URL) async throws {
        guard item.name.hasSuffix(".soniquill") else { throw GoogleDriveSharingError.invalidResponse }
        try await download(item, to: target, limit: 8 * 1_073_741_824 + 32 * 1_048_576 + 17)
    }

    func download(_ item: Item, to target: URL, limit: UInt64) async throws {
        guard Self.validID(item.id),
              let checksum = item.sha256Checksum,
              let size = item.size.flatMap(UInt64.init), size > 0,
              size <= limit else {
            throw GoogleDriveSharingError.invalidResponse
        }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: target.path), fm.createFile(atPath: target.path, contents: nil) else {
            throw RecordingPackageError.invalid
        }
        var completed = false
        defer { if !completed { try? fm.removeItem(at: target) } }
        let file = try FileHandle(forWritingTo: target)
        defer { try? file.close() }
        let chunk: UInt64 = 8 * 1_048_576
        for start in stride(from: 0, to: Int(size), by: Int(chunk)) {
            let first = UInt64(start)
            let last = min(first + chunk, size) - 1
            var request = Self.request(Self.files.appendingPathComponent(item.id), items: [.init(name: "alt", value: "media")])
            request.setValue("bytes=\(first)-\(last)", forHTTPHeaderField: "Range")
            let (data, response) = try await authorized(request)
            let rangeMatches = response.statusCode == 206 &&
                response.value(forHTTPHeaderField: "Content-Range") == "bytes \(first)-\(last)/\(size)"
            let completeResponse = response.statusCode == 200 && first == 0 && last + 1 == size
            guard (rangeMatches || completeResponse), UInt64(data.count) == last - first + 1 else {
                throw GoogleDriveSharingError.invalidResponse
            }
            try checkPrivacy()
            try file.write(contentsOf: data)
        }
        guard try SourceImportService.hash(target) == checksum else { throw DriveProjectError.remoteVersionChanged }
        completed = true
    }

    private func authorized(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        try checkPrivacy()
        let access = try await token(nil)
        try checkPrivacy()
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        var (data, response) = try await transport.send(request)
        if response.statusCode == 401 {
            try checkPrivacy()
            let renewed = try await token(access)
            try checkPrivacy()
            request.setValue("Bearer \(renewed)", forHTTPHeaderField: "Authorization")
            (data, response) = try await transport.send(request)
        }
        guard (200..<300).contains(response.statusCode) else { throw GoogleDriveSharingError.http(response.statusCode) }
        return (data, response)
    }

    private static func request(_ url: URL, items: [URLQueryItem]) -> URLRequest {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = items
        return URLRequest(url: components.url!)
    }
}

private extension URLRequest {
    mutating func setJSON(_ dictionary: [String: Any]) throws {
        setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        httpBody = try JSONSerialization.data(withJSONObject: dictionary)
    }
}
