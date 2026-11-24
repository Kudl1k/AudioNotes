#if os(iOS)
import SwiftUI

/// OpenAI API key management for iOS. The key enables OpenAI API transcription
/// (`/audio/transcriptions`) plus API-key summaries and chat. It is independent of
/// the ChatGPT plan account, whose token is never sent to the transcription endpoint.
struct IOSOpenAIAPIKeyView: View {
    @ObservedObject var settings: ProviderSettingsViewModel
    var isOfflineReview = false
    /// Called after a key was saved so the caller can make OpenAI the transcription default when needed.
    var onKeySaved: () -> Void = {}

    @State private var isEditing = false
    @State private var isRevealed = false
    @State private var showingRemoveConfirmation = false
    @State private var savedFeedback = 0
    @FocusState private var fieldFocused: Bool

    private static let keysURL = URL(string: "https://platform.openai.com/api-keys")!

    private var trimmedInput: String { settings.keyInput.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var showsEntry: Bool { !settings.keyIsConfigured || isEditing }
    private var looksUnusual: Bool { !trimmedInput.isEmpty && !trimmedInput.hasPrefix("sk-") }
    private var canSave: Bool { !trimmedInput.isEmpty && !settings.isBusy }

    var body: some View {
        Form {
            header
            if showsEntry { entrySections } else { configuredSections }
        }
        .navigationTitle("OpenAI API Key")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.default, value: showsEntry)
        .animation(.default, value: settings.keyIsConfigured)
        .sensoryFeedback(.success, trigger: savedFeedback)
        .onDisappear { if isEditing || !settings.keyIsConfigured { settings.keyInput = "" } }
        .confirmationDialog("Remove OpenAI API Key?", isPresented: $showingRemoveConfirmation, titleVisibility: .visible) {
            Button("Remove API Key", role: .destructive) {
                guard !isOfflineReview else { return }
                Task { await settings.removeKey() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("OpenAI transcription, summaries and chat with an API key will stop working until you add a key again.")
        }
    }

    // MARK: - Header

    private var header: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityHidden(true)
                VStack(spacing: 4) {
                    Text("OpenAI Transcription").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                    Text("Transcribe recordings with Whisper and GPT-4o Transcribe. Billed to your OpenAI API account, separately from ChatGPT plans.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                statusBadge
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 4, trailing: 16))
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: settings.keyIsConfigured ? "checkmark.circle.fill" : "circle.dashed")
                .contentTransition(.symbolEffect(.replace))
            Text(settings.keyIsConfigured ? "Ready" : "Not Set Up")
        }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(settings.keyIsConfigured ? Color.green : Color.secondary)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background((settings.keyIsConfigured ? Color.green : Color.secondary).opacity(0.12), in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.openai.status")
    }

    // MARK: - Configured

    @ViewBuilder private var configuredSections: some View {
        Section {
            LabeledContent {
                Text(verbatim: "••••••••••••").font(.body.monospaced()).foregroundStyle(.secondary)
            } label: {
                Label("API Key", systemImage: "lock.fill")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("API key stored")
            Button {
                settings.keyInput = ""
                isRevealed = false
                isEditing = true
                fieldFocused = true
            } label: {
                Label("Replace Key", systemImage: "arrow.triangle.2.circlepath")
            }
            .accessibilityIdentifier("settings.openai.replace")
        } footer: {
            Text("Stored only on this device in the iOS Keychain. Soniquill never shows or logs the key.")
        }

        Section {
            Link(destination: Self.keysURL) {
                Label("Manage Keys on OpenAI", systemImage: "arrow.up.right.square")
            }
        }

        Section {
            Button(role: .destructive) { showingRemoveConfirmation = true } label: {
                Label("Remove Key", systemImage: "trash")
            }
            .disabled(settings.isBusy)
            .accessibilityIdentifier("settings.openai.remove")
        }
    }

    // MARK: - Entry

    @ViewBuilder private var entrySections: some View {
        Section {
            HStack(spacing: 10) {
                Group {
                    if isRevealed {
                        TextField("sk-…", text: $settings.keyInput)
                    } else {
                        SecureField("sk-…", text: $settings.keyInput)
                    }
                }
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.password)
                .submitLabel(.done)
                .focused($fieldFocused)
                .onSubmit(save)
                .disabled(settings.isBusy)
                .accessibilityLabel("OpenAI API key")
                .accessibilityIdentifier("settings.openai.key")

                if trimmedInput.isEmpty {
                    PasteButton(payloadType: String.self) { strings in
                        guard let value = strings.first else { return }
                        Task { @MainActor in settings.keyInput = value.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .accessibilityIdentifier("settings.openai.paste")
                } else {
                    Button { isRevealed.toggle() } label: {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isRevealed ? "Hide key" : "Show key")
                }
            }
        } header: {
            Text(settings.keyIsConfigured ? "New API Key" : "API Key")
        } footer: {
            if let error = settings.errorMessage {
                InlineErrorLabel(error, font: .footnote)
            } else if looksUnusual {
                Label("OpenAI keys usually start with “sk-”.", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            } else {
                Text("Stored only on this device in the iOS Keychain. Soniquill never shows or logs the key.")
            }
        }

        Section {
            Button(action: save) {
                HStack(spacing: 8) {
                    if settings.isBusy { ProgressView().tint(.white) }
                    Text(settings.keyIsConfigured ? "Replace Key" : "Save Key").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity, minHeight: 34)
            }
            .modifier(IOSPrimaryAction())
            .controlSize(.large)
            .disabled(!canSave)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .accessibilityIdentifier("settings.openai.save")

            if isEditing {
                Button("Cancel") {
                    settings.keyInput = ""
                    isEditing = false
                    fieldFocused = false
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
        }

        if !settings.keyIsConfigured {
            Section {
                Link(destination: Self.keysURL) {
                    Label("Create a Key on OpenAI", systemImage: "arrow.up.right.square")
                }
            } footer: {
                Text("Sign in at platform.openai.com, create a secret key, copy it and paste it above.")
            }
        }
    }

    // MARK: - Actions

    private func save() {
        guard canSave else { return }
        fieldFocused = false
        guard !isOfflineReview else { return }
        Task {
            await settings.saveKey()
            guard settings.keyIsConfigured, settings.errorMessage == nil else { return }
            isEditing = false
            isRevealed = false
            savedFeedback += 1
            onKeySaved()
            await settings.fetchVoiceModels()
        }
    }
}
#endif
