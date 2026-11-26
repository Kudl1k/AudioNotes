import Foundation

/// Where one local project syncs in Google Drive.
struct DriveProjectLink: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable {
        /// Shared by this device into a sharing folder (`publishedProjectID == nil`).
        case shared
        /// Linked to a published project folder, usually one someone shared with this user.
        case linked
    }

    var folderID: String
    var name: String
    var publishedProjectID: UUID?
    var role: Role

    init(folder: DriveProjectFolder, role: Role) {
        folderID = folder.id
        name = folder.name
        publishedProjectID = folder.publishedProjectID
        self.role = role
    }

    var folder: DriveProjectFolder { .init(id: folderID, name: name, publishedProjectID: publishedProjectID) }
}

/// Device-local map of project → Drive destination, persisted as JSON under `drive.project.links`.
/// Non-secret; `DriveSharingLocalState.reset()` forgets it on disconnect.
struct DriveProjectLinks: Equatable, Sendable {
    static let key = "drive.project.links"
    /// The default folder that projects without a link are shared into.
    static let sharingFolderKey = "drive.project.sharingFolder"

    enum Legacy {
        static let linkedLocalID = "drive.project.linkedLocalID"
        static let destination = "drive.project.destination"
        static let sharingDestination = "drive.project.sharingDestination"
    }

    /// Projects that sync to the same Drive folder in one run.
    struct Group: Equatable, Sendable {
        let folder: DriveProjectFolder
        var projectIDs: [UUID]
    }

    private(set) var entries: [UUID: DriveProjectLink] = [:]

    init(entries: [UUID: DriveProjectLink] = [:]) { self.entries = entries }

    init(data: Data) {
        guard !data.isEmpty,
              let decoded = try? JSONDecoder().decode([String: DriveProjectLink].self, from: data) else { return }
        for (key, link) in decoded {
            if let id = UUID(uuidString: key) { entries[id] = link }
        }
    }

    var data: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let raw = Dictionary(uniqueKeysWithValues: entries.map { ($0.key.uuidString, $0.value) })
        return (try? encoder.encode(raw)) ?? Data()
    }

    var isEmpty: Bool { entries.isEmpty }

    subscript(projectID: UUID) -> DriveProjectLink? { entries[projectID] }

    /// The local project already linked to `folder`, if any.
    func project(linkedTo folder: DriveProjectFolder) -> UUID? {
        entries.first { $0.value.role == .linked && $0.value.folder.isSameFolder(as: folder) }?.key
    }

    mutating func set(_ folder: DriveProjectFolder, role: DriveProjectLink.Role, for projectID: UUID) {
        entries[projectID] = .init(folder: folder, role: role)
    }

    mutating func remove(_ projectID: UUID) { entries[projectID] = nil }

    /// Drops links of projects that no longer exist locally.
    mutating func prune(keeping projectIDs: Set<UUID>) {
        entries = entries.filter { projectIDs.contains($0.key) }
    }

    /// Stores a folder's current Drive name in every link to it (Drive folders can be renamed).
    mutating func refresh(_ folder: DriveProjectFolder) {
        for (id, link) in entries where link.folder.isSameFolder(as: folder) && link.name != folder.name {
            entries[id]?.name = folder.name
        }
    }

    /// The folder `projectID` syncs with: its own link, otherwise the default sharing folder.
    func destination(for projectID: UUID, sharingFolder: DriveProjectFolder?) -> DriveProjectFolder? {
        if let link = entries[projectID] { return link.folder }
        guard let sharingFolder, sharingFolder.publishedProjectID == nil else { return nil }
        return sharingFolder
    }

    /// Groups `projectIDs` by destination, keeping the given order. Projects without a destination are omitted.
    func groups(for projectIDs: [UUID], sharingFolder: DriveProjectFolder?) -> [Group] {
        var groups: [Group] = []
        for id in projectIDs {
            guard let folder = destination(for: id, sharingFolder: sharingFolder) else { continue }
            if let index = groups.firstIndex(where: { $0.folder.isSameFolder(as: folder) }) {
                groups[index].projectIDs.append(id)
            } else {
                groups.append(.init(folder: folder, projectIDs: [id]))
            }
        }
        return groups
    }

    // MARK: Persistence

    static func load(from defaults: UserDefaults = .standard) -> Self {
        migrateLegacy(in: defaults)
        return Self(data: defaults.data(forKey: key) ?? Data())
    }

    func save(to defaults: UserDefaults = .standard) {
        if entries.isEmpty { defaults.removeObject(forKey: Self.key) }
        else { defaults.set(data, forKey: Self.key) }
    }

    /// Removes a deleted project's link.
    static func remove(projectID: UUID, from defaults: UserDefaults = .standard) {
        var links = load(from: defaults)
        guard links[projectID] != nil else { return }
        links.remove(projectID)
        links.save(to: defaults)
    }

    /// One-time move from the single-link keys (`linkedLocalID`, `destination`, `sharingDestination`)
    /// to the links map and `sharingFolderKey`. Removes the legacy keys it consumed. Idempotent.
    static func migrateLegacy(in defaults: UserDefaults) {
        let legacyKeys = [Legacy.linkedLocalID, Legacy.destination, Legacy.sharingDestination]
        guard legacyKeys.contains(where: { defaults.object(forKey: $0) != nil }) else { return }
        func folder(_ key: String) -> DriveProjectFolder? {
            defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(DriveProjectFolder.self, from: $0) }
        }
        var links = Self(data: defaults.data(forKey: key) ?? Data())
        let destination = folder(Legacy.destination)
        let sharing: DriveProjectFolder?
        if let linkedID = defaults.string(forKey: Legacy.linkedLocalID).flatMap(UUID.init(uuidString:)) {
            if let destination, destination.publishedProjectID != nil, links[linkedID] == nil {
                links.set(destination, role: .linked, for: linkedID)
            }
            sharing = folder(Legacy.sharingDestination)
        } else {
            // Without a link the destination was the sharing folder (or a published folder awaiting recovery).
            sharing = destination
        }
        if let sharing, defaults.object(forKey: sharingFolderKey) == nil,
           let data = try? JSONEncoder().encode(sharing) {
            defaults.set(data, forKey: sharingFolderKey)
        }
        links.save(to: defaults)
        for key in legacyKeys { defaults.removeObject(forKey: key) }
    }
}
