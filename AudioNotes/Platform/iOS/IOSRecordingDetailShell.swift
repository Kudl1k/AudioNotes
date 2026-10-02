#if os(iOS)
import SwiftUI

struct IOSRecordingDetailShell: View {
    let recording: Recording

    var body: some View {
        List {
            headerSection
            transcriptSection
            summarySection
            sourcesSection
            chatPlaceholderSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(recording.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(recording.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)

                HStack(spacing: 8) {
                    Label(AudioTime.format(recording.duration), systemImage: "clock")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.15), in: Capsule())

                    Label(recording.importedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.15), in: Capsule())

                    if let project = recording.project {
                        Label(project.name, systemImage: "folder")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }

                Text("File: \(recording.originalFileName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var transcriptSection: some View {
        Section(header: Label("Transcript", systemImage: "waveform")) {
            if let transcript = recording.transcript {
                VStack(alignment: .leading, spacing: 6) {
                    if let sourceName = transcript.sourceName {
                        Text(sourceName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(transcript.segments.count) segments recorded")
                        .font(.subheadline)
                    if let firstSegment = transcript.segments.sorted(by: { $0.position < $1.position }).first {
                        Text(firstSegment.text)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                .padding(.vertical, 2)
            } else {
                ContentUnavailableView(
                    "No Transcript",
                    systemImage: "waveform.slash",
                    description: Text("This recording does not have a transcript yet.")
                )
                .padding(.vertical, 8)
            }
        }
    }

    private var summarySection: some View {
        Section(header: Label("Summary", systemImage: "doc.plaintext")) {
            if let summary = recording.summary {
                VStack(alignment: .leading, spacing: 6) {
                    if !summary.title.isEmpty {
                        Text(summary.title)
                            .font(.headline)
                    }
                    if !summary.overview.isEmpty {
                        Text(summary.overview)
                            .font(.body)
                            .lineLimit(4)
                    }
                    HStack(spacing: 12) {
                        if !summary.keyPoints.isEmpty {
                            Label("\(summary.keyPoints.count) key points", systemImage: "list.bullet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !summary.actionItems.isEmpty {
                            Label("\(summary.actionItems.count) actions", systemImage: "checklist")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 2)
            } else {
                ContentUnavailableView(
                    "No Summary",
                    systemImage: "doc.badge.ellipsis",
                    description: Text("No AI summary generated for this recording yet.")
                )
                .padding(.vertical, 8)
            }
        }
    }

    private var sourcesSection: some View {
        Section(header: Label("Sources", systemImage: "paperclip")) {
            if recording.sources.isEmpty {
                Text("No attached sources")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recording.sources) { source in
                    HStack {
                        Image(systemName: sourceIconName(for: source))
                            .foregroundStyle(Color.accentColor)
                        Text(source.displayName)
                            .font(.body)
                    }
                }
            }
        }
    }

    private var chatPlaceholderSection: some View {
        Section(header: Label("Chat", systemImage: "bubble.left.and.bubble.right")) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ask questions about this recording")
                    .font(.subheadline.weight(.medium))
                Text("Chat integration will connect grounded Q&A with transcript and source citations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private func sourceIconName(for source: RecordingSource) -> String {
        switch source.type {
        case .pdf: return "doc.text"
        case .image: return "photo"
        case .document: return "doc"
        case .audio: return "waveform"
        }
    }
}
#endif
