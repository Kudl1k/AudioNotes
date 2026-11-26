import SwiftUI

struct DriveConflictResolutionSheet: View {
    let conflicts: [DriveProjectSync.Conflict]
    let onApply: ([DriveProjectSync.Resolution]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var choices: [String: DriveProjectSync.Choice] = [:]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(conflicts) { conflict in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: conflict.key.hasPrefix("r-") ? "waveform" : "doc.text")
                                    .foregroundStyle(.orange)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(conflict.local.name)
                                        .font(.headline)
                                        .lineLimit(2)
                                    if conflict.drive.name != conflict.local.name {
                                        Text("Drive file: \(conflict.drive.name)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    } else {
                                        Text(conflict.canDownload
                                             ? "Modified locally and in Google Drive"
                                             : "Local and Drive copies differ")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Picker("Action for \(conflict.local.name)", selection: binding(for: conflict)) {
                                Text("Keep Both").tag(DriveProjectSync.Choice.both)
                                Text("Use Local").tag(DriveProjectSync.Choice.local)
                                if conflict.canDownload {
                                    Text("Use Drive").tag(DriveProjectSync.Choice.drive)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            choiceCaption(for: effectiveChoice(for: conflict), canDownload: conflict.canDownload)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
#if os(macOS)
                    HStack {
                        Text("Conflicting Files (\(conflicts.count))")
                        Spacer()
                        if conflicts.count > 1 {
                            setAllMenu
                                .controlSize(.small)
                        }
                    }
#else
                    Text("Conflicting Files (\(conflicts.count))")
#endif
                } footer: {
                    Text(planSummary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Resolve Conflicts")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { dismiss() }
                }
#if os(iOS)
                if conflicts.count > 1 {
                    ToolbarItem(placement: .secondaryAction) {
                        setAllMenu
                    }
                }
#endif
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(conflicts.map { .init(conflict: $0, choice: effectiveChoice(for: $0)) })
                    }
                    .disabled(conflicts.isEmpty)
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 520, idealWidth: 540, minHeight: 470, idealHeight: 500)
#endif
    }

    private func effectiveChoice(for conflict: DriveProjectSync.Conflict) -> DriveProjectSync.Choice {
        let chosen = choices[conflict.id] ?? .both
        if chosen == .drive && !conflict.canDownload { return .both }
        return chosen
    }

    private func binding(for conflict: DriveProjectSync.Conflict) -> Binding<DriveProjectSync.Choice> {
        Binding(
            get: { effectiveChoice(for: conflict) },
            set: { choices[conflict.id] = $0 }
        )
    }

    private var setAllMenu: some View {
        Menu("Set All", systemImage: "checklist") {
            Button("Keep Both for All") { setAll(.both) }
            Button("Overwrite Drive for All (Use Local)") { setAll(.local) }
            if conflicts.contains(where: \.canDownload) {
                Button("Overwrite Local for All (Use Drive)") { setAll(.drive) }
            }
        }
    }

    private func setAll(_ choice: DriveProjectSync.Choice) {
        for conflict in conflicts {
            choices[conflict.id] = (choice == .drive && !conflict.canDownload) ? .both : choice
        }
    }

    @ViewBuilder
    private func choiceCaption(for choice: DriveProjectSync.Choice, canDownload: Bool) -> some View {
        switch choice {
        case .both:
            Label(canDownload
                  ? "Keeps the Drive file and saves a separate Local Conflict Copy."
                  : "Keeps the Drive file and saves a separate Local Conflict Copy (Drive download unavailable).",
                  systemImage: "doc.on.doc")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .local:
            Label("Overwrites the Google Drive file with your local version.", systemImage: "arrow.up.doc")
                .font(.caption)
                .foregroundStyle(.orange)
        case .drive:
            Label("Overwrites your local transcript with the Google Drive version.", systemImage: "arrow.down.doc")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var planSummary: String {
        let resolved = conflicts.map(effectiveChoice)
        let bothCount = resolved.filter { $0 == .both }.count
        let localCount = resolved.filter { $0 == .local }.count
        let driveCount = resolved.filter { $0 == .drive }.count
        var parts: [String] = []
        if bothCount > 0 { parts.append("\(bothCount) keep both") }
        if localCount > 0 { parts.append("\(localCount) overwrite Drive") }
        if driveCount > 0 { parts.append("\(driveCount) overwrite local") }
        return parts.isEmpty ? "" : "Selected actions: " + parts.joined(separator: " · ") + "."
    }
}
