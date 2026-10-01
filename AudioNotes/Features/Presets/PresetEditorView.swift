import SwiftUI
import SwiftData

struct PresetEditorView: View {
    @Environment(LocalAIConfiguration.self) private var localConfiguration: LocalAIConfiguration?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let existingPreset: AIPreset?
    let defaultFeature: AIPresetFeature
    let initialSettings: LLMGenerationSettings?
    let initialInstructions: String?
    let onSave: ((AIPreset) -> Void)?

    @State private var name: String
    @State private var feature: AIPresetFeature
    @State private var basePreset: SummaryPreset
    @State private var userInstructions: String
    @State private var selectedProvider: LLMProviderID?
    @State private var selectedModel: String
    @State private var maxTokens: String
    @State private var temperature: Double
    @State private var topP: Double
    @State private var reasoningEffort: ReasoningEffort
    @State private var outputLength: OutputLength
    @State private var showAdvanced: Bool = false
    @State private var errorMessage: String?

    init(
        existingPreset: AIPreset? = nil,
        defaultFeature: AIPresetFeature = .summary,
        initialSettings: LLMGenerationSettings? = nil,
        initialInstructions: String? = nil,
        onSave: ((AIPreset) -> Void)? = nil
    ) {
        self.existingPreset = existingPreset
        self.defaultFeature = defaultFeature
        self.initialSettings = initialSettings
        self.initialInstructions = initialInstructions
        self.onSave = onSave

        _name = State(initialValue: existingPreset?.name ?? "")
        _feature = State(initialValue: existingPreset?.feature ?? defaultFeature)
        _basePreset = State(initialValue: existingPreset?.basePreset ?? .meeting)
        _userInstructions = State(initialValue: existingPreset?.userInstructions ?? initialInstructions ?? "")
        _selectedProvider = State(initialValue: existingPreset?.provider)
        _selectedModel = State(initialValue: existingPreset?.model ?? "")

        let settings = existingPreset?.generationSettings ?? initialSettings
        _maxTokens = State(initialValue: settings?.maxOutputTokens.map(String.init) ?? "")
        _temperature = State(initialValue: settings?.temperature ?? 0.7)
        _topP = State(initialValue: settings?.topP ?? 1.0)
        _reasoningEffort = State(initialValue: settings?.reasoningEffort ?? .medium)
        _outputLength = State(initialValue: settings?.outputLength ?? .medium)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Preset Details") {
                    TextField("Preset Name", text: $name, prompt: Text("e.g. Action-Oriented Meeting"))

                    Picker("Feature", selection: $feature) {
                        Text("Summary").tag(AIPresetFeature.summary)
                        Text("Chat").tag(AIPresetFeature.chat)
                    }
                    .disabled(existingPreset != nil)

                    if feature == .summary {
                        Picker("Base Format", selection: $basePreset) {
                            ForEach(SummaryPreset.allCases) { preset in
                                Label(preset.displayName, systemImage: preset.iconName)
                                    .tag(preset)
                            }
                        }
                    }
                }

                Section("Instructions") {
                    Picker(feature == .summary ? "Summary length" : "Chat response length", selection: $outputLength) {
                        ForEach(OutputLength.allCases) { Text($0.title).tag($0) }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Custom Prompt Instructions")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $userInstructions)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 90)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                    }
                }

                DisclosureGroup(isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Provider Override", selection: $selectedProvider) {
                            Text("Use Default").tag(Optional<LLMProviderID>.none)
                            Text("OpenAI").tag(Optional(LLMProviderID.openAI))
                            Text("Mock Provider").tag(Optional(LLMProviderID.mock))
                            Text("Anthropic Claude").tag(Optional(LLMProviderID.anthropic))
                            Text("Google Gemini").tag(Optional(LLMProviderID.gemini))
                            Text("Ollama").tag(Optional(LLMProviderID.ollama))
                        }

                        if selectedProvider == .ollama, let localConfiguration {
                            OllamaModelPicker(title: "Model override", selection: $selectedModel, configuration: localConfiguration)
                        }
                        if selectedProvider == .openAI || selectedProvider == .anthropic || selectedProvider == .gemini {
                            TextField("Model Override (Optional)", text: $selectedModel, prompt: Text("e.g. gpt-4o, o3-mini"))
                        }

                        HStack {
                            Text("Max Output Tokens:")
                            TextField("Default", text: $maxTokens)
                                .frame(width: 90)
                        }

                        VStack(alignment: .leading) {
                            HStack {
                                Text("Temperature:")
                                Spacer()
                                Text(String(format: "%.2f", temperature))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $temperature, in: 0.0...2.0, step: 0.05)
                        }

                        VStack(alignment: .leading) {
                            HStack {
                                Text("Top P:")
                                Spacer()
                                Text(String(format: "%.2f", topP))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $topP, in: 0.0...1.0, step: 0.05)
                        }

                        Picker("Reasoning Effort (o1/o3):", selection: $reasoningEffort) {
                            ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                                Text(effort.rawValue.capitalized).tag(effort)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                } label: {
                    Text("Advanced Generation Settings")
                        .font(.headline)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(existingPreset == nil ? "New AI Preset" : "Edit AI Preset")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .frame(minWidth: 460, minHeight: 480)
        }
    }

    private func save() {
        let repo = AIPresetRepository(modelContext: modelContext)
        let parsedTokens = Int(maxTokens.trimmingCharacters(in: .whitespacesAndNewlines))
        let settings = LLMGenerationSettings(
            maxOutputTokens: parsedTokens,
            temperature: temperature,
            topP: topP,
            reasoningEffort: reasoningEffort,
            outputLength: outputLength
        )
        let modelString = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = userInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : userInstructions

        do {
            if let existing = existingPreset {
                try repo.updatePreset(
                    existing,
                    name: name,
                    systemInstructions: existing.systemInstructions,
                    userInstructions: instructions,
                    provider: selectedProvider,
                    model: modelString,
                    settings: settings
                )
                onSave?(existing)
            } else {
                let created = try repo.createPreset(
                    name: name,
                    feature: feature,
                    basePreset: feature == .summary ? basePreset : nil,
                    userInstructions: instructions,
                    provider: selectedProvider,
                    model: modelString,
                    settings: settings
                )
                onSave?(created)
            }
            dismiss()
        } catch {
            errorMessage = "Failed to save preset: \(error.localizedDescription)"
        }
    }
}
