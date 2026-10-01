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
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Picker("Feature", selection: $selectedTab) {
                    Text("Summary Presets").tag(AIPresetFeature.summary)
                    Text("Chat Presets").tag(AIPresetFeature.chat)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 340)

                Spacer(minLength: 16)

                Button {
                    showCreateSheet = true
                } label: {
                    Label("New Preset…", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("n", modifiers: .command)
                .fixedSize()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .fixedSize(horizontal: false, vertical: true)

            Form {
                Section("My Custom Presets") {
                    let filtered = userPresets.filter { $0.feature == selectedTab }
                    if filtered.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No custom presets yet")
                                .font(.headline)
                            Text("Choose New Preset to save your own instructions for \(selectedTab == .summary ? "summaries" : "chat").")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    } else {
                        ForEach(filtered) { preset in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(preset.name)
                                        .font(.headline)
                                    if let base = preset.basePreset {
                                        Text("Base: \(base.displayName)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let instructions = preset.userInstructions, !instructions.isEmpty {
                                        Text(instructions)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }

                                Spacer()

                                Button("Duplicate") {
                                    duplicate(preset)
                                }
                                .buttonStyle(.borderless)

                                Button("Edit") {
                                    presetToEdit = preset
                                }
                                .buttonStyle(.borderless)

                                Button("Delete", role: .destructive) {
                                    presetToDelete = preset
                                    showDeleteConfirmation = true
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.red)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                if selectedTab == .summary {
                    Section("Built-in Presets") {
                        ForEach(SummaryPreset.allCases) { preset in
                            HStack {
                                Label(preset.displayName, systemImage: preset.iconName)
                                    .font(.body)
                                Spacer()
                                Text("Built-in")
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
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

    private func duplicate(_ preset: AIPreset) {
        let repo = AIPresetRepository(modelContext: modelContext)
        _ = try? repo.duplicatePreset(preset)
    }

    private func delete(_ preset: AIPreset) {
        let repo = AIPresetRepository(modelContext: modelContext)
        try? repo.deletePreset(preset)
    }
}
