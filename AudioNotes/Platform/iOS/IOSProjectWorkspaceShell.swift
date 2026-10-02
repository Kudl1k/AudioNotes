#if os(iOS)
import SwiftUI

struct IOSProjectWorkspaceShell: View {
    let project: Project

    var body: some View {
        List {
            headerSection
            recordingsSection
            sourcesSection
            chatPlaceholderSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(project.name)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)

                if let desc = project.projectDescription, !desc.isEmpty {
                    Text(desc)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Label("\(project.recordings.count) Recordings", systemImage: "waveform")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.15), in: Capsule())

                    Label("\(project.sources.count) Sources", systemImage: "paperclip")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.15), in: Capsule())

                    Label("Created \(project.createdAt.formatted(date: .abbreviated, time: .omitted))", systemImage: "calendar")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var recordingsSection: some View {
        Section(header: Label("Recordings", systemImage: "waveform")) {
            if project.recordings.isEmpty {
                Text("No recordings assigned to this project.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(project.recordings.sorted(by: { $0.importedAt > $1.importedAt })) { recording in
                    NavigationLink(destination: IOSRecordingDetailShell(recording: recording)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(recording.title)
                                .font(.body.weight(.medium))
                            Text("\(AudioTime.format(recording.duration)) • \(recording.importedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var sourcesSection: some View {
        Section(header: Label("Sources", systemImage: "paperclip")) {
            if project.sources.isEmpty {
                Text("No sources added to this project.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(project.sources) { source in
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
        Section(header: Label("Project Chat", systemImage: "bubble.left.and.bubble.right")) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Synthesize answers across all project materials")
                    .font(.subheadline.weight(.medium))
                Text("Cross-recording search, source grounding, and multi-turn project chat workspace.")
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
