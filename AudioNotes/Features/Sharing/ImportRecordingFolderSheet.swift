import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ImportRecordingFolderSheet: View {
    let storage: LibraryStorage
    let onImported: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage("drive.project.sourceFolder") private var sourceBookmark = Data()
    @State private var model = DriveProjectsModel()
    @State private var showPicker = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let sourceName = model.sourceName {
                        LabeledContent("Folder", value: sourceName)
                    }
                    Button(model.sourceName == nil ? "Choose Folder…" : "Change Folder…", systemImage: "folder") {
                        showPicker = true
                    }.disabled(model.isBusy)
                } footer: {
                    if model.sourceName == nil {
                        Text("Choose a folder containing exported Soniquill recordings. You can select a Google Drive folder if it appears in the system picker.")
                    }
                }

                if model.sourceName != nil {
                    Section("Recordings in This Folder") {
                        if model.packages.isEmpty {
                            Text("No Soniquill packages found. If this folder contains projects, choose a project’s own subfolder.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(model.packages, id: \.self) { url in
                            Button(url.deletingPathExtension().lastPathComponent, systemImage: "waveform") {
                                model.importPackage(url, storage: storage, container: context.container) { id in
                                    onImported(id)
                                    dismiss()
                                }
                            }.disabled(model.isBusy)
                        }
                    }
                }
                if let status = model.status {
                    Section {
                        Text(status)
                        if model.isBusy { Button("Cancel") { model.cancel() } }
                    }
                }
            }
            .navigationTitle("Import from a Folder")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.disabled(model.isBusy)
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 480, minHeight: 360)
#endif
        .interactiveDismissDisabled(model.isBusy)
        .task {
            if !sourceBookmark.isEmpty { model.restoreSource(sourceBookmark) }
        }
        .onDisappear { model.cancel() }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): model.chooseSource(url) { sourceBookmark = $0 ?? Data() }
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .alert("Import from a Folder", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}
