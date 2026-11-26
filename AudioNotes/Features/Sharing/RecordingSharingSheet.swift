import SwiftUI
#if os(iOS)
import UIKit
#endif

struct RecordingSharingSheet: View {
    let recording: Recording
    let storage: LibraryStorage

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage("ai.localOnly") private var localOnly = false
    @State private var selected: Set<UUID> = []
    @State private var connected = false
    @State private var connectionUnavailable: String?
    @State private var work: Task<Void, Never>?
    @State private var error: String?
    @State private var status: String?
    @State private var progress: Double?
    @State private var link: URL?
    @State private var prepared: URL?
    @State private var upload: GoogleDriveUpload?
    @State private var confirmUpload = false
    @State private var uploadSize: String?
    @State private var preparedAttachmentNames: [String] = []
    @State private var showSavePicker = false
    @State private var cloudWork = false
    @State private var temporaryFolders = SharingTemporaryFolders()

    private let connection = GoogleDriveConnection.shared

    private var attachments: [RecordingSource] {
        recording.sources.filter { !$0.isPrimaryAudio }.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }
    private var packageName: String {
        let name = recording.title.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters))
            .joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? "Recording" : String(name.prefix(60))) + ".soniquill"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Recording", value: recording.title)
                    Label("Original audio and transcript", systemImage: "checkmark.circle")
                    if !attachments.isEmpty {
                        ForEach(attachments) { source in
                            Toggle(source.displayName, isOn: Binding(
                                get: { selected.contains(source.id) },
                                set: { include in
                                    if include { selected.insert(source.id) } else { selected.remove(source.id) }
                                    resetPackage()
                                }))
                                .disabled(work != nil || upload != nil)
                        }
                    }
                } header: {
                    Text("Package Contents")
                } footer: {
                    if !attachments.isEmpty { Text("Select the attachments you want to include.") }
                }

                Section("Share a Copy") {
                    Button("Save Package to Files…", systemImage: "arrow.down.document") { savePackage() }
                        .disabled(work != nil)

                    if localOnly {
                        Label("Local Only is on. Drive sharing is paused.", systemImage: "lock")
                            .foregroundStyle(.secondary)
                    } else if connectionUnavailable != nil {
                        Text("Google Drive is unavailable in this build. You can still save the package.")
                            .foregroundStyle(.secondary)
                    } else if let link {
                        Button("Open in Drive to Share", systemImage: "arrow.up.right.square") { openURL(link) }
                    } else if connected {
                        Button(upload == nil ? "Upload to My Drive…" : "Resume Upload…", systemImage: "arrow.up.circle") {
                            prepareUploadConfirmation()
                        }.disabled(work != nil)
                    } else {
                        Button("Connect Google Drive…", systemImage: "link") {
                            start(cloud: true) {
                                try await connection.connect()
                                connected = true
                                if upload != nil { resetPackage() }
                            }
                        }.disabled(work != nil)
                    }
                }

                if let status {
                    Section {
                        Text(status).foregroundStyle(.secondary)
                        if let progress { ProgressView(value: progress) }
                        if let work { Button("Cancel") { work.cancel() } }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Share Recording")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                if connected {
                    ToolbarItem(placement: .secondaryAction) {
                        Menu("Drive Account", systemImage: "person.crop.circle") {
                            Button("Disconnect Google Drive", role: .destructive) {
                                start(cloud: true) {
                                    defer { connected = false; resetPackage() }
                                    try await connection.disconnect()
                                }
                            }
                        }
                        .disabled(work != nil)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.disabled(work != nil)
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 460, minHeight: 380)
#else
        .sheet(isPresented: $showSavePicker) {
            if let prepared { PackageSavePicker(url: prepared) }
        }
#endif
        .interactiveDismissDisabled(work != nil)
        .task { await refreshConnection() }
        .onChange(of: localOnly) { _, enabled in
            if enabled && cloudWork { work?.cancel() }
        }
        .onDisappear {
            let folders = temporaryFolders
            if let work {
                work.cancel()
                // The cancelled task may still be finishing a package; clean up once it has stopped.
                Task { await work.value; folders.removeAll() }
            } else {
                resetPackage()
                folders.removeAll()
            }
        }
        .confirmationDialog("Upload this package to My Drive?", isPresented: $confirmUpload, titleVisibility: .visible) {
            Button(upload == nil ? "Upload Package" : "Resume Upload") { uploadPackage() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Google Drive will receive the original audio and transcript."
                 + (preparedAttachmentNames.isEmpty ? "" :
                    " Selected attachments: \(preparedAttachmentNames.joined(separator: ", ")).")
                 + (uploadSize.map { " Package size: \($0)." } ?? "")
                 + " Open the uploaded file in Drive to give someone access.")
        }
        .alert("Recording Sharing", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func refreshConnection() async {
        do {
            connected = try await connection.status()
            connectionUnavailable = nil
        } catch {
            connectionUnavailable = error.localizedDescription
        }
    }

    private func start(cloud: Bool = false, _ action: @escaping @MainActor () async throws -> Void) {
        guard work == nil else { return }
        cloudWork = cloud
        status = nil
        progress = nil
        work = Task {
            defer { work = nil; cloudWork = false; progress = nil }
            do { try await action() }
            catch is CancellationError { status = "Cancelled." }
            catch let failure {
                if Task.isCancelled {
                    status = "Cancelled."
                } else {
                    error = failure.localizedDescription
                    if cloud { await refreshConnection() }
                }
            }
        }
    }

    private func prepare() async throws -> URL {
        if let prepared { return prepared }
        status = "Preparing package…"
        let snapshot = try RecordingPackageSnapshot(recording: recording, selected: selected, storage: storage)
        let folder = FileManager.default.temporaryDirectory.appending(path: "SoniquillShare-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        temporaryFolders.track(folder)
        let url = folder.appendingPathComponent(packageName)
        do {
            try await RecordingPackageCodec().export(snapshot, to: url)
            try Task.checkCancellation()
        } catch {
            temporaryFolders.remove(folder)
            throw error
        }
        prepared = url
        preparedAttachmentNames = snapshot.files.dropFirst().map(\.name)
        return url
    }

    private func resetPackage() {
        discardPreparedPackage()
        upload = nil
        link = nil
        status = nil
    }

    private func discardPreparedPackage() {
        if let prepared { temporaryFolders.remove(prepared.deletingLastPathComponent()) }
        prepared = nil
        preparedAttachmentNames = []
    }

    private func savePackage() {
        start {
            let package = try await prepare()
            status = nil
#if os(macOS)
            if let target = await FilePanels.chooseSaveDestination(fileName: packageName, types: [.recordingPackage]) {
                try await RecordingPackageCodec().savePrepared(package, to: target)
                status = "Package saved."
            }
#else
            showSavePicker = true
#endif
        }
    }

    private func prepareUploadConfirmation() {
        start {
            let package = try await prepare()
            if let bytes = try package.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                uploadSize = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            }
            status = nil
            confirmUpload = true
        }
    }

    private func uploadPackage() {
        start(cloud: true) {
            try DriveSharingPrivacy.check()
            let package = try await prepare()
            let operation: GoogleDriveUpload
            if let upload { operation = upload }
            else {
                let token = try await connection.uploadToken()
                operation = GoogleDriveUpload(file: package, name: package.lastPathComponent, token: token)
                upload = operation
            }
            status = "Uploading to My Drive…"
            link = try await operation.run { received, total in
                await MainActor.run { progress = Double(received) / Double(total) }
            }
            upload = nil
            discardPreparedPackage()
            status = "Uploaded to My Drive."
        }
    }
}

/// Temporary package folders this sheet created; removed when they are no longer needed.
@MainActor
private final class SharingTemporaryFolders {
    private var folders: Set<URL> = []

    func track(_ folder: URL) { folders.insert(folder) }

    func remove(_ folder: URL) {
        folders.remove(folder)
        try? FileManager.default.removeItem(at: folder)
    }

    func removeAll() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders.removeAll()
    }
}

#if os(iOS)
private struct PackageSavePicker: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}
#endif
