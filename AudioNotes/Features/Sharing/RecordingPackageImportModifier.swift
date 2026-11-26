import SwiftData
import SwiftUI

struct RecordingPackageImportModifier: ViewModifier {
    @Binding var isPresented: Bool
    let storage: LibraryStorage
    let onImported: (UUID) -> Void

    @Environment(\.modelContext) private var context
    @State private var work: Task<Void, Never>?
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .background {
                Color.clear.fileImporter(isPresented: $isPresented, allowedContentTypes: [.recordingPackage]) { result in
                    switch result {
                    case .success(let url): start(url)
                    case .failure(let failure): error = failure.localizedDescription
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let work {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Importing recording package…")
                        Spacer()
                        Button("Cancel") { work.cancel() }
                    }
                    .padding().background(.regularMaterial)
                }
            }
            .alert("Recording Package", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
    }

    private func start(_ url: URL) {
        guard work == nil else { return }
        let container = context.container
        work = Task {
            defer { work = nil }
            do {
                let staged = try await RecordingPackageCodec().stage(url, under: storage.rootURL)
                let id = try RecordingPackageImport.commit(staged, storage: storage, container: container)
                onImported(id)
            } catch is CancellationError {
            } catch let failure {
                error = failure.localizedDescription
            }
        }
    }
}
