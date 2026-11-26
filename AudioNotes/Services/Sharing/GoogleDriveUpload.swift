import Foundation

actor GoogleDriveUpload {
    typealias Token = @Sendable (_ rejected: String?) async throws -> String
    typealias Progress = @Sendable (_ confirmed: UInt64, _ total: UInt64) async -> Void

    private static let api = URL(string: "https://www.googleapis.com/drive/v3")!
    private static let upload = URL(string: "https://www.googleapis.com/upload/drive/v3/files")!
    private static let fields = "id,size,sha256Checksum,trashed,parents,webViewLink"
    private static let mime = "application/octet-stream"
    private static let chunkSize = 8 * 1_048_576

    private let file: URL
    private let name: String
    struct Target: Sendable {
        let id: String?
        let reservedID: String?
        let parent: String
        let key: String
        let mime: String
    }

    private let target: Target?
    private let transport: DriveHTTPTransport
    private let checkPrivacy: @Sendable () throws -> Void
    private let token: Token
    private var fileID: String?
    var currentFileID: String? { fileID }
    private var sessionURL: URL?
    private var total: UInt64?
    private var checksum: String?
    private var running = false

    init(file: URL, name: String, target: Target? = nil, transport: DriveHTTPTransport = .live,
         checkPrivacy: @escaping @Sendable () throws -> Void = DriveSharingPrivacy.check,
         token: @escaping Token) {
        self.file = file
        self.name = name
        self.target = target
        self.fileID = target?.id ?? target?.reservedID
        self.transport = transport
        self.checkPrivacy = checkPrivacy
        self.token = token
    }

    func run(progress: Progress) async throws -> URL {
        guard !running else { throw GoogleDriveSharingError.busy }
        running = true
        defer { running = false }
        try checkPrivacy()
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.uint64Value > 0 else {
            throw GoogleDriveSharingError.changedFile
        }
        let length = size.uint64Value
        let hash = try SourceImportService.hash(file)
        guard total == nil || (total == length && checksum == hash) else { throw GoogleDriveSharingError.changedFile }
        total = length
        checksum = hash

        if let target {
            guard DriveProjectRemote.validID(target.parent), DriveProjectRemote.validID(target.key),
                  fileID.map(DriveProjectRemote.validID) ?? true else {
                throw GoogleDriveSharingError.invalidResponse
            }
        }
        if fileID == nil { fileID = try await generateID() }
        guard var id = fileID else { throw GoogleDriveSharingError.invalidResponse }

        var offset: UInt64 = 0
        if let sessionURL {
            var probe = URLRequest(url: sessionURL)
            probe.httpMethod = "PUT"
            probe.setValue("bytes */\(length)", forHTTPHeaderField: "Content-Range")
            probe.setValue("0", forHTTPHeaderField: "Content-Length")
            let (data, response) = try await send(probe)
            switch response.statusCode {
            case 200, 201:
                let link = try completed(data, id: id, length: length, checksum: hash)
                await progress(length, length)
                return link
            case 308:
                offset = try confirmed(response, length: length)
            case 404, 410:
                self.sessionURL = nil
            default: throw GoogleDriveSharingError.http(response.statusCode)
            }
        }
        if sessionURL == nil {
            var (_, response) = try await start(id: id, length: length)
            if response.statusCode == 409, target?.id == nil {
                if let link = try? await existing(id: id, length: length, checksum: hash) {
                    await progress(length, length)
                    return link
                }
                let freshID = try await generateID()
                self.fileID = freshID
                id = freshID
                (_, response) = try await start(id: id, length: length)
            } else if response.statusCode == 409 {
                let link = try await existing(id: id, length: length, checksum: hash)
                await progress(length, length)
                return link
            }
            guard response.statusCode == 200 || response.statusCode == 201 else {
                throw GoogleDriveSharingError.http(response.statusCode)
            }
            guard let location = response.value(forHTTPHeaderField: "Location"),
                  let url = URL(string: location), Self.isSessionURL(url, expectedPath: "/upload/drive/v3/files/\(id)") else {
                throw GoogleDriveSharingError.invalidResponse
            }
            sessionURL = url
        }
        guard let sessionURL else { throw GoogleDriveSharingError.invalidResponse }

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        await progress(offset, length)
        while offset < length {
            try checkPrivacy()
            try handle.seek(toOffset: offset)
            let count = Int(min(UInt64(Self.chunkSize), length - offset))
            guard let data = try handle.read(upToCount: count), data.count == count else {
                throw GoogleDriveSharingError.changedFile
            }
            let end = offset + UInt64(count) - 1
            var request = URLRequest(url: sessionURL)
            request.httpMethod = "PUT"
            request.setValue("bytes \(offset)-\(end)/\(length)", forHTTPHeaderField: "Content-Range")
            request.setValue(target?.mime ?? Self.mime, forHTTPHeaderField: "Content-Type")
            request.httpBody = data
            let (body, response) = try await send(request)
            switch response.statusCode {
            case 200, 201:
                let link = try completed(body, id: id, length: length, checksum: hash)
                await progress(length, length)
                return link
            case 308:
                let next = try confirmed(response, length: length)
                guard next > offset, next <= end + 1 else { throw GoogleDriveSharingError.invalidResponse }
                offset = next
                await progress(offset, length)
            case 404, 410:
                self.sessionURL = nil
                throw GoogleDriveSharingError.http(response.statusCode)
            default: throw GoogleDriveSharingError.http(response.statusCode)
            }
        }
        throw GoogleDriveSharingError.invalidResponse
    }

    private func generateID() async throws -> String {
        struct IDs: Decodable { let ids: [String] }
        let url = Self.url(Self.api.appendingPathComponent("files/generateIds"),
                           items: ["count": "1", "space": "drive", "type": "files"])
        let (data, response) = try await send(URLRequest(url: url))
        guard response.statusCode == 200 else { throw GoogleDriveSharingError.http(response.statusCode) }
        guard let id = try JSONDecoder().decode(IDs.self, from: data).ids.first,
              !id.isEmpty, id.utf8.count <= 256,
              id.utf8.allSatisfy({ $0 == 45 || (48...57).contains($0) ||
                  (65...90).contains($0) || $0 == 95 || (97...122).contains($0) }) else {
            throw GoogleDriveSharingError.invalidResponse
        }
        return id
    }

    private func start(id: String, length: UInt64) async throws -> (Data, HTTPURLResponse) {
        let update = target?.id != nil
        let endpoint = update ? Self.upload.appendingPathComponent(id) : Self.upload
        var request = URLRequest(url: Self.url(endpoint, items: ["uploadType": "resumable", "fields": Self.fields]))
        request.httpMethod = update ? "PATCH" : "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(target?.mime ?? Self.mime, forHTTPHeaderField: "X-Upload-Content-Type")
        request.setValue(String(length), forHTTPHeaderField: "X-Upload-Content-Length")
        var metadata: [String: Any] = ["name": name, "mimeType": target?.mime ?? Self.mime]
        if !update {
            metadata["id"] = id
            if let target {
                metadata["parents"] = [target.parent]
                metadata["appProperties"] = ["soniquillKey": target.key]
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: metadata)
        return try await send(request)
    }

    private func existing(id: String, length: UInt64, checksum: String) async throws -> URL {
        let url = Self.url(Self.api.appendingPathComponent("files").appendingPathComponent(id),
                           items: ["fields": Self.fields])
        let (body, response) = try await send(URLRequest(url: url))
        guard response.statusCode == 200 else { throw GoogleDriveSharingError.http(response.statusCode) }
        return try completed(body, id: id, length: length, checksum: checksum)
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        try checkPrivacy()
        let access = try await token(nil)
        try checkPrivacy()
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        let result = try await transport.send(request)
        guard result.1.statusCode == 401 else { return result }
        try checkPrivacy()
        let refreshed = try await token(access)
        try checkPrivacy()
        request.setValue("Bearer \(refreshed)", forHTTPHeaderField: "Authorization")
        return try await transport.send(request)
    }

    private func confirmed(_ response: HTTPURLResponse, length: UInt64) throws -> UInt64 {
        guard let range = response.value(forHTTPHeaderField: "Range") else { return 0 }
        guard range.hasPrefix("bytes=0-"), let end = UInt64(range.dropFirst(8)), end < length - 1 else {
            throw GoogleDriveSharingError.invalidResponse
        }
        return end + 1
    }

    private func completed(_ body: Data, id: String, length: UInt64, checksum: String) throws -> URL {
        struct Result: Decodable {
            let id: String
            let size: String
            let sha256Checksum: String?
            let trashed: Bool?
            let parents: [String]?
            let webViewLink: URL?
        }
        let result = try JSONDecoder().decode(Result.self, from: body)
        guard result.id == id, UInt64(result.size) == length, result.sha256Checksum == checksum,
              result.trashed != true else {
            throw GoogleDriveSharingError.invalidResponse
        }
        if let expectedParent = target?.parent, target?.id == nil, let parents = result.parents {
            guard parents.contains(expectedParent) else { throw GoogleDriveSharingError.invalidResponse }
        }
        if let url = result.webViewLink, url.scheme == "https", url.host == "drive.google.com",
           url.user == nil, url.password == nil, url.port == nil {
            return url
        }
        return URL(string: "https://drive.google.com/open?id=\(id)")!
    }

    private static func isSessionURL(_ url: URL, expectedPath: String) -> Bool {
        url.scheme == "https" && url.host == "www.googleapis.com" && url.user == nil &&
            url.password == nil && url.port == nil && (url.path == "/upload/drive/v3/files" || url.path == expectedPath)
    }

    private static func url(_ base: URL, items: [String: String]) -> URL {
        var value = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        value.queryItems = items.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
        return value.url!
    }
}
