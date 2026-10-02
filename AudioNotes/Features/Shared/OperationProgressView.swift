import SwiftUI

/// Only this leaf observes the once-per-second display clock. There is no model
/// mutation, persisted tick, or timer task to retain after the view disappears.
struct OperationElapsedTimeView: View {
    let startedAt: Date
    var estimatedRemaining: TimeInterval? = nil

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { timeline in
            ViewThatFits(in: .horizontal) {
                HStack(spacing: WorkspaceSpacing.standard) { elapsed(timeline.date); remaining }
                VStack(alignment: .leading, spacing: WorkspaceSpacing.compact) { elapsed(timeline.date); remaining }
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        // A changing duration is readable on demand, never a live announcement.
        .accessibilityElement(children: .contain).accessibilityAddTraits(.updatesFrequently)
    }

    private func elapsed(_ now: Date) -> some View {
        Text("\(OperationDurationFormatter.string(OperationDurationFormatter.elapsed(since: startedAt, now: now))) elapsed")
    }

    @ViewBuilder private var remaining: some View {
        if let estimatedRemaining, estimatedRemaining.isFinite, estimatedRemaining > 0 {
            Text("~\(OperationDurationFormatter.string(estimatedRemaining)) remaining")
        }
    }
}

struct OperationProgressView: View {
    let title: String
    var status: String? = nil
    var progress = OperationProgressValue()
    var startedAt: Date? = nil
    var estimatedRemaining: TimeInterval? = nil
    var cancel: (() -> Void)? = nil
    var canCancel = true

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceSpacing.standard) {
            HStack(alignment: .firstTextBaseline, spacing: WorkspaceSpacing.standard) {
                if progress.fraction == nil {
                    ProgressView().controlSize(.small).accessibilityLabel(title)
                }
                Text(title).font(.callout)
                Spacer(minLength: WorkspaceSpacing.standard)
                if let cancel {
                    Button("Cancel", action: cancel).disabled(!canCancel).controlSize(.small)
                        .accessibilityLabel("Cancel \(title)").accessibilityIdentifier("progress.cancel")
                }
            }
            if let fraction = progress.fraction {
                HStack(spacing: WorkspaceSpacing.standard) {
                    ProgressView(value: fraction).accessibilityLabel(title)
                        .accessibilityValue(progress.percentage ?? "")
                    Text(progress.percentage ?? "").font(.caption).monospacedDigit()
                }
            }
            if let status, !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if let completed = progress.completed, let total = progress.total {
                Text("\(completed) of \(total) completed").font(.caption).foregroundStyle(.secondary)
            }
            if let startedAt {
                OperationElapsedTimeView(startedAt: startedAt, estimatedRemaining: estimatedRemaining)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        // No custom progress animation; native controls respect platform settings.
    }
}
