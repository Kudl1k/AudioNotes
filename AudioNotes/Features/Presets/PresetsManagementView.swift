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
#if os(iOS)
            Picker("Feature", selection: $selectedTab) {
                Text("Summary").tag(AIPresetFeature.summary)
                Text("Chat").tag(AIPresetFeature.chat)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
#else
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

#endif
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
#if os(iOS)
                        Button {
                            showCreateSheet = true
                        } label: {
                            Label("New Preset", systemImage: "plus")
                        }
#endif
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

#if os(iOS)
                                Spacer()
                                Menu {
                                    Button("Edit", systemImage: "pencil") { presetToEdit = preset }
                                    Button("Duplicate", systemImage: "plus.square.on.square") { duplicate(preset) }
                                    Button("Delete", systemImage: "trash", role: .destructive) { presetToDelete = preset; showDeleteConfirmation = true }
                                } label: { Label("Preset actions", systemImage: "ellipsis.circle").labelStyle(.iconOnly) }
#else
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
#endif
                            }
                            .padding(.vertical, 4)
#if os(iOS)
                            .swipeActions(edge: .trailing) {
                                Button("Delete", role: .destructive) {
                                    presetToDelete = preset
                                    showDeleteConfirmation = true
                                }
                                Button("Edit") {
                                    presetToEdit = preset
                                }
                                .tint(.blue)
                            }
#endif
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
#if os(macOS)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
#endif
        }
#if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreateSheet = true
                } label: {
                    Label("New Preset", systemImage: "plus")
                }
            }
        }
#endif
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
