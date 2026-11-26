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
    @AppStorage("drive.project.destination") private var destinationData = Data()
    // Keep the general sharing folder available while the existing destination holds a project link.
    @AppStorage("drive.project.sharingDestination") private var sharingDestinationData = Data()
    @AppStorage("drive.project.linkedLocalID") private var linkedLocalID = ""
    /// Folder + project set the user already confirmed sharing for, so repeat syncs skip the privacy prompt.
    @AppStorage("drive.project.confirmedScope") private var confirmedScope = ""
    @State private var model = DriveProjectsModel()
    @State private var pendingShare: ShareConfirmation?
    @State private var showsConflictSheet = false
    @State private var repeatWhileOpen = false
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

    init(storage: LibraryStorage, initialProject: UUID? = nil, isEmbedded: Bool = false) {
        self.storage = storage
        self.isEmbedded = isEmbedded
        _projectSelectionOverride = State(initialValue: initialProject.map { [$0] })
    }

    private var selected: Set<UUID> {
        let stored = projectSelectionOverride ?? (try? JSONDecoder().decode(Set<UUID>.self, from: selectionData)) ?? []
        var available = stored.intersection(projects.map(\.id))
        // A linked copy can have a different Drive identity from the local project.
        if available.count > 1, let linkedProject { available.remove(linkedProject.id) }
        return available
    }
    private var selectedProjects: [Project] { projects.filter { selected.contains($0.id) } }
    private var linkedProject: Project? { projects.first { $0.id.uuidString == linkedLocalID } }
    private var usesLinkedDestination: Bool {
        guard let linkedProject else { return false }
        return selected == [linkedProject.id]
    }

    private var savedDestination: DriveProjectFolder? {
        try? JSONDecoder().decode(DriveProjectFolder.self, from: destinationData)
    }

    private var recoveryCandidate: DriveProjectFolder? {
        guard !localOnly, model.isDriveConnected, !usesLinkedDestination, !selected.isEmpty,
              destination == nil, let folder = savedDestination, folder.publishedProjectID != nil else { return nil }
        return folder
    }

    private var destination: DriveProjectFolder? {
        let data = usesLinkedDestination || linkedLocalID.isEmpty ? destinationData : sharingDestinationData
        guard let folder = try? JSONDecoder().decode(DriveProjectFolder.self, from: data),
              usesLinkedDestination || folder.publishedProjectID == nil else { return nil }
        return folder
    }
    private var shareScope: String {
        (destination?.id ?? "") + "|" + selected.map(\.uuidString).sorted().joined(separator: ",")
    }
    private var isConfirmed: Bool { destination != nil && confirmedScope == shareScope }

    private var phase: Phase {
        if localOnly { return .paused }
        switch model.destinationAvailability {
        case nil: return .checking
        case .failure(let message): return .unavailable(message)
        case .available:
            if recoveryCandidate != nil && attemptedRecovery != recoveryCandidate { return .checking }
            if destination == nil { return .needsFolder }
            return model.isDriveConnected ? .ready : .needsReconnect
        }
    }

    private var canAct: Bool {
        phase == .ready && !selectedProjects.isEmpty && !model.isBusy
    }

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
            model.verification = nil
            model.conflicts = []
            showsConflictSheet = false
        }
        .onChange(of: destination) { model.verification = nil; model.conflicts = []; showsConflictSheet = false }
        .onChange(of: shareScope) {
            repeatWhileOpen = false
            pendingShare = nil
        }
        .onChange(of: localOnly) { _, enabled in
            if enabled { repeatWhileOpen = false; showsConflictSheet = false; model.cancelCloud() }
        }
#if os(iOS)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { repeatWhileOpen = false }
        }
#endif
        .task { await model.checkDriveAvailability() }
        .task(id: recoveryCandidate) { await recoverSharingFolder() }
        .task(id: repeatWhileOpen) {
            guard repeatWhileOpen else { return }
            while !Task.isCancelled {
                guard phase == .ready, isConfirmed else {
                    repeatWhileOpen = false
                    return
                }
                await sync()
                guard !Task.isCancelled else { return }
                if model.error != nil || !model.conflicts.isEmpty { repeatWhileOpen = false; return }
                do { try await Task.sleep(for: .seconds(300)) }
                catch { return }
            }
        }
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
        case .ready: destination?.name ?? "Google Drive"
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
            return "Sign in again to keep sharing to “\(destination?.name ?? "your folder")”."
        case .ready:
            if repeatWhileOpen { return "Auto-sync is on." }
            if usesLinkedDestination, let linkedProject { return "Linked Drive project for “\(linkedProject.name)”. Files inherit the folder’s access." }
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
            Button { chooseFolder() } label: {
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
                if let url = destination?.webURL {
                    Button("Open in Google Drive", systemImage: "arrow.up.right.square") { openURL(url) }
                }
                if usesLinkedDestination {
                    Divider()
                    Button("Unlink Drive Project", systemImage: "xmark.circle") { unlink() }
                } else {
                    Button("Change Folder…", systemImage: "folder") { chooseFolder() }
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
                        Text(model.conflicts.count == 1 ? "1 file changed in both places"
                             : "\(model.conflicts.count) files changed in both places")
                            .font(.headline)
                        Text(conflictNamesSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Button("Review…") { showsConflictSheet = true }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .fixedSize()
                        .disabled(model.isBusy || repeatWhileOpen || localOnly)
                }
                .padding(.vertical, 4)
            } footer: {
                Text("Nothing was overwritten. Both versions are kept until you decide.")
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
            if let linkedProject {
                Text("“\(linkedProject.name)” syncs with its linked Drive copy. Choose other projects to share them through your sharing folder.")
            } else if !projects.isEmpty {
                Text("Shares completed recordings with their transcripts and attachments, plus project documents and images. Summaries and chats stay on this device. Turning a project off stops future updates; copies already in Drive stay.")
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
        let isLinked = project.id.uuidString == linkedLocalID
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
                                    .help("Linked to a project folder in Google Drive")
                            }
                        }
                        Text(contentSummary(for: project))
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

            if isSelected, let upToDate = verificationState(for: project) {
                Label(upToDate ? "Up to date" : "Changes to share",
                      systemImage: upToDate ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                    .font(.caption)
                    .foregroundStyle(upToDate ? Color.green : Color.orange)
                    .labelStyle(.titleAndIcon)
                    .fixedSize()
            }

            if phase == .ready || phase == .needsFolder {
                Menu {
                    projectMenuItems(project, isLinked: isLinked)
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
        .contextMenu { projectMenuItems(project, isLinked: isLinked) }
    }

    @ViewBuilder
    private func projectMenuItems(_ project: Project, isLinked: Bool) -> some View {
        if isLinked {
            if let url = destination?.webURL {
                Button("Open in Google Drive", systemImage: "arrow.up.right.square") { openURL(url) }
            }
            Button("Unlink Drive Project", systemImage: "xmark.circle") { unlink() }
        } else {
            Button("Link to Existing Drive Project…", systemImage: "link") { link(project.id) }
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

    private func verificationState(for project: Project) -> Bool? {
        guard let result = model.verification, result.folder == destination,
              Set(result.projects.keys) == Set(selectedProjects.map(\.id)) else { return nil }
        return result.projects[project.id]
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
        isConfirmed || usesLinkedDestination ? "Sync Now" : "Share"
    }

    private var shareHint: String? {
        if selectedProjects.isEmpty { return "Select at least one project to share." }
        if let result = model.verification, result.folder == destination {
            var text = "Last checked \(result.checkedAt.formatted(date: .omitted, time: .shortened))."
            if result.unfinished > 0 {
                text += result.unfinished == 1
                    ? " 1 recording is waiting for a transcript and will be shared once it’s transcribed."
                    : " \(result.unfinished) recordings are waiting for a transcript and will be shared once they’re transcribed."
            }
            return text
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

    private var confirmationTitle: String {
        let target = destination.map { "“\($0.name)”" } ?? "Google Drive"
        let count = selectedProjects.count
        if usesLinkedDestination, let linkedProject { return "Sync “\(linkedProject.name)” with Google Drive?" }
        return count == 1 ? "Share “\(selectedProjects[0].name)” to \(target)?" : "Share \(count) projects to \(target)?"
    }

    private func confirmationMessage(for action: ShareAction) -> String {
        var text = "Anyone with access to this Drive folder will be able to open the recordings, transcripts, attachments, and documents in "
        text += selectedProjects.count == 1 ? "this project." : "\(selectedProjects.map(\.name).joined(separator: ", "))."
        if action == .automatic { text += " Auto-Sync runs every five minutes while this screen is open and shares new content you add." }
        return text
    }

    // MARK: - Actions

    private func toggle(_ id: UUID) {
        var ids = selected
        if ids.contains(id) {
            ids.remove(id)
        } else if let linkedProject {
            if id == linkedProject.id {
                ids = [id]
            } else {
                ids.remove(linkedProject.id)
                ids.insert(id)
            }
        } else {
            ids.insert(id)
        }
        if projectSelectionOverride != nil { projectSelectionOverride = ids }
        else { selectionData = (try? JSONEncoder().encode(ids)) ?? Data() }
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
        if linkedLocalID.isEmpty { destinationData = data }
        else { sharingDestinationData = data }
    }

    private func chooseFolder() {
        let linkedFolder = usesLinkedDestination ? destination : nil
        model.chooseDestination { folder in
            if let linkedFolder {
                guard folder.id == linkedFolder.id, folder.publishedProjectID == linkedFolder.publishedProjectID else {
                    model.error = "Choose “\(linkedFolder.name)” to reconnect the linked project."
                    return
                }
                destinationData = (try? JSONEncoder().encode(folder)) ?? destinationData
                return
            }
            guard folder.publishedProjectID == nil else {
                model.error = "Choose a sharing folder outside the published project folder."
                return
            }
            saveSharingFolder(folder)
        }
    }

    private func link(_ id: UUID) {
        model.chooseDestination(requirePublishedProject: true) { folder in
            guard projects.contains(where: { $0.id == id }) else { return }
            saveLink(folder, to: id)
        }
    }

    private func unlink() {
        linkedLocalID = ""
        destinationData = sharingDestinationData
        sharingDestinationData = Data()
        model.status = nil
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

    private func verify() {
        guard canAct, let destination else { return }
        do {
            let snapshots = try selectedProjects.map { try DriveProjectSnapshot(project: $0, storage: storage) }
            model.verify(snapshots, folder: destination)
        } catch {
            model.error = error.localizedDescription
        }
    }

    private func saveLink(_ folder: DriveProjectFolder, to id: UUID) {
        guard let folderData = try? JSONEncoder().encode(folder),
              let ids = try? JSONEncoder().encode(Set([id])) else { return }
        if linkedLocalID.isEmpty { sharingDestinationData = destinationData }
        linkedLocalID = id.uuidString
        destinationData = folderData
        selectionData = ids
        if projectSelectionOverride != nil { projectSelectionOverride = [id] }
    }

    private func sync(resolutions: [DriveProjectSync.Resolution] = []) async {
        guard phase == .ready, let destination, isConfirmed, !selectedProjects.isEmpty,
              !model.isBusy, !Task.isCancelled else { return }
        do {
            let snapshots = try selectedProjects.map { try DriveProjectSnapshot(project: $0, storage: storage) }
            await model.sync(snapshots, folder: destination, storage: storage, container: context.container,
                             resolutions: resolutions)
            if !Task.isCancelled && resolutions.isEmpty && !model.conflicts.isEmpty && model.error == nil {
                showsConflictSheet = true
            }
        } catch {
            model.error = error.localizedDescription
        }
    }
}

private struct DriveConflictResolutionSheet: View {
    let conflicts: [DriveProjectSync.Conflict]
    let onApply: ([DriveProjectSync.Resolution]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var choices: [String: DriveProjectSync.Choice] = [:]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(conflicts) { conflict in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: conflict.key.hasPrefix("r-") ? "waveform" : "doc.text")
                                    .foregroundStyle(.orange)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(conflict.local.name)
                                        .font(.headline)
                                        .lineLimit(2)
                                    if conflict.drive.name != conflict.local.name {
                                        Text("Drive file: \(conflict.drive.name)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    } else {
                                        Text(conflict.canDownload
                                             ? "Modified locally and in Google Drive"
                                             : "Local and Drive copies differ")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Picker("Action for \(conflict.local.name)", selection: binding(for: conflict)) {
                                Text("Keep Both").tag(DriveProjectSync.Choice.both)
                                Text("Use Local").tag(DriveProjectSync.Choice.local)
                                if conflict.canDownload {
                                    Text("Use Drive").tag(DriveProjectSync.Choice.drive)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            choiceCaption(for: effectiveChoice(for: conflict), canDownload: conflict.canDownload)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
#if os(macOS)
                    HStack {
                        Text("Conflicting Files (\(conflicts.count))")
                        Spacer()
                        if conflicts.count > 1 {
                            setAllMenu
                                .controlSize(.small)
                        }
                    }
#else
                    Text("Conflicting Files (\(conflicts.count))")
#endif
                } footer: {
                    Text(planSummary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Resolve Conflicts")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { dismiss() }
                }
#if os(iOS)
                if conflicts.count > 1 {
                    ToolbarItem(placement: .secondaryAction) {
                        setAllMenu
                    }
                }
#endif
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(conflicts.map { .init(conflict: $0, choice: effectiveChoice(for: $0)) })
                    }
                    .disabled(conflicts.isEmpty)
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 520, idealWidth: 540, minHeight: 470, idealHeight: 500)
#endif
    }

    private func effectiveChoice(for conflict: DriveProjectSync.Conflict) -> DriveProjectSync.Choice {
        let chosen = choices[conflict.id] ?? .both
        if chosen == .drive && !conflict.canDownload { return .both }
        return chosen
    }

    private func binding(for conflict: DriveProjectSync.Conflict) -> Binding<DriveProjectSync.Choice> {
        Binding(
            get: { effectiveChoice(for: conflict) },
            set: { choices[conflict.id] = $0 }
        )
    }

    private var setAllMenu: some View {
        Menu("Set All", systemImage: "checklist") {
            Button("Keep Both for All") { setAll(.both) }
            Button("Overwrite Drive for All (Use Local)") { setAll(.local) }
            if conflicts.contains(where: \.canDownload) {
                Button("Overwrite Local for All (Use Drive)") { setAll(.drive) }
            }
        }
    }

    private func setAll(_ choice: DriveProjectSync.Choice) {
        for conflict in conflicts {
            choices[conflict.id] = (choice == .drive && !conflict.canDownload) ? .both : choice
        }
    }

    @ViewBuilder
    private func choiceCaption(for choice: DriveProjectSync.Choice, canDownload: Bool) -> some View {
        switch choice {
        case .both:
            Label(canDownload
                  ? "Keeps the Drive file and saves a separate Local Conflict Copy."
                  : "Keeps the Drive file and saves a separate Local Conflict Copy (Drive download unavailable).",
                  systemImage: "doc.on.doc")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .local:
            Label("Overwrites the Google Drive file with your local version.", systemImage: "arrow.up.doc")
                .font(.caption)
                .foregroundStyle(.orange)
        case .drive:
            Label("Overwrites your local transcript with the Google Drive version.", systemImage: "arrow.down.doc")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var planSummary: String {
        let resolved = conflicts.map(effectiveChoice)
        let bothCount = resolved.filter { $0 == .both }.count
        let localCount = resolved.filter { $0 == .local }.count
        let driveCount = resolved.filter { $0 == .drive }.count
        var parts: [String] = []
        if bothCount > 0 { parts.append("\(bothCount) keep both") }
        if localCount > 0 { parts.append("\(localCount) overwrite Drive") }
        if driveCount > 0 { parts.append("\(driveCount) overwrite local") }
        return parts.isEmpty ? "" : "Selected actions: " + parts.joined(separator: " · ") + "."
    }
}

@MainActor @Observable
final class DriveProjectsModel {
    enum DestinationAvailability: Equatable {
        case available
        case failure(String)
    }

    private let connection = GoogleDriveConnection.shared
    var destinationAvailability: DestinationAvailability?
    private(set) var isDriveConnected = false
    private let source = DrivePackageFolder()
    private var work: Task<Void, Never>?
    private var isCloudWork = false
    var isBusy: Bool { work != nil }
    var sourceName: String?
    var packages: [URL] = []
    var error: String?
    var status: String?
    var progress: Double?
    var verification: DriveProjectSync.Verification?
    var conflicts: [DriveProjectSync.Conflict] = []

    func checkDriveAvailability() async {
        do {
            isDriveConnected = try await connection.status()
            destinationAvailability = .available
        } catch {
            destinationAvailability = .failure("Drive sharing is unavailable in this build. Local package sharing is available.")
        }
    }

    func chooseSource(_ url: URL, remember: @escaping (Data?) -> Void) {
        start("Reading source folder…") {
            try await self.loadSource(url)
            remember(await self.source.remember(url))
        }
    }

    func restoreSource(_ bookmark: Data) {
        start("Reading source folder…") {
            do {
                let url = try await self.source.restore(bookmark)
                try await self.loadSource(url)
            } catch {
                self.status = "Choose the source folder again to restore access."
            }
        }
    }

    private func loadSource(_ url: URL) async throws {
        let packages = try await source.packages(in: url)
        try Task.checkCancellation()
        sourceName = url.lastPathComponent
        self.packages = packages
        status = nil
    }

    func importPackage(_ url: URL, storage: LibraryStorage, container: ModelContainer, onImported: @escaping (UUID) -> Void) {
        start("Importing recording…") {
            let staged = try await self.source.stage(url, storage: storage)
            let id = try RecordingPackageImport.commit(staged, storage: storage, container: container)
            self.status = "Recording imported."
            onImported(id)
        }
    }

    func recoverSharingFolder(from folder: DriveProjectFolder) async throws -> DriveProjectFolder? {
        try await connection.sharingParent(of: folder)
    }

    func chooseDestination(requirePublishedProject: Bool = false, _ selected: @escaping (DriveProjectFolder) -> Void) {
        start("Waiting for Google Drive…", cloud: true) {
            let folder = try await self.connection.chooseFolder()
            try Task.checkCancellation()
            self.isDriveConnected = true
            if requirePublishedProject, folder.publishedProjectID == nil {
                throw DriveProjectError.selectPublishedProject
            }
            selected(folder)
            self.status = nil
        }
    }

    func importDriveProject(storage: LibraryStorage, container: ModelContainer,
                            onImported: @escaping (DriveProjectFolder, UUID) -> Void) {
        start("Choose a published project folder in Drive…", cloud: true) {
            let folder = try await self.connection.chooseFolder()
            guard let id = folder.publishedProjectID else { throw DriveProjectError.selectPublishedProject }
            self.isDriveConnected = true
            self.status = "Importing Drive Project…"
            let token = try await self.connection.uploadToken()
            let remote = DriveProjectRemote(transport: .live, checkPrivacy: DriveSharingPrivacy.check, token: token)
            let count = try await DriveProjectSync.shared.importProject(folder, remote: remote, storage: storage, container: container)
            onImported(folder, id)
            self.status = "Imported \(count) new recordings from \(folder.name)."
        }
    }

    func verify(_ snapshots: [DriveProjectSnapshot], folder: DriveProjectFolder) {
        guard !isBusy else { return }
        verification = nil
        start("Checking Drive versions…", cloud: true) {
            let token = try await self.connection.uploadToken()
            let remote = DriveProjectRemote(transport: .live, checkPrivacy: DriveSharingPrivacy.check, token: token)
            let result = try await DriveProjectSync.shared.verify(projects: snapshots, folder: folder, remote: remote) { name in
                await MainActor.run { self.status = "Checking \(name)…" }
            }
            try Task.checkCancellation()
            self.verification = result
            self.status = nil
        }
    }

    func sync(_ snapshots: [DriveProjectSnapshot], folder: DriveProjectFolder,
              storage: LibraryStorage, container: ModelContainer, resolutions: [DriveProjectSync.Resolution] = []) async {
        guard work == nil, !Task.isCancelled else { return }
        verification = nil
        start("Checking Drive…", cloud: true) {
            let token = try await self.connection.uploadToken()
            let remote = DriveProjectRemote(transport: .live, checkPrivacy: DriveSharingPrivacy.check, token: token)
            let result = try await DriveProjectSync.shared.run(
                projects: snapshots, folder: folder, remote: remote, storageRoot: storage.rootURL,
                applyTranscript: { incoming, snapshot, projectID in
                    try RecordingPackageImport.applySyncedTranscript(incoming, replacing: snapshot, projectID: projectID,
                                                                     storage: storage, container: container)
                }, resolutions: resolutions
            ) { name, fraction in
                await MainActor.run {
                    self.status = name
                    self.progress = fraction
                }
            }
            try Task.checkCancellation()
            if !resolutions.isEmpty {
                let refreshedByID = Dictionary(uniqueKeysWithValues: result.conflicts.map { ($0.id, $0) })
                var updated: [DriveProjectSync.Conflict] = []
                for existing in self.conflicts {
                    if result.resolvedConflictIDs.contains(existing.id) { continue }
                    if let refreshed = refreshedByID[existing.id] {
                        updated.append(refreshed)
                    } else {
                        updated.append(existing)
                    }
                }
                for refreshed in result.conflicts where !updated.contains(where: { $0.id == refreshed.id }) {
                    updated.append(refreshed)
                }
                self.conflicts = updated
                if !result.conflicts.isEmpty {
                    let driveChoices = Set(resolutions.filter { $0.choice == .drive }.map(\.conflict.id))
                    if result.conflicts.contains(where: { driveChoices.contains($0.id) && !$0.canDownload }) {
                        self.error = "One or more Drive versions changed audio, attachments, or transcript segments and cannot update the local recording in place. Choose Use Local or Keep Both."
                    } else {
                        self.error = "One or more files changed since these conflicts were detected. Review the updated conflicts and apply again."
                    }
                }
            } else {
                self.conflicts = result.conflicts
            }
            let conflictSummary = self.conflicts.isEmpty
                ? ""
                : " · \(self.conflicts.count) \(self.conflicts.count == 1 ? "conflict needs" : "conflicts need") review"
            var parts: [String] = []
            if result.uploaded > 0 { parts.append("\(result.uploaded) uploaded") }
            if result.downloaded > 0 { parts.append("\(result.downloaded) downloaded") }
            if result.unchanged > 0 { parts.append("\(result.unchanged) up to date") }
            if result.unfinished > 0 { parts.append("\(result.unfinished) awaiting transcript") }
            let time = Date.now.formatted(date: .omitted, time: .shortened)
            self.status = "Synced at \(time)" + (parts.isEmpty ? "" : " · " + parts.joined(separator: ", ")) + "\(conflictSummary)."
            if result.failures.isEmpty && self.conflicts.isEmpty {
                // A clean sync leaves every synced project matching Drive; keep the row badges meaningful.
                self.verification = .init(checkedAt: .now, folder: folder,
                                          projects: Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, true) }),
                                          unfinished: result.unfinished)
            }
            if result.failures.count > result.conflicts.count {
                let nonConflictFailures = result.failures.filter {
                    !$0.hasSuffix(DriveProjectError.conflictingVersion.localizedDescription)
                }
                self.error = (nonConflictFailures.isEmpty ? result.failures : nonConflictFailures).joined(separator: "\n")
            }
        }
        let task = work
        await withTaskCancellationHandler {
            await task?.value
        } onCancel: {
            task?.cancel()
        }
    }

    func cancel() { work?.cancel() }
    func cancelCloud() { if isCloudWork { cancel() } }

    private func start(_ label: String, cloud: Bool = false, action: @escaping @MainActor () async throws -> Void) {
        guard work == nil else { return }
        status = label
        error = nil
        isCloudWork = cloud
        work = Task {
            defer { work = nil; isCloudWork = false; progress = nil }
            do { try await action() }
            catch {
                if Task.isCancelled { status = "Cancelled." }
                else { self.error = error.localizedDescription; status = nil }
            }
        }
    }
}
