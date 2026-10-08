#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

struct ExportSheetView: View {
    @Environment(\.dismiss) private var dismiss
    let recording: Recording

    @State private var options = ExportOptions()
    @State private var model = ExportViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("Format") {
                    Picker("File Format", selection: $options.format) {
                        ForEach(ExportFormat.allCases) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Content to Include") {
                    Toggle("Sources", isOn: $options.includeSources)
                    Toggle("Metadata (Date, Duration, Source File)", isOn: $options.includeMetadata)
                    Toggle("Include AI generation metadata", isOn: $options.includeAIGenerationMetadata)

                    Toggle("AI Summary", isOn: $options.includeSummary)
                        .disabled(recording.summary == nil)

                    Toggle("Transcript", isOn: $options.includeTranscript)
                        .disabled(recording.transcript == nil)

                    Toggle("Chat History", isOn: $options.includeChat)
                        .disabled(recording.chatSessions.first?.messages.isEmpty ?? true)
                }

                Section("Formatting Options") {
                    Toggle("Include Timestamps", isOn: $options.includeTimestamps)
                    Toggle("Include Speaker Names", isOn: $options.includeSpeakers)

                    if options.format == .markdown {
                        Toggle("Include YAML Front Matter", isOn: $options.markdownFrontMatter)
                    }
                }

                if model.state == .exporting {
                    ProgressView(options.format == .pdf ? "Exporting PDF…" : "Exporting Markdown…")
                        .accessibilityLabel("Exporting recording")
                }
                if let errorMessage = model.errorMessage {
                    Section {
                        InlineErrorLabel(errorMessage, font: .callout)
                    }
                }
            }
            .disabled(model.isBusy)
            .formStyle(.grouped)
            .navigationTitle("Export Recording")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export…") {
                        performExport()
                    }
                    .disabled(!canExport || model.isBusy)
                }
            }
            .frame(minWidth: 440, minHeight: 380)
            .onChange(of: model.state) { _, state in if state == .completed { dismiss() } }
            .onDisappear { model.cancel() }
        }
    }

    private var canExport: Bool {
        options.includeSources || options.includeSummary || options.includeTranscript || options.includeChat || options.includeMetadata
    }

    private func performExport() {
        guard model.chooseDestination() else { return }
        let selectedOptions = options
        let format = selectedOptions.format

        let sanitizedTitle = recording.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultFileName = "\(sanitizedTitle).\(format.fileExtension)"

        let types = UTType(filenameExtension: format.fileExtension).map { [$0] } ?? []
        Task {
            guard let targetURL = await FilePanels.chooseSaveDestination(fileName: defaultFileName, types: types)
            else { model.cancel(); return }
            model.export(recording: recording, options: selectedOptions, to: targetURL)
        }
    }
}

#endif
