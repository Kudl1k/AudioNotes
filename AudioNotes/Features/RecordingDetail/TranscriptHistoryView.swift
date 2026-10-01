import Observation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class TranscriptHistoryViewModel {
    let recording: Recording
    var selectedID: UUID?
    var errorMessage: String?

    init(recording: Recording) {
        self.recording = recording
        selectedID = recording.transcript?.id
    }

    var versions: [Transcript] {
        ([recording.transcript].compactMap { $0 } + recording.transcriptHistory)
            .sorted { $0.createdAt > $1.createdAt }
    }
    var selected: Transcript? { versions.first { $0.id == selectedID } }

    func restore(_ version: Transcript, repository: SwiftDataTranscriptRepository) {
        do { try repository.makeCurrent(version, for: recording); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    func delete(_ version: Transcript, repository: SwiftDataTranscriptRepository) {
        do {
            try repository.delete(version, for: recording)
            if selectedID == version.id { selectedID = recording.transcript?.id }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}

struct TranscriptHistoryView: View {
    @State private var model: TranscriptHistoryViewModel
    let isProcessing: Bool
    let seek: (TimeInterval) -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var deleteCandidate: Transcript?

    init(recording: Recording, isProcessing: Bool, seek: @escaping (TimeInterval) -> Void) {
        _model = State(initialValue: TranscriptHistoryViewModel(recording: recording))
        self.isProcessing = isProcessing
        self.seek = seek
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcript History").font(.title2.bold())
            HSplitView {
                List(selection: $model.selectedID) {
                    ForEach(model.versions) { version in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(version.sourceName ?? "Unknown provider")
                            Text(version.createdAt, format: .dateTime.year().month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                            GenerationCostLabel(generationID: version.generationID, details: true)
                            if model.recording.transcript?.id == version.id {
                                Text("Current").font(.caption2).foregroundStyle(.tint)
                            }
                        }
                        .padding(.vertical, 4).tag(version.id)
                    }
                }
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
                TranscriptView(transcript: model.selected, seek: seek)
                    .frame(minWidth: 360)
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            HStack {
                if let version = model.selected, model.recording.transcript?.id != version.id {
                    Button("Make Current") {
                        model.restore(version, repository: SwiftDataTranscriptRepository(context: context))
                    }.disabled(isProcessing)
                    Button("Delete Version", role: .destructive) { deleteCandidate = version }
                        .disabled(isProcessing)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding().frame(minWidth: 760, minHeight: 480)
        .confirmationDialog("Delete this transcript version?", isPresented: Binding(
            get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }
        ), titleVisibility: .visible) {
            Button("Delete Version", role: .destructive) {
                guard let version = deleteCandidate else { return }
                model.delete(version, repository: SwiftDataTranscriptRepository(context: context))
                deleteCandidate = nil
            }
        } message: { Text("This cannot be undone. Generation usage and cost history are retained.") }
    }
}
