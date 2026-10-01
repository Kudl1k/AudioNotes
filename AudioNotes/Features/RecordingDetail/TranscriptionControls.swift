import SwiftUI

struct TranscriptionControls: View {
    let model: RecordingViewModel
    let transcribe: () -> Void
    var regenerate: (() -> Void)? = nil
    @State private var isShowingDetails = false

    private var visibleProgress: Double? {
        model.progressSnapshot?.overallProgress ?? model.progress.map { 0.1 + 0.8 * min(1, max(0, $0)) }
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
                SettingsLink { Image(systemName: "gearshape") }.help("Transcription settings")
                if model.state.isProcessing {
                    Button("Cancel", action: model.cancelTranscription)
                        .disabled(!model.state.canCancel)
                } else if model.canTranscribe {
                    Button(model.state == .idle ? "Transcribe" : "Try Again", action: transcribe)
                        .buttonStyle(.borderedProminent)
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
                    if let progress = visibleProgress {
                        ProgressView(value: progress)
                            .accessibilityLabel("Transcription progress")
                            .accessibilityValue(Text("\(Int(progress * 100)) percent"))
                            .animation(.easeInOut(duration: 0.25), value: progress)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                            .accessibilityLabel("Transcription in progress")
                    }
                    HStack {
                        Label(activityTitle(snapshot), systemImage: "waveform")
                            .font(.subheadline)
                        Spacer()
                        Text(partLabel(snapshot)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let duration = snapshot.totalAudioDuration {
                        Text("\(AudioTime.string(snapshot.processedAudioDuration ?? 0)) / \(AudioTime.string(duration)) processed")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        HStack(spacing: 16) {
                            Text("Elapsed  \(AudioTime.string(model.elapsedTime ?? 0))")
                            if let eta = snapshot.estimatedRemainingTime {
                                Text("Est. remaining  ~\(AudioTime.string(eta))")
                            }
                        }
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
                Label("Transcription complete · \(AudioTime.string(model.recording.duration)) · \(max(1, model.progressSnapshot?.completedParts ?? 1)) part · completed in \(model.completionDurationText)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)
            }

            if case .failed(let message) = model.state {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).textSelection(.enabled)
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
        case .transcribing: "Transcribing part \(snapshot.currentPart ?? 1) of \(snapshot.totalParts ?? 1)…"
        case .merging: "Combining transcript…"
        case .saving: "Saving transcript…"
        case .completed: "Transcription complete"
        }
    }

    private func partLabel(_ snapshot: TranscriptionProgressSnapshot) -> String {
        if let current = snapshot.currentPart, let total = snapshot.totalParts { "Part \(current) of \(total)" }
        else { snapshot.phase.message }
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
    }
}
