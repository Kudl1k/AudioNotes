import SwiftUI
import SwiftData

struct PresetsManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AIPreset.name, order: .forward) private var userPresets: [AIPreset]

    @State private var selectedTab: AIPresetFeature = .summary
    @State private var presetToEdit: AIPreset?
    @State private var presetToDelete: AIPreset?
    @State private var showCreateSheet: Bool = false
    @State private var showDeleteConfirmation: Bool = false

    var body: some View {
        Form {
#if os(iOS)
            Section { featurePicker }
#endif

            Section {
                let presets = userPresets.filter { $0.feature == selectedTab }
                if presets.isEmpty {
                    Text("No custom presets yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(presets) { preset in
                        presetRow(preset)
                    }
                }
            } header: {
#if os(macOS)
                HStack {
                    Text("My Presets")
                    Spacer()
                    newPresetButton
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("New Preset")
                }
#else
                Text("My Presets")
#endif
            }

            if selectedTab == .summary {
                Section("Built-in Presets") {
                    ForEach(SummaryPreset.allCases) { preset in
                        Label(preset.displayName, systemImage: preset.iconName)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .toolbar {
#if os(macOS)
            ToolbarItem(placement: .principal) {
                featurePicker
                    .fixedSize()
            }
#else
            ToolbarItem(placement: .primaryAction) {
                newPresetButton
            }
#endif
        }
        .sheet(item: $presetToEdit) { preset in
            PresetEditorView(existingPreset: preset, defaultFeature: selectedTab)
        }
        .sheet(isPresented: $showCreateSheet) {
            PresetEditorView(defaultFeature: selectedTab)
        }
        .confirmationDialog(
            "Delete Preset?",
            isPresented: $showDeleteConfirmation,
            presenting: presetToDelete
        ) { preset in
            Button("Delete '\(preset.name)'", role: .destructive) {
                delete(preset)
            }
            Button("Cancel", role: .cancel) {}
        } message: { preset in
            Text("Are you sure you want to delete '\(preset.name)'? This action cannot be undone.")
        }
    }

    private var featurePicker: some View {
        Picker("Feature", selection: $selectedTab) {
            Text("Summaries").tag(AIPresetFeature.summary)
            Text("Chat").tag(AIPresetFeature.chat)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var newPresetButton: some View {
        Button {
            showCreateSheet = true
        } label: {
            Label("New Preset", systemImage: "plus")
        }
        .keyboardShortcut("n", modifiers: .command)
    }

    private func presetRow(_ preset: AIPreset) -> some View {
        HStack {
            Button {
                presetToEdit = preset
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(preset.name)
                    if let base = preset.basePreset {
                        Text(base.displayName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let instructions = preset.userInstructions, !instructions.isEmpty {
                        Text(instructions)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the preset editor")

            Menu {
                Button("Edit", systemImage: "pencil") { presetToEdit = preset }
                Button("Duplicate", systemImage: "plus.square.on.square") { duplicate(preset) }
                Button("Delete", systemImage: "trash", role: .destructive) { confirmDeletion(of: preset) }
            } label: {
                Label("Actions for \(preset.name)", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
#if os(macOS)
            .menuStyle(.borderlessButton)
#endif
            .fixedSize()
        }
#if os(iOS)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", systemImage: "trash", role: .destructive) { confirmDeletion(of: preset) }
        }
#endif
    }

    private func confirmDeletion(of preset: AIPreset) {
        presetToDelete = preset
        showDeleteConfirmation = true
    }

    private func duplicate(_ preset: AIPreset) {
        let repo = AIPresetRepository(modelContext: modelContext)
        _ = try? repo.duplicatePreset(preset)
    }

    private func delete(_ preset: AIPreset) {
        let repo = AIPresetRepository(modelContext: modelContext)
        try? repo.deletePreset(preset)
    }
}
