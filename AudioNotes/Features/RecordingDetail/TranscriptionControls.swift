#if os(macOS)
import SwiftUI

struct TranscriptionControls: View {
    let model: RecordingViewModel
    let transcribe: () -> Void
    var regenerate: (() -> Void)? = nil
    @State private var isShowingSteps = false
    @State private var isShowingResponseDetails = false

    private var visibleProgress: Double? {
        model.progressSnapshot?.overallProgress ?? model.progress
    }

    private var showsResetButton: Bool {
        if case .failed = model.state { return true }
        return model.state == .cancelled || model.hasCheckpoint
    }

    private var primaryActionTitle: String {
        if model.hasCheckpoint { return "Resume" }
        return model.state == .idle ? "Transcribe" : "Retry"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceSpacing.section) {
            HStack(alignment: .center, spacing: WorkspaceSpacing.section) {
                VStack(alignment: .leading, spacing: 3) {
                    headerTitle
                    Text(model.transcriptionConfiguration)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if !model.state.isProcessing && model.hasCheckpoint {
                        Text("Completed parts are saved and will be reused when you resume.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if model.canTranscribe, case .idle = model.state {
                        Text(model.transcriptionEstimate.displayText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: WorkspaceSpacing.section)
                actionButtons
            }

            if model.state.isProcessing, let snapshot = model.progressSnapshot {
                VStack(alignment: .leading, spacing: WorkspaceSpacing.standard) {
                    if let fraction = visibleProgress {
                        let progressValue = OperationProgressValue(fraction: fraction)
                        HStack(spacing: WorkspaceSpacing.standard) {
                            ProgressView(value: fraction)
                                .accessibilityLabel(activityTitle(snapshot))
                                .accessibilityValue(progressValue.percentage ?? "")
                            if let percentage = progressValue.percentage {
                                Text(percentage)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: WorkspaceSpacing.standard) {
                            if let summary = snapshotSummary(snapshot) {
                                Text(summary)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: WorkspaceSpacing.section)
                            OperationElapsedTimeView(
                                startedAt: snapshot.startedAt,
                                estimatedRemaining: snapshot.estimatedRemainingTime
                            )
                        }
                        VStack(alignment: .leading, spacing: WorkspaceSpacing.compact) {
                            if let summary = snapshotSummary(snapshot) {
                                Text(summary)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            OperationElapsedTimeView(
                                startedAt: snapshot.startedAt,
                                estimatedRemaining: snapshot.estimatedRemainingTime
                            )
                        }
                    }

                    DisclosureGroup("Transcription Steps", isExpanded: $isShowingSteps) {
                        details(snapshot)
                            .font(.callout)
                            .padding(.top, WorkspaceSpacing.compact)
                    }
                    .disclosureGroupStyle(FullRowDisclosureStyle())
                    .accessibilityIdentifier("transcription.steps")
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(accessibilityProgress(snapshot))
            }

            if case .failed(let message) = model.state {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .accessibilityLabel("Transcription failed: \(message)")

                if let snapshot = model.progressSnapshot, let summary = snapshotSummary(snapshot) {
                    Text(summary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if let details = model.errorDetails {
                    DisclosureGroup("Response Details", isExpanded: $isShowingResponseDetails) {
                        ScrollView {
                            Text(details)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 160)
                        .padding(.top, WorkspaceSpacing.compact)
                    }
                    .disclosureGroupStyle(FullRowDisclosureStyle())
                    .accessibilityIdentifier("transcription.responseDetails")
                }
            }
        }
    }

    @ViewBuilder
    private var headerTitle: some View {
        if model.state.isProcessing {
            HStack(spacing: WorkspaceSpacing.standard) {
                if visibleProgress == nil {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
                Text(model.progressSnapshot.map(activityTitle) ?? model.state.title)
                    .font(.headline)
            }
        } else if model.state == .completed {
            Label(
                "Transcription complete · \(AudioTime.string(model.recording.duration)) · ^[\(max(1, model.progressSnapshot?.completedParts ?? 1)) part](inflect: true) · completed in \(model.completionDurationText)",
                systemImage: "checkmark.circle.fill"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.green)
        } else if case .failed = model.state {
            Label("Transcription failed", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)
        } else if model.state == .cancelled {
            Label("Transcription cancelled", systemImage: "xmark.circle")
                .font(.headline)
                .foregroundStyle(.secondary)
        } else {
            Label(model.state.title, systemImage: "text.bubble")
                .font(.headline)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: WorkspaceSpacing.standard) {
            if model.canTranscribe {
                TranscriptionOptionsButton(model: model)
            }
            if model.state.isProcessing {
                Button("Cancel", action: model.cancelTranscription)
                    .disabled(!model.state.canCancel)
                    .accessibilityLabel("Cancel transcription")
                    .accessibilityIdentifier("progress.cancel")
            } else {
                if showsResetButton {
                    Button("Reset", action: model.resetTranscription)
                        .help(model.hasCheckpoint ? "Clear saved progress and reset transcription state" : "Reset transcription state")
                        .accessibilityIdentifier("transcription.reset")
                }
                if model.canTranscribe {
                    Button(primaryActionTitle, action: transcribe)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier(model.state == .idle ? "transcription.start" : "transcription.retry")
                } else if model.canRegenerate, let regenerate {
                    Button("Regenerate…", action: regenerate)
                }
            }
        }
    }

    private func activityTitle(_ snapshot: TranscriptionProgressSnapshot) -> String {
        if snapshot.phase == .transcribing && model.executionLocation == .local && !model.isMockProvider {
            return "Transcribing locally…"
        }
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

    private func snapshotSummary(_ snapshot: TranscriptionProgressSnapshot) -> String? {
        var parts: [String] = []
        if let part = partStatus(snapshot) {
            parts.append(part)
        }
        if let duration = snapshot.totalAudioDuration, duration > 0 {
            parts.append("\(AudioTime.string(snapshot.processedAudioDuration ?? 0)) / \(AudioTime.string(duration)) processed")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func partLabel(_ snapshot: TranscriptionProgressSnapshot) -> String {
        snapshot.partDescription ?? snapshot.phase.message
    }

    private func accessibilityProgress(_ snapshot: TranscriptionProgressSnapshot) -> String {
        let percent = visibleProgress.map { ", \(Int($0 * 100)) percent complete" } ?? ""
        return "Transcription\(percent), \(partLabel(snapshot))"
    }

    @ViewBuilder private func details(_ snapshot: TranscriptionProgressSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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

private struct FullRowDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: WorkspaceSpacing.compact) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, alignment: .center)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                    configuration.label
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                }
            }
            .buttonStyle(DisclosureRowButtonStyle())
            .padding(.leading, -8)

            if configuration.isExpanded {
                configuration.content
                    .padding(.leading, 18)
            }
        }
    }
}

private struct DisclosureRowButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : (isHovering ? 0.08 : 0)))
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}
#endif
