#if os(iOS)
import SwiftUI

struct IOSSettingsView: View {
    let services: AppServices
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Generation Defaults")) {
                    Picker("Summary Provider", selection: Binding(
                        get: { services.llmConfiguration.summaryProvider },
                        set: { services.llmConfiguration.summaryProvider = $0 }
                    )) {
                        ForEach(LLMProviderID.selectable) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }

                    Picker("Chat Provider", selection: Binding(
                        get: { services.llmConfiguration.chatProvider },
                        set: { services.llmConfiguration.chatProvider = $0 }
                    )) {
                        ForEach(LLMProviderID.selectable) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }

                    Picker("Transcription Provider", selection: Binding(
                        get: { services.configuration.selectedProvider },
                        set: { services.configuration.selectedProvider = $0 }
                    )) {
                        ForEach(TranscriptionProviderID.selectable) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                }

                Section(header: Text("AI Providers")) {
                    providerRow(title: "OpenAI", systemImage: "sparkles", status: "Configurable")
                    providerRow(title: "Google Gemini", systemImage: "star", status: "Configurable")
                    providerRow(title: "Anthropic", systemImage: "text.bubble", status: "API Key")
                    providerRow(title: "Ollama (Local / Remote)", systemImage: "desktopcomputer", status: "Configurable")
                    providerRow(title: "Local Whisper", systemImage: "waveform", status: "On-Device")
                }

                Section(header: Text("About")) {
                    HStack {
                        Text("Application")
                        Spacer()
                        Text("AudioNotes").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Build")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Platform Shell")
                        Spacer()
                        Text("Native iOS & iPadOS").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func providerRow(title: String, systemImage: String, status: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(status)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
#endif
