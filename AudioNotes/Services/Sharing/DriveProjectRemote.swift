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
}

struct DriveProjectRemote: Sendable {
    static let folderType = "application/vnd.google-apps.folder"
    private static let files = URL(string: "https://www.googleapis.com/drive/v3/files")!
    private static let fields = "id,name,mimeType,size,sha256Checksum,createdTime,modifiedTime,trashed,parents,driveId,ownedByMe,appProperties,capabilities(canAddChildren)"
    let transport: DriveHTTPTransport
    let checkPrivacy: @Sendable () throws -> Void
    let token: GoogleDriveUpload.Token

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

    func validateFolder(id: String) async throws -> DriveProjectFolder {
        guard Self.validID(id) else { throw GoogleDriveSharingError.invalidResponse }
        let item: Item = try await get(Self.files.appendingPathComponent(id), fields: Self.fields)
        guard item.id == id, item.mimeType == Self.folderType, item.trashed != true,
              item.driveId == nil, item.ownedByMe == true, item.capabilities?.canAddChildren == true else {
            throw DriveProjectError.folderUnavailable
        }
        let key = item.appProperties?["soniquillKey"]
        let projectID = key.flatMap { $0.hasPrefix("p-") ? UUID(uuidString: String($0.dropFirst(2))) : nil }
        return .init(id: item.id, name: item.name, publishedProjectID: projectID)
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

    func projectFolder(in parent: String, project: DriveProjectSnapshot) async throws -> Item? {
        let direct = try await children(in: parent, key: "p-" + project.id.uuidString)
            .filter { $0.mimeType == Self.folderType && $0.capabilities?.canAddChildren == true }
        if let canonical = Self.canonicalFolder(from: direct, preferredName: project.name) {
            return canonical
        }
        guard !project.recordings.isEmpty else { return nil }
        let folderQuery = "'\(parent)' in parents and trashed = false and mimeType = '\(Self.folderType)'"
        let allSubfolders = try await listFiles(query: folderQuery).filter {
            $0.mimeType == Self.folderType &&
            $0.ownedByMe == true &&
            $0.driveId == nil &&
            $0.capabilities?.canAddChildren == true &&
            ($0.appProperties?["soniquillKey"]?.hasPrefix("p-") == true)
        }
        guard !allSubfolders.isEmpty else { return nil }
        let normalizedTarget = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sameName = allSubfolders.filter {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare(normalizedTarget) == .orderedSame
        }
        let otherSubfolders = allSubfolders.filter { folder in !sameName.contains(where: { $0.id == folder.id }) }
        for pool in [sameName, otherSubfolders] where !pool.isEmpty {
            var matched: [Item] = []
            for candidate in pool.prefix(20) {
                for recording in project.recordings {
                    let items = try await children(in: candidate.id, key: "r-" + recording.recordingID.uuidString)
                    if items.contains(where: { $0.mimeType != Self.folderType }) {
                        matched.append(candidate)
                        break
                    }
                }
            }
            if matched.count == 1 { return matched[0] }
        }
        return nil
    }

    func ensureProjectFolder(in parent: String, project: DriveProjectSnapshot) async throws -> String {
        let key = "p-" + project.id.uuidString
        let name = project.name
        if let match = try await projectFolder(in: parent, project: project) {
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
        UserDefaults.standard.set(id, forKey: "drive.project.fileID.\(parent).\(key)")
    }

    func clearReservation(parent: String, key: String) {
        UserDefaults.standard.removeObject(forKey: "drive.project.fileID.\(parent).\(key)")
    }

    func baseline(for id: String) -> DriveProjectSync.Version? {
        guard let data = UserDefaults.standard.data(forKey: "drive.project.baseline.\(id)") else { return nil }
        return try? JSONDecoder().decode(DriveProjectSync.Version.self, from: data)
    }

    func saveBaseline(_ version: DriveProjectSync.Version, for id: String) {
        guard let data = try? JSONEncoder().encode(version) else { return }
        UserDefaults.standard.set(data, forKey: "drive.project.baseline.\(id)")
    }

    func reserveID(parent: String, key: String) async throws -> String {
        struct IDs: Decodable { let ids: [String] }
        let preference = "drive.project.fileID.\(parent).\(key)"
        if let saved = UserDefaults.standard.string(forKey: preference), Self.validID(saved) { return saved }
        let url = Self.files.appendingPathComponent("generateIds")
        let result: IDs = try await send(Self.request(url, items: [
            .init(name: "count", value: "1"), .init(name: "space", value: "drive"), .init(name: "type", value: "files")
        ]))
        guard let id = result.ids.first, Self.validID(id) else { throw GoogleDriveSharingError.invalidResponse }
        UserDefaults.standard.set(id, forKey: preference)
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
