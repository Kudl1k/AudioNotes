import SwiftUI

struct TranscriptionControls: View {
    let model: RecordingViewModel
    let transcribe: () -> Void
    var regenerate: (() -> Void)? = nil
    @State private var isShowingDetails = false

    private var visibleProgress: Double? {
        model.progressSnapshot?.overallProgress ?? model.progress
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Label(title, systemImage: "text.bubble")
                        .font(.headline)
                    if model.state.isProcessing || model.state == .completed {
                        Text(AudioTime.string(model.recording.duration) + " recording")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                OpenSettingsLink { Image(systemName: "gearshape") }.help("Transcription settings")
                    .accessibilityLabel("Transcription settings").accessibilityIdentifier("transcription.settings")
                if model.state.isProcessing {
                    Button("Cancel", action: model.cancelTranscription)
                        .disabled(!model.state.canCancel)
                        .accessibilityLabel("Cancel transcription").accessibilityIdentifier("progress.cancel")
                } else if model.canTranscribe {
                    Button(model.state == .idle ? "Transcribe" : "Retry", action: transcribe)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier(model.state == .idle ? "transcription.start" : "transcription.retry")
                } else if model.canRegenerate, let regenerate {
                    Button("Regenerate…", action: regenerate)
                }
            }

            if model.canTranscribe {
                TranscriptionProviderControls(model: model)
                Text(model.transcriptionEstimate.displayText).font(.caption).foregroundStyle(.secondary)
            }

            if model.state.isProcessing, let snapshot = model.progressSnapshot {
                VStack(alignment: .leading, spacing: 8) {
                    OperationProgressView(title: activityTitle(snapshot), status: partStatus(snapshot),
                        progress: OperationProgressValue(fraction: visibleProgress),
                        startedAt: snapshot.startedAt, estimatedRemaining: snapshot.estimatedRemainingTime)
                    if let duration = snapshot.totalAudioDuration {
                        Text("\(AudioTime.string(snapshot.processedAudioDuration ?? 0)) / \(AudioTime.string(duration)) audio processed")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        isShowingDetails.toggle()
                    } label: {
                        Label(isShowingDetails ? "Hide Details" : "Show Details",
                              systemImage: isShowingDetails ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(isShowingDetails ? "Hide transcription steps" : "Show transcription steps")

                    if isShowingDetails {
                        details(snapshot)
                            .font(.caption)
                            .padding(.top, 2)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(accessibilityProgress(snapshot))
            } else if model.state == .completed {
                Label("Transcription complete · \(AudioTime.string(model.recording.duration)) · ^[\(max(1, model.progressSnapshot?.completedParts ?? 1)) part](inflect: true) · completed in \(model.completionDurationText)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)
            }

            if case .failed(let message) = model.state {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityLabel("Transcription failed: \(message)")
                if let snapshot = model.progressSnapshot {
                    VStack(alignment: .leading, spacing: 3) {
                        if let part = snapshot.currentPart {
                            Text("Part \(part) of \(snapshot.totalParts ?? part) · \(snapshot.completedParts) completed")
                        }
                        Text("\(AudioTime.string(snapshot.processedAudioDuration ?? 0)) of \(AudioTime.string(snapshot.totalAudioDuration ?? model.recording.duration)) processed")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                if let details = model.errorDetails {
                    Button {
                        isShowingDetails.toggle()
                    } label: {
                        Label(isShowingDetails ? "Hide Response Details" : "Response details",
                              systemImage: isShowingDetails ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    if isShowingDetails {
                        Text(details).font(.caption.monospaced()).textSelection(.enabled)
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            Text(model.isMockProvider
                 ? "Mock provider: creates sample text for testing, not a transcription of your audio."
                 : "Provider: \(model.providerName)\(model.selectedModelName.map { " · " + $0 } ?? "") · \(model.executionLocation.title)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var title: String {
        if model.state.isProcessing { "Transcribing \(model.recording.title)" }
        else { model.state.title }
    }

    private func activityTitle(_ snapshot: TranscriptionProgressSnapshot) -> String {
        if snapshot.phase == .transcribing && model.executionLocation == .local && !model.isMockProvider { return "Transcribing locally…" }
        return switch snapshot.phase {
        case .preparing: "Preparing audio…"
        case .splitting: "Optimizing audio…"
        case .uploading: "Uploading audio…"
        case .processing: "Processing audio…"
        case .transcribing: "Transcribing audio…"
        case .merging: "Combining transcript…"
        case .saving: "Saving transcript…"
        case .completed: "Transcription complete"
        }
    }

    private func partStatus(_ snapshot: TranscriptionProgressSnapshot) -> String? {
        snapshot.partDescription.map { "\($0) · \(snapshot.completedParts) completed" }
    }

    private func partLabel(_ snapshot: TranscriptionProgressSnapshot) -> String {
        snapshot.partDescription ?? snapshot.phase.message
    }

    private func accessibilityProgress(_ snapshot: TranscriptionProgressSnapshot) -> String {
        let percent = visibleProgress.map { ", \(Int($0 * 100)) percent complete" } ?? ""
        return "Transcription\(percent), \(partLabel(snapshot))"
    }

    @ViewBuilder private func details(_ snapshot: TranscriptionProgressSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            detailRow("Preparing audio", done: snapshot.phase != .preparing && snapshot.phase != .splitting,
                      active: snapshot.phase == .preparing || snapshot.phase == .splitting)
            if let total = snapshot.totalParts, total > 0 {
                ForEach(1...total, id: \.self) { part in
                    detailRow("Part \(part) of \(total)", done: part <= snapshot.completedParts,
                              active: part == snapshot.currentPart && snapshot.phase == .transcribing)
                }
            } else {
                detailRow("Transcription request", done: snapshot.phase == .saving || snapshot.phase == .completed,
                          active: snapshot.phase == .transcribing)
            }
            detailRow("Saving", done: snapshot.phase == .completed, active: snapshot.phase == .saving)
        }
    }

    private func detailRow(_ title: String, done: Bool, active: Bool) -> some View {
        Label(title, systemImage: done ? "checkmark.circle.fill" : (active ? "arrow.trianglehead.2.clockwise.rotate.90" : "circle"))
            .foregroundStyle(done ? .secondary : (active ? .primary : .tertiary))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title).accessibilityValue(done ? "Completed" : (active ? "In progress" : "Waiting"))
    }
}
