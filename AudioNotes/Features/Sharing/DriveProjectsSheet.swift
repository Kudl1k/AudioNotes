import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct DriveProjectsSheet: View {
    let storage: LibraryStorage
    private let isEmbedded: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var context
    @Query(sort: \Project.name) private var projects: [Project]
    @AppStorage("ai.localOnly") private var localOnly = false
    @AppStorage("drive.project.selection") private var selectionData = Data()
    /// Per-project Drive destinations (see `DriveProjectLinks`).
    @AppStorage(DriveProjectLinks.key) private var linksData = Data()
    /// Default folder for projects that have no link yet.
    @AppStorage(DriveProjectLinks.sharingFolderKey) private var sharingFolderData = Data()
    /// Folder + project set the user already confirmed sharing for, so repeat syncs skip the privacy prompt.
    @AppStorage("drive.project.confirmedScope") private var confirmedScope = ""
    @State private var model = DriveProjectsModel()
    @State private var pendingShare: ShareConfirmation?
    @State private var showsConflictSheet = false
    @State private var confirmsDisconnect = false
    @State private var repeatWhileOpen = false
    /// Set when the app is backgrounded mid-sync: auto-sync stops once the running sync finishes.
    @State private var stopAutoSyncWhenIdle = false
    @State private var projectSelectionOverride: Set<UUID>?
    @State private var attemptedRecovery: DriveProjectFolder?

    private enum ShareAction {
        case once, automatic
    }

    private struct ShareConfirmation {
        let action: ShareAction
        let scope: String
    }

    private enum Phase: Equatable {
        case paused, checking, unavailable(String), needsFolder, needsReconnect, ready
    }

    private enum RowSync {
        case conflict, changes, synced(unfinished: Int), upToDate
    }

    init(storage: LibraryStorage, initialProject: UUID? = nil, isEmbedded: Bool = false) {
        self.storage = storage
        self.isEmbedded = isEmbedded
        _projectSelectionOverride = State(initialValue: initialProject.map { [$0] })
        // Idempotent; moves the single-link keys of earlier versions into the links map.
        DriveProjectLinks.migrateLegacy(in: .standard)
    }

    // MARK: - Derived state

    private var links: DriveProjectLinks { DriveProjectLinks(data: linksData) }

    private var selected: Set<UUID> {
        let stored = projectSelectionOverride ?? (try? JSONDecoder().decode(Set<UUID>.self, from: selectionData)) ?? []
        return stored.intersection(projects.map(\.id))
    }
    private var selectedProjects: [Project] { projects.filter { selected.contains($0.id) } }

    private var storedSharingFolder: DriveProjectFolder? {
        try? JSONDecoder().decode(DriveProjectFolder.self, from: sharingFolderData)
    }

    private var sharingFolder: DriveProjectFolder? {
        guard let folder = storedSharingFolder, folder.publishedProjectID == nil else { return nil }
        return folder
    }

    private func destination(for id: UUID) -> DriveProjectFolder? {
        links.destination(for: id, sharingFolder: sharingFolder)
    }

    private var groups: [DriveProjectLinks.Group] {
        links.groups(for: selectedProjects.map(\.id), sharingFolder: sharingFolder)
    }

    /// Selected projects that have nowhere to sync yet (no link and no sharing folder).
    private var unassigned: [Project] { selectedProjects.filter { destination(for: $0.id) == nil } }

    /// Every Drive folder this device syncs with.
    private var foldersInUse: [DriveProjectFolder] {
        var folders: [DriveProjectFolder] = sharingFolder.map { [$0] } ?? []
        for link in links.entries.values where !folders.contains(where: { $0.isSameFolder(as: link.folder) }) {
            folders.append(link.folder)
        }
        return folders
    }

    private var recoveryCandidate: DriveProjectFolder? {
        guard !localOnly, model.isDriveConnected, let folder = storedSharingFolder,
              folder.publishedProjectID != nil else { return nil }
        return folder
    }

    private var shareScope: String {
        groups.map { $0.folder.id + ":" + $0.projectIDs.map(\.uuidString).sorted().joined(separator: ",") }
            .sorted().joined(separator: "|")
    }
    private var isConfirmed: Bool { !groups.isEmpty && unassigned.isEmpty && confirmedScope == shareScope }
    private var allSelectedLinked: Bool {
        !selectedProjects.isEmpty && selectedProjects.allSatisfy { links[$0.id]?.role == .linked }
    }

    private var phase: Phase {
        if localOnly { return .paused }
        switch model.destinationAvailability {
        case nil: return .checking
        case .failure(let message): return .unavailable(message)
        case .available:
            if recoveryCandidate != nil && attemptedRecovery != recoveryCandidate { return .checking }
            if sharingFolder == nil && links.isEmpty { return .needsFolder }
            return model.isDriveConnected && !model.needsReconnect ? .ready : .needsReconnect
        }
    }

    private var canAct: Bool {
        phase == .ready && !selectedProjects.isEmpty && unassigned.isEmpty && !model.isBusy
    }

    private var showsAccountSection: Bool {
        model.destinationAvailability == .available
            && (model.isDriveConnected || storedSharingFolder != nil || !links.isEmpty)
    }

    // MARK: - Body

    var body: some View {
        Group {
            if isEmbedded {
                sharingForm
            } else {
                NavigationStack {
                    sharingForm
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { dismiss() }.disabled(model.isBusy)
                            }
                        }
                }
#if os(macOS)
                .frame(minWidth: 520, idealWidth: 540, minHeight: 540, idealHeight: 600)
#endif
            }
        }
        .interactiveDismissDisabled(model.isBusy)
        .onDisappear { model.cancel() }
        .onChange(of: projects.map(\.id)) { previous, current in
            let removed = Set(previous).subtracting(current)
            guard !removed.isEmpty else { return }
            if let stored = try? JSONDecoder().decode(Set<UUID>.self, from: selectionData) {
                selectionData = (try? JSONEncoder().encode(stored.subtracting(removed))) ?? Data()
            }
            projectSelectionOverride?.subtract(removed)
        }
        .onChange(of: selected) {
            guard !model.isBusy else { return }
            model.clearConflicts()
            showsConflictSheet = false
        }
        .onChange(of: shareScope) {
            repeatWhileOpen = false
            pendingShare = nil
        }
        .onChange(of: localOnly) { _, enabled in
            if enabled { repeatWhileOpen = false; showsConflictSheet = false; model.cancelCloud() }
        }
#if os(iOS)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background, repeatWhileOpen else { return }
            // A running sync keeps going under a background task assertion; stop the loop afterwards.
            if model.isBusy { stopAutoSyncWhenIdle = true } else { repeatWhileOpen = false }
        }
#endif
        .task { await model.checkDriveAvailability() }
        .task(id: recoveryCandidate) { await recoverSharingFolder() }
        .task(id: repeatWhileOpen) { await runAutoSync() }
        .sheet(isPresented: $showsConflictSheet) {
            DriveConflictResolutionSheet(
                conflicts: model.conflicts,
                onApply: { resolutions in
                    showsConflictSheet = false
                    Task { await sync(resolutions: resolutions) }
                }
            )
#if os(iOS)
            .presentationDetents([.fraction(0.68), .large])
            .presentationDragIndicator(.visible)
#endif
        }
        .confirmationDialog(confirmationTitle,
                            isPresented: Binding(get: { pendingShare != nil }, set: { if !$0 { pendingShare = nil } }),
                            titleVisibility: .visible, presenting: pendingShare) { confirmation in
            Button(confirmation.action == .automatic ? "Enable Auto-Sync" : primaryActionTitle) {
                perform(confirmation.action, scope: confirmation.scope)
            }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmationMessage(for: confirmation.action))
        }
        .confirmationDialog("Disconnect Google Drive?", isPresented: $confirmsDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { disconnect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Soniquill signs out of Google Drive and forgets the sharing folder, linked projects, and sync history on this device. Files already in Google Drive stay there.")
        }
        .alert("Google Drive", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var sharingForm: some View {
        Form {
            statusSection
            conflictSection
            projectsSection
            if phase == .ready && !projects.isEmpty { shareSection }
            if phase == .ready || phase == .needsFolder || phase == .needsReconnect { receiveSection }
            if showsAccountSection { accountSection }
        }
        .formStyle(.grouped)
        .navigationTitle(isEmbedded ? "Google Drive Sharing" : "Share Projects")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            HStack(alignment: .center, spacing: 14) {
                statusIcon
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle)
                        .font(.headline)
                        .lineLimit(2)
                    Text(statusSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
#if os(iOS)
                if phase == .ready { statusAccessory }
#else
                statusAccessory
#endif
            }
            .padding(.vertical, 6)
#if os(iOS)
            if phase == .needsFolder || phase == .needsReconnect {
                statusAccessory
                    .frame(maxWidth: .infinity)
            }
#endif

            if phase == .ready, let sharingFolder, model.unavailableFolderIDs.contains(sharingFolder.id) {
                HStack(spacing: 10) {
                    Label("Google Drive can’t open “\(sharingFolder.name)”. Choose it again to keep sharing.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Spacer(minLength: 8)
                    Button("Choose Folder…") { chooseFolder() }
                        .disabled(model.isBusy)
                }
            }

            if model.isBusy {
                HStack(spacing: 10) {
                    if let progress = model.progress {
                        ProgressView(value: progress).frame(maxWidth: 120)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(model.status ?? "Working…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Button("Cancel") { repeatWhileOpen = false; model.cancel() }
                        .controlSize(.small)
                }
            } else if let status = model.status {
                Label(status, systemImage: "clock.arrow.circlepath")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var statusIcon: some View {
        let badge: (symbol: String, tint: Color)? = switch phase {
        case .paused: ("lock.circle.fill", .gray)
        case .checking: nil
        case .unavailable: ("xmark.circle.fill", .gray)
        case .needsFolder: ("plus.circle.fill", .accentColor)
        case .needsReconnect: ("exclamationmark.circle.fill", .orange)
        case .ready: repeatWhileOpen
            ? ("arrow.triangle.2.circlepath.circle.fill", .accentColor)
            : ("checkmark.circle.fill", .green)
        }
        let isDimmed = switch phase {
        case .paused, .unavailable: true
        default: false
        }
        return ZStack(alignment: .bottomTrailing) {
            Image("GoogleDrive")
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
                .saturation(isDimmed ? 0 : 1)
                .opacity(isDimmed || phase == .checking ? 0.55 : 1)
                .frame(width: 44, height: 44)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.black.opacity(0.08)))
            if let badge {
                Image(systemName: badge.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, badge.tint)
                    .offset(x: 5, y: 5)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .accessibilityHidden(true)
    }

    private var statusTitle: String {
        switch phase {
        case .paused: "Drive sharing is paused"
        case .checking: "Checking Google Drive…"
        case .unavailable: "Google Drive isn’t available"
        case .needsFolder: "Share projects through Google Drive"
        case .needsReconnect: "Reconnect Google Drive"
        case .ready: sharingFolder?.name ?? "Google Drive"
        }
    }

    private var statusSubtitle: String {
        switch phase {
        case .paused:
            return "Local Only is on, so nothing leaves this device. Turn it off to share projects."
        case .checking:
            return "One moment."
        case .unavailable(let message):
            return message
        case .needsFolder:
            return "Choose a Drive folder. Each project you share gets its own subfolder, and anyone with access to the folder can open it."
        case .needsReconnect:
            return "Google Drive needs you to sign in again. Your folders and linked projects stay set up."
        case .ready:
            if repeatWhileOpen { return "Auto-sync is on." }
            if sharingFolder == nil {
                return "Linked projects sync with their own Drive folders. Choose a sharing folder to share other projects."
            }
            if links.entries.values.contains(where: { $0.role == .linked }) {
                return "Google Drive sharing folder. Linked projects sync with their own folders."
            }
            return "Google Drive folder. Shared files inherit its access settings."
        }
    }

    @ViewBuilder
    private var statusAccessory: some View {
        switch phase {
        case .needsFolder:
            Button { chooseFolder() } label: {
                Text("Choose Folder…")
#if os(iOS)
                    .frame(maxWidth: .infinity)
#endif
            }
                .buttonStyle(.borderedProminent)
#if os(iOS)
                .controlSize(.large)
#endif
                .disabled(model.isBusy)
        case .needsReconnect:
            Button { model.reconnect(checking: foldersInUse) } label: {
                Text("Reconnect…")
#if os(iOS)
                    .frame(maxWidth: .infinity)
#endif
            }
                .buttonStyle(.borderedProminent)
#if os(iOS)
                .controlSize(.large)
#endif
                .disabled(model.isBusy)
        case .ready:
            Menu {
                if let url = sharingFolder?.webURL {
                    Button("Open in Google Drive", systemImage: "arrow.up.right.square") { openURL(url) }
                }
                Button(sharingFolder == nil ? "Choose Sharing Folder…" : "Change Folder…", systemImage: "folder") {
                    chooseFolder()
                }
            } label: {
                Label("Folder Options", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
                    .font(.title3)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.isBusy || repeatWhileOpen)
        default:
            EmptyView()
        }
    }

    // MARK: - Conflicts

    @ViewBuilder
    private var conflictSection: some View {
        if !model.conflicts.isEmpty {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.conflicts.count == 1 ? "1 conflict needs attention"
                             : "\(model.conflicts.count) conflicts need attention")
                            .font(.headline)
                        Text(conflictNamesSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Button("Resolve…") { showsConflictSheet = true }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .fixedSize()
                        .disabled(model.isBusy || localOnly)
                }
                .padding(.vertical, 4)
            } footer: {
                Text("These files changed both here and in Google Drive. Nothing was overwritten. Both versions are kept until you decide.")
            }
        }
    }

    private var conflictNamesSummary: String {
        let names = model.conflicts.prefix(3).map(\.local.name).joined(separator: ", ")
        let remaining = model.conflicts.count - 3
        return remaining > 0 ? "\(names) and \(remaining) more" : names
    }

    // MARK: - Projects

    private var projectsSection: some View {
        Section {
            if projects.isEmpty {
                ContentUnavailableView("No Projects Yet", systemImage: "folder",
                                       description: Text("Create a project in the library, or import one someone shared with you."))
            } else if projects.count > 6 && isEmbedded {
                DisclosureGroup {
                    projectRows
                } label: {
                    LabeledContent("Projects", value: selectionSummary)
                }
#if os(macOS)
                .disclosureGroupStyle(FullWidthDisclosureStyle())
#endif
            } else if projects.count > 6 {
                NavigationLink {
                    Form { projectRows }
                        .formStyle(.grouped)
                        .navigationTitle("Projects")
                } label: {
                    LabeledContent("Projects", value: selectionSummary)
                }
                .disabled(model.isBusy || repeatWhileOpen)
                if !selectedProjects.isEmpty {
                    Text(selectedProjects.prefix(3).map(\.name).joined(separator: ", ") +
                         (selectedProjects.count > 3 ? " and \(selectedProjects.count - 3) more" : ""))
                        .foregroundStyle(.secondary)
                }
            } else {
                projectRows
            }
        } header: {
            HStack {
                Text("Projects")
                Spacer()
                if !projects.isEmpty && projects.count <= 6 {
                    Text(selectionSummary).foregroundStyle(.secondary).font(.caption)
                }
            }
        } footer: {
            if !projects.isEmpty {
                Text("Shares completed recordings with their transcripts and attachments, plus project documents and images. Summaries and chats stay on this device. Linked projects sync with their own Drive folders. Turning a project off stops future updates; copies already in Drive stay.")
            }
        }
    }

    private var selectionSummary: String {
        selectedProjects.isEmpty ? "None selected" : "\(selectedProjects.count) of \(projects.count) selected"
    }

    private var projectRows: some View {
        ForEach(projects) { project in
            projectRow(project)
        }
    }

    private func projectRow(_ project: Project) -> some View {
        let isSelected = selected.contains(project.id)
        let link = links[project.id]
        let isLinked = link?.role == .linked
        let rowSync = isSelected ? syncState(for: project) : nil
        return HStack(spacing: 10) {
            Button { toggle(project.id) } label: {
                HStack(spacing: 10) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .contentTransition(.symbolEffect(.replace))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(project.name).lineLimit(1)
                            if isLinked {
                                Image(systemName: "link")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .help("Linked to “\(link?.name ?? "")” in Google Drive")
                            }
                        }
                        Text(rowCaption(for: project, link: link, sync: rowSync))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy || repeatWhileOpen)
            .accessibilityLabel(project.name)
            .accessibilityValue(isSelected ? "Selected" : "Not selected")
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if let rowSync { syncBadge(rowSync) }

            if phase == .ready || phase == .needsFolder || phase == .needsReconnect {
                Menu {
                    projectMenuItems(project, link: link)
                } label: {
                    Label("Options for \(project.name)", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(model.isBusy || repeatWhileOpen)
            }
        }
        .contextMenu { projectMenuItems(project, link: link) }
    }

    private func syncBadge(_ state: RowSync) -> some View {
        let content: (title: String, symbol: String, tint: Color) = switch state {
        case .conflict: ("Needs review", "exclamationmark.triangle.fill", .orange)
        case .changes: ("Changes to share", "arrow.up.circle.fill", .orange)
        case .synced: ("Synced", "checkmark.circle", .secondary)
        case .upToDate: ("Up to date", "checkmark.circle.fill", .green)
        }
        return Label(content.title, systemImage: content.symbol)
            .font(.caption)
            .foregroundStyle(content.tint)
            .labelStyle(.titleAndIcon)
            .fixedSize()
    }

    private func rowCaption(for project: Project, link: DriveProjectLink?, sync: RowSync?) -> String {
        var parts = [contentSummary(for: project)]
        if let link, model.unavailableFolderIDs.contains(link.folderID) {
            parts.append("Drive folder can’t be opened")
        } else if let link, link.role == .shared, let sharingFolder, !link.folder.isSameFolder(as: sharingFolder) {
            parts.append("In “\(link.name)”")
        }
        if case .synced(let unfinished) = sync {
            parts.append(unfinished == 1 ? "1 recording not finished yet won’t be shared"
                         : "\(unfinished) recordings not finished yet won’t be shared")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func projectMenuItems(_ project: Project, link: DriveProjectLink?) -> some View {
        if let link {
            if let url = link.folder.webURL {
                Button("Open in Google Drive", systemImage: "arrow.up.right.square") { openURL(url) }
            }
            Button("Choose Drive Folder Again…", systemImage: "folder.badge.questionmark") { relink(project) }
                .disabled(model.destinationAvailability != .available || localOnly)
            if link.role == .linked {
                Divider()
                Button("Unlink Drive Project", systemImage: "xmark.circle") { unlink(project.id) }
            } else if let sharingFolder, !link.folder.isSameFolder(as: sharingFolder) {
                Divider()
                Button("Share to “\(sharingFolder.name)” Instead", systemImage: "folder") { unlink(project.id) }
            }
        } else {
            Button("Link to Existing Drive Project…", systemImage: "link") { linkExisting(project.id) }
                .disabled(model.destinationAvailability != .available || localOnly)
        }
    }

    private func contentSummary(for project: Project) -> String {
        let recordings = project.recordings.count
        let documents = project.sources.count
        var parts: [String] = []
        if recordings > 0 { parts.append(recordings == 1 ? "1 recording" : "\(recordings) recordings") }
        if documents > 0 { parts.append(documents == 1 ? "1 document" : "\(documents) documents") }
        return parts.isEmpty ? "Empty" : parts.joined(separator: " · ")
    }

    private func syncState(for project: Project) -> RowSync? {
        if model.conflictProjectIDs.contains(project.id) { return .conflict }
        guard let state = model.projectStates[project.id], let destination = destination(for: project.id),
              state.folder.isSameFolder(as: destination) else { return nil }
        if !state.isCurrent { return .changes }
        if state.unfinished > 0 { return .synced(unfinished: state.unfinished) }
        return .upToDate
    }

    // MARK: - Share

    private var shareSection: some View {
        Section {
            HStack {
                Button(primaryActionTitle) { requestShare(.once) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(isEmbedded ? nil : .defaultAction)
                    .disabled(!canAct || repeatWhileOpen)

                Spacer()

                if repeatWhileOpen {
                    Text("Auto-Sync On")
                        .accessibilityHint("Syncs every five minutes while this screen is open.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Menu {
                    if repeatWhileOpen {
                        Button("Turn Off Auto-Sync") { repeatWhileOpen = false }
                    } else {
                        Button("Turn On Auto-Sync") { requestShare(.automatic) }
                    }
                    Button("Check for Changes") { verify() }
                        .disabled(!canAct || repeatWhileOpen)
                } label: {
                    Label("Sync Options", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!canAct && !repeatWhileOpen)
            }
        } header: {
            Text("Sync")
        } footer: {
            if let hint = shareHint { Text(hint) }
        }
    }

    private var primaryActionTitle: String {
        isConfirmed || allSelectedLinked ? "Sync Now" : "Share"
    }

    private var shareHint: String? {
        if selectedProjects.isEmpty { return "Select at least one project to share." }
        if let first = unassigned.first {
            return unassigned.count == 1
                ? "Choose a sharing folder to share “\(first.name)”."
                : "Choose a sharing folder to share \(unassigned.count) selected projects."
        }
        if let checked = model.lastCheckedAt {
            return "Last checked \(checked.formatted(date: .omitted, time: .shortened))."
        }
        return nil
    }

    private var receiveSection: some View {
        Section {
            Button("Import Project from Drive…", systemImage: "square.and.arrow.down") {
                model.importDriveProject(storage: storage, container: context.container) { folder, id in
                    saveLink(folder, to: id)
                }
            }
            .disabled(model.isBusy || repeatWhileOpen)
        } header: {
            Text("Received a Project?")
        } footer: {
            Text("Pick a project folder someone shared with you in Google Drive. It’s added to your library as a new project and stays linked for future syncs.")
        }
    }

    private var accountSection: some View {
        Section {
            Button("Disconnect Google Drive…", role: .destructive) { confirmsDisconnect = true }
                .disabled(model.isBusy)
        } header: {
            Text("Google Drive Account")
        } footer: {
            Text("Signs out and forgets this device’s sharing folder, linked projects, and sync history. Files in Google Drive aren’t deleted.")
        }
    }

    private var confirmationTitle: String {
        let count = selectedProjects.count
        if count == 1 {
            let project = selectedProjects[0]
            if links[project.id]?.role == .linked { return "Sync “\(project.name)” with Google Drive?" }
            let target = destination(for: project.id).map { "“\($0.name)”" } ?? "Google Drive"
            return "Share “\(project.name)” to \(target)?"
        }
        if groups.count == 1 { return "Share \(count) projects to “\(groups[0].folder.name)”?" }
        return "Share \(count) projects to Google Drive?"
    }

    private func confirmationMessage(for action: ShareAction) -> String {
        var text = groups.count > 1
            ? "Anyone with access to these Drive folders (\(groups.map(\.folder.name).joined(separator: ", "))) will be able to open the recordings, transcripts, attachments, and documents in "
            : "Anyone with access to this Drive folder will be able to open the recordings, transcripts, attachments, and documents in "
        text += selectedProjects.count == 1 ? "this project." : "\(selectedProjects.map(\.name).joined(separator: ", "))."
        if action == .automatic { text += " Auto-Sync runs every five minutes while this screen is open and shares new content you add." }
        return text
    }

    // MARK: - Actions

    private func setSelection(_ ids: Set<UUID>) {
        if projectSelectionOverride != nil { projectSelectionOverride = ids }
        else { selectionData = (try? JSONEncoder().encode(ids)) ?? Data() }
    }

    private func toggle(_ id: UUID) {
        var ids = selected
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        setSelection(ids)
    }

    private func updateLinks(_ change: (inout DriveProjectLinks) -> Void) {
        var updated = links
        change(&updated)
        guard updated != links else { return }
        linksData = updated.isEmpty ? Data() : updated.data
    }

    private func recoverSharingFolder() async {
        guard let candidate = recoveryCandidate, attemptedRecovery != candidate else { return }
        let folder = try? await model.recoverSharingFolder(from: candidate)
        guard !Task.isCancelled, recoveryCandidate == candidate else { return }
        attemptedRecovery = candidate
        if let folder { saveSharingFolder(folder) }
    }

    private func saveSharingFolder(_ folder: DriveProjectFolder) {
        guard let data = try? JSONEncoder().encode(folder) else { return }
        sharingFolderData = data
    }

    private func chooseFolder() {
        model.chooseDestination(access: .publish) { folder in
            guard folder.publishedProjectID == nil else {
                model.error = "Choose a sharing folder outside the published project folder."
                return
            }
            saveSharingFolder(folder)
        }
    }

    /// Re-picks a project's existing Drive folder, e.g. after access was lost.
    private func relink(_ project: Project) {
        guard let link = links[project.id] else { return }
        let id = project.id
        model.chooseDestination(access: link.role == .linked ? .linkPublished : .publish) { folder in
            guard folder.isSameFolder(as: link.folder) else {
                model.error = "Choose “\(link.name)” to reconnect “\(project.name)”."
                return
            }
            updateLinks { $0.set(folder, role: link.role, for: id) }
        }
    }

    private func linkExisting(_ id: UUID) {
        model.chooseDestination(access: .linkPublished, requirePublishedProject: true) { folder in
            guard projects.contains(where: { $0.id == id }) else { return }
            if let other = links.project(linkedTo: folder), other != id {
                let name = projects.first { $0.id == other }?.name ?? "another project"
                model.error = "“\(folder.name)” is already linked to “\(name)”."
                return
            }
            saveLink(folder, to: id)
        }
    }

    private func unlink(_ id: UUID) {
        updateLinks { $0.remove(id) }
        model.status = nil
    }

    private func saveLink(_ folder: DriveProjectFolder, to id: UUID) {
        updateLinks { $0.set(folder, role: .linked, for: id) }
        setSelection(selected.union([id]))
    }

    /// Persists Drive's current folder name and pins newly shared projects to the folder they were shared into.
    private func recordSynced(_ folder: DriveProjectFolder, projectIDs: [UUID]) {
        updateLinks { links in
            links.refresh(folder)
            if folder.publishedProjectID == nil {
                for id in projectIDs where links[id] == nil { links.set(folder, role: .shared, for: id) }
            }
        }
        if let stored = storedSharingFolder, stored.isSameFolder(as: folder), stored.name != folder.name {
            saveSharingFolder(folder)
        }
        model.markAvailable(folder)
    }

    private func disconnect() {
        repeatWhileOpen = false
        pendingShare = nil
        showsConflictSheet = false
        Task {
            await model.disconnect {
                // `GoogleDriveConnection.disconnect()` cleared the stored Drive settings; drop in-memory copies too.
                projectSelectionOverride = nil
                attemptedRecovery = nil
            }
        }
    }

    private func requestShare(_ action: ShareAction) {
        guard canAct else { return }
        if isConfirmed { perform(action, scope: shareScope) }
        else { pendingShare = ShareConfirmation(action: action, scope: shareScope) }
    }

    private func perform(_ action: ShareAction, scope: String) {
        guard canAct, scope == shareScope else { return }
        confirmedScope = scope
        switch action {
        case .once: Task { await sync() }
        case .automatic: repeatWhileOpen = true
        }
    }

    private func saveContext() -> Bool {
        do {
            if context.hasChanges { try context.save() }
            return true
        } catch {
            model.error = error.localizedDescription
            return false
        }
    }

    private func verify() {
        guard canAct else { return }
        let groups = groups
        guard saveContext() else { return }
        Task {
            await model.verify(groups, storage: storage, container: context.container) { folder in
                recordSynced(folder, projectIDs: [])
            }
        }
    }

    private func runAutoSync() async {
        guard repeatWhileOpen else { return }
        while !Task.isCancelled {
            guard phase == .ready, isConfirmed else {
                repeatWhileOpen = false
                return
            }
            // Never start a tick while the user is resolving conflicts or other Drive work is running.
            if !showsConflictSheet && !model.isBusy { await sync(trigger: .automatic) }
            guard !Task.isCancelled else { return }
            if stopAutoSyncWhenIdle || model.stopsAutoSync {
                stopAutoSyncWhenIdle = false
                repeatWhileOpen = false
                return
            }
            do { try await Task.sleep(for: .seconds(300)) }
            catch { return }
        }
    }

    private func sync(resolutions: [DriveProjectSync.Resolution] = [],
                      trigger: DriveProjectsModel.SyncTrigger = .manual) async {
        guard phase == .ready, isConfirmed, !model.isBusy, !Task.isCancelled else { return }
        let groups = groups
        guard saveContext() else { return }
        await model.sync(groups, storage: storage, container: context.container,
                         resolutions: resolutions, trigger: trigger) { folder, ids in
            recordSynced(folder, projectIDs: ids)
        }
        // Periodic syncs only report conflicts inline; the review sheet opens for manual syncs.
        if trigger == .manual, !Task.isCancelled, resolutions.isEmpty, !model.conflicts.isEmpty, model.error == nil {
            showsConflictSheet = true
        }
    }
}
