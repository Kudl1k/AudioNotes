import SwiftData
import SwiftUI

struct SummaryView: View {
    let recording: Recording
    @Bindable var model: SummaryViewModel
    let onSeek: (TimeInterval) -> Void
    var onOpenSource: (SourceReference) -> Void = { _ in }
    @Environment(\.modelContext) private var modelContext
    @State private var showsRegenerateOptions = false
#if os(iOS)
    @State private var showingIOSConfiguration = false
#endif
    @State private var showingSavePreset = false
    @State private var showingManagePresets = false
    @State private var showingHistory = false
    @State private var historicalSummary: Summary?

    @Query(sort: \AIPreset.name, order: .forward) private var allUserPresets: [AIPreset]

    private var userSummaryPresets: [AIPreset] {
        allUserPresets.filter { $0.feature == .summary }
    }

    var body: some View {
        Group {
            if !model.hasReadySources && recording.summary == nil {
                ContentUnavailableView(
                "No ready sources",
                systemImage: "text.bubble",
                description: Text("Transcribe audio or add documents and images in Sources to generate a summary.")
            )
            } else if let summary = historicalSummary ?? recording.summary {
                summaryContent(summary)
            } else {
                emptyStateGenerator
            }
        }
        .sheet(isPresented: $showingHistory) {
            SummaryHistorySheet(recording: recording, model: model, repository: repository) { historicalSummary = $0 }
#if os(macOS)
                .frame(minWidth: 440, minHeight: 360)
#endif
        }
        // While the history sheet is open, it presents its own version errors.
        .alert("Summary history", isPresented: Binding(get: { model.historyError != nil && !showingHistory },
                                                       set: { if !$0 { model.historyError = nil } })) {
            Button("OK", role: .cancel) { model.historyError = nil }
        } message: { Text(model.historyError ?? "") }
    }

    private var repository: SwiftDataSummaryRepository { SwiftDataSummaryRepository(context: modelContext) }

    private var emptyStateGenerator: some View {
        ScrollView {
            Group {
#if os(iOS)
                iosGenerator
#else
                generatorForm
#endif
            }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, generatorHorizontalPadding)
                .padding(.vertical, generatorVerticalPadding)
        }
        .sheet(isPresented: $showingSavePreset) {
            PresetEditorView(
                defaultFeature: .summary,
                initialSettings: model.generationSettings,
                initialInstructions: model.customInstructions
            ) { created in
                model.applyUserPreset(created)
            }
        }
        .sheet(isPresented: $showingManagePresets) {
            PresetsManagementView()
#if os(macOS)
                .frame(minWidth: 500, minHeight: 400)
#endif
        }
    }

#if os(iOS)
    private var iosGenerator: some View {
        IOSCreationPrompt(title: "Create Summary", symbol: "doc.text",
            description: "Generate structured notes from this recording's transcript.") {
            Text(model.providerName + " · " + (model.selectedUserPreset?.name ?? model.selectedPreset.title))
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Change") { showingIOSConfiguration = true }.accessibilityIdentifier("summary.configure")
            if model.state.isGenerating { summaryProgress }
            else {
                Button("Generate Summary", action: startGeneration)
                    .modifier(IOSPrimaryAction()).disabled(!model.canGenerate)
                    .accessibilityIdentifier("summary.generate")
            }
        }
        .sheet(isPresented: $showingIOSConfiguration) {
            NavigationStack {
                Form {
                    Section("Sources") { sourceSelection }
                    Section("Provider") { SummaryProviderControls(model: model) }
                    Section("Summary") {
                        presetMenu
                        Picker("Length", selection: $model.outputLength) {
                            ForEach(OutputLength.allCases) { Text($0.title).tag($0) }
                        }
                        if model.selectedPreset == .custom {
                            TextField("Custom instructions", text: $model.customInstructions, axis: .vertical)
                            Button("Save as Preset") { showingSavePreset = true }
                        }
                    }
                    Section {
                        DisclosureGroup("Advanced") {
                            Text("Advanced generation parameters are saved with custom presets. Unsupported parameters are filtered by the provider.")
                                .foregroundStyle(.secondary)
                            Button("Manage Presets") { showingManagePresets = true }
                        }
                    }
                }
                    .navigationTitle("Summary Settings").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingIOSConfiguration = false } } }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
#endif

    // Keep the form's natural height independent of the TabView's available
    // height. Native controls must not be compressed to fit a short detail pane.
    private var generatorForm: some View {
        VStack(spacing: WorkspaceSpacing.section) {
            Text("No summary yet")
                .font(.title2.bold())
            Text("Select a summary preset to generate a structured analysis of the transcript.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            VStack(alignment: .leading, spacing: 12) {
                sourceSelection
                SummaryProviderControls(model: model)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Preset:")
                        .font(.headline)
                    presetMenu
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Length:").font(.headline)
                    Picker("Output length", selection: $model.outputLength) {
                        ForEach(OutputLength.allCases) { length in Text(length.title).tag(length) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 0, maxWidth: .infinity)
                }

                if model.selectedPreset == .custom {
                    TextField("Enter custom summary instructions…", text: $model.customInstructions, axis: .vertical)
                        .lineLimit(3...5)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Spacer()
                        Button("Save as Preset…") {
                            showingSavePreset = true
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.isMockProvider ? "Provider: Mock (development)" : "Provider: \(model.providerName)")
                        Text(model.executionDescription)
                        if let estimate = model.costEstimate { Text(estimate.displayText).help("A budget range based on approximate input size, possible caching, and the configured output ceiling. Actual usage may differ.") }
                    }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.state.isGenerating {
                        summaryProgress
                    } else {
                        HStack {
                            Spacer(minLength: 0)
                            Button("Generate Summary") {
                                startGeneration()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canGenerate)
                        }
                    }
                }
            }
            .padding(16)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: 500)

            if case .failed(let message) = model.state {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .accessibilityLabel("Summary failed: \(message)")
                    .padding(.horizontal)
            }
        }
    }

    private var summaryProgress: some View {
        OperationProgressView(title: "Generating summary…", status: model.progressMessage,
            startedAt: model.operationStartedAt, cancel: model.cancelGeneration)
    }

    private var presetMenu: some View {
        Menu {
            Section("Built-in") {
                ForEach(SummaryPreset.allCases) { preset in
                    Button {
                        model.selectBuiltInPreset(preset)
                    } label: {
                        if model.selectedUserPreset == nil && model.selectedPreset == preset {
                            Label(preset.title, systemImage: "checkmark")
                        } else {
                            Label(preset.title, systemImage: preset.iconName)
                        }
                    }
                }
            }

            if !userSummaryPresets.isEmpty {
                Section("My Presets") {
                    ForEach(userSummaryPresets) { preset in
                        Button {
                            model.applyUserPreset(preset)
                        } label: {
                            if model.selectedUserPreset?.id == preset.id {
                                Label(preset.name, systemImage: "checkmark")
                            } else {
                                Text(preset.name)
                            }
                        }
                    }
                }
            }

            Divider()

            Button("Manage Presets…") {
                showingManagePresets = true
            }
        } label: {
            HStack(spacing: 4) {
                if let userPreset = model.selectedUserPreset {
                    Text(userPreset.name)
                } else {
                    Label(model.selectedPreset.title, systemImage: model.selectedPreset.iconName)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
    }

    private var summaryHeaderLayout: AnyLayout {
#if os(iOS)
        AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
#else
        AnyLayout(HStackLayout(alignment: .center))
#endif
    }

    private func summaryContent(_ summary: Summary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: contentSectionSpacing) {
                // Version controls recede so the notes begin near the content selector.
#if os(iOS)
                iosSummaryHeader(summary)
#else
                summaryHeaderLayout {
                    if historicalSummary != nil {
                        Text("Historical version").font(.caption.bold()).foregroundStyle(.orange)
                    }
                    Label(summary.preset.title, systemImage: summary.preset.iconName)
                        .font(.headline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.tint.opacity(0.12), in: Capsule())
                        .foregroundStyle(.tint)

                    Text(summary.createdAt, format: .dateTime.month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !summary.providerName.isEmpty {
                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        GenerationCostLabel(generationID: summary.generationID)
                        Text(summary.providerName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if historicalSummary != nil {
                        Button("Make Current") {
                            if model.makeCurrent(summary, using: repository) { historicalSummary = nil }
                        }
                    }
                    Button("History") { showingHistory = true }

                    if !model.state.isGenerating {
                        Button {
                            showsRegenerateOptions.toggle()
                        } label: {
                            Label("Regenerate…", systemImage: "arrow.clockwise")
                        }
                        .controlSize(.small)
#if os(iOS)
                        .sheet(isPresented: $showsRegenerateOptions) {
                            NavigationStack {
                                ScrollView { regeneratePopover }
                                    .navigationTitle("Summary Settings").navigationBarTitleDisplayMode(.inline)
                            }
                        }
#else
                        .popover(isPresented: $showsRegenerateOptions) { regeneratePopover }
#endif
                    }
                }

#endif
                if model.state.isGenerating { summaryProgress }

                SourceReferenceChips(references: SourceReferenceResolver().validate(summary.sourceReferences, recording: recording), onOpen: onOpenSource)

                if !summary.title.isEmpty {
                    Text(summary.title)
                        .font(.title2.bold())
                        .textSelection(.enabled)
                }

                // Overview
                if !summary.overview.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Overview")
                            .font(.title3.bold()).accessibilityAddTraits(.isHeader)
#if os(iOS)
                        IOSSummaryOverviewView(text: summary.overview)
#else
                        Text(summary.overview)
                            .textSelection(.enabled)
                            .lineSpacing(3)
#endif
                    }
                }

                // Key Points
                if !summary.keyPoints.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Key Points")
                            .font(.title3.bold()).accessibilityAddTraits(.isHeader)
                        ForEach(summary.keyPoints) { point in
                            HStack(alignment: .top, spacing: 8) {
                                Text("•")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                Text(point.text)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                // Decisions
                if !summary.decisions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Decisions")
                            .font(.title3.bold()).accessibilityAddTraits(.isHeader)
                        ForEach(summary.decisions) { decision in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .padding(.top, 2).accessibilityHidden(true)
                                Text(decision.text)
                                    .textSelection(.enabled)
                                Spacer()
                                if let ts = decision.timestamp {
                                    SummaryTimestampButton(timestamp: ts) { onSeek(ts) }
                                }
                            }
                            .modifier(SummaryItemSurface())
                        }
                    }
                }

                // Action Items
                if !summary.actionItems.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Action Items")
                            .font(.title3.bold()).accessibilityAddTraits(.isHeader)
                        ForEach(summary.actionItems) { item in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "square")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 2).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.text)
                                        .textSelection(.enabled)
                                    HStack(spacing: 8) {
                                        if let assignee = item.assignee, !assignee.isEmpty {
                                            Label(assignee, systemImage: "person.circle")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        if let due = item.dueDate, !due.isEmpty {
                                            Label(due, systemImage: "calendar")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                Spacer()
                                if let ts = item.timestamp {
                                    SummaryTimestampButton(timestamp: ts) { onSeek(ts) }
                                }
                            }
                            .modifier(SummaryItemSurface())
                        }
                    }
                }

                // Open Questions
                if !summary.openQuestions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Open Questions")
                            .font(.title3.bold()).accessibilityAddTraits(.isHeader)
                        ForEach(summary.openQuestions) { question in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "questionmark.circle")
                                    .foregroundStyle(.orange)
                                    .padding(.top, 2).accessibilityHidden(true)
                                Text(question.text)
                                    .textSelection(.enabled)
                                Spacer()
                                if let ts = question.timestamp {
                                    SummaryTimestampButton(timestamp: ts) { onSeek(ts) }
                                }
                            }
                            .modifier(SummaryItemSurface())
                        }
                    }
                }

                // Important Quotes
                if !summary.importantQuotes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Important Quotes")
                            .font(.title3.bold()).accessibilityAddTraits(.isHeader)
                        ForEach(summary.importantQuotes) { quote in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .top) {
                                    Text("“\(quote.text)”")
                                        .italic()
                                        .textSelection(.enabled)
                                    Spacer()
                                    if let ts = quote.timestamp {
                                        SummaryTimestampButton(timestamp: ts) { onSeek(ts) }
                                    }
                                }
                                if let speaker = quote.speaker, !speaker.isEmpty {
                                    Text("— \(speaker)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .modifier(SummaryItemSurface(isQuote: true))
                        }
                    }
                }

                // Additional Sections
                ForEach(summary.additionalSections) { section in
                    if !section.items.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title)
                                .font(.title3.bold()).accessibilityAddTraits(.isHeader)
                            ForEach(section.items, id: \.self) { item in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("•")
                                        .font(.headline)
                                        .foregroundStyle(.secondary)
                                    Text(item)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, contentPadding)
            .padding(.vertical, contentVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var generatorHorizontalPadding: CGFloat {
#if os(iOS)
        0
#else
        WorkspaceSpacing.majorSection
#endif
    }
    private var generatorVerticalPadding: CGFloat {
#if os(iOS)
        8
#else
        WorkspaceSpacing.majorSection
#endif
    }
    private var contentVerticalPadding: CGFloat {
#if os(iOS)
        8
#else
        20
#endif
    }
    private var contentPadding: CGFloat {
#if os(iOS)
        0 // The detail shell owns the reading margin.
#else
        20
#endif
    }
    private var contentSectionSpacing: CGFloat {
#if os(iOS)
        12
#else
        20
#endif
    }

#if os(iOS)
    private func iosSummaryHeader(_ summary: Summary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Label(summary.preset.title, systemImage: summary.preset.iconName)
                    Spacer(minLength: 8)
                    summaryVersionMenu(summary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Label(summary.preset.title, systemImage: summary.preset.iconName)
                    summaryVersionMenu(summary)
                }
            }
            HStack(spacing: 4) {
                Text(summary.createdAt, format: .dateTime.month().day().hour().minute())
                if !summary.providerName.isEmpty { Text("· " + summary.providerName) }
                GenerationCostLabel(generationID: summary.generationID)
            }
            .font(.caption).foregroundStyle(.secondary)
            if historicalSummary != nil { Text("Historical version").font(.caption).foregroundStyle(.secondary) }
        }
        .font(.subheadline)
    }

    private func summaryVersionMenu(_ summary: Summary) -> some View {
        Menu {
            Button("History") { showingHistory = true }
            if historicalSummary != nil {
                Button("Make Current") {
                    if model.makeCurrent(summary, using: repository) { historicalSummary = nil }
                }
            }
            if !model.state.isGenerating {
                Button("Regenerate…", systemImage: "arrow.clockwise") { showsRegenerateOptions = true }
            }
        } label: {
            Label("Versions", systemImage: "clock.arrow.circlepath").padding(.vertical, 8)
        }
        .sheet(isPresented: $showsRegenerateOptions) {
            NavigationStack {
                Form {
                    Section("Sources") { sourceSelection }
                    Section("Provider") { SummaryProviderControls(model: model) }
                    Section("Summary") {
                        presetMenu
                        Picker("Length", selection: $model.outputLength) {
                            ForEach(OutputLength.allCases) { Text($0.title).tag($0) }
                        }
                        if model.selectedPreset == .custom {
                            TextField("Custom instructions…", text: $model.customInstructions, axis: .vertical)
                        }
                    }
                    Section {
                        Button("Regenerate") { showsRegenerateOptions = false; startGeneration() }
                            .disabled(!model.canGenerate)
                    }
                }
                .navigationTitle("Summary Settings").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showsRegenerateOptions = false } } }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
#endif

    private var sourceSelection: some View {
        SourceSelectionView(recording: recording, selectedSourceIDs: $model.selectedSourceIDs,
            allowImageUpload: $model.allowImageUpload, supportsImages: model.supportsImageInput)
            .disabled(model.state.isGenerating)
    }

    private var regeneratePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            sourceSelection
            Text("Regenerate Summary")
                .font(.headline)
            presetMenu
            SummaryProviderControls(model: model)
            Picker("Length", selection: $model.outputLength) {
                ForEach(OutputLength.allCases) { length in Text(length.title).tag(length) }
            }
            if model.selectedPreset == .custom {
                TextField("Custom instructions…", text: $model.customInstructions, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Button("Cancel") { showsRegenerateOptions = false }
                Spacer()
                Button("Regenerate") {
                    showsRegenerateOptions = false
                    startGeneration()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canGenerate)
            }
        }
        .padding(16)
#if os(macOS)
        .frame(width: 320)
#endif
    }

    private func startGeneration() {
        model.generateSummary(using: repository)
    }
}

private struct SummaryHistorySheet: View {
    let recording: Recording
    let model: SummaryViewModel
    let repository: any SummaryStoring
    let select: (Summary) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var deleteCandidate: Summary?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Summary History").font(.title2.bold())
            List(([recording.summary].compactMap { $0 } + recording.summaryHistory).sorted { $0.createdAt > $1.createdAt }) { version in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        if !version.title.isEmpty { Text(version.title).font(.headline) }
                        Text("\(version.preset.title) · \(version.providerName.isEmpty ? "Unknown provider" : version.providerName)")
                        Text("\(version.outputLength.title) · \(version.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        GenerationCostLabel(generationID: version.generationID, details: true)
                        if recording.summary?.id == version.id { Text("Current").font(.caption2).foregroundStyle(.tint) }
                    }
                    Spacer()
                    Button("View") { select(version); dismiss() }
                    if recording.summary?.id != version.id {
                        Button(role: .destructive) { deleteCandidate = version } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Delete Version")
                    }
                }
                .padding(.vertical, 4)
            }
            HStack { Spacer(); Button("Done") { dismiss() } }
        }
        .padding()
        .confirmationDialog("Delete this summary version?", isPresented: Binding(
            get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }
        ), titleVisibility: .visible) {
            Button("Delete Version", role: .destructive) {
                guard let candidate = deleteCandidate else { return }
                model.deleteVersion(candidate, using: repository)
                deleteCandidate = nil
            }
        } message: { Text("This cannot be undone.") }
        .alert("Summary history", isPresented: Binding(get: { model.historyError != nil },
                                                       set: { if !$0 { model.historyError = nil } })) {
            Button("OK", role: .cancel) { model.historyError = nil }
        } message: { Text(model.historyError ?? "") }
    }
}

private struct SummaryTimestampButton: View {
    let timestamp: TimeInterval
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(AudioTime.format(timestamp))
                .font(.caption.monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Seek audio to \(AudioTime.format(timestamp))")
        .help("Jump to \(AudioTime.format(timestamp)) in audio")
    }
}

/// iOS content remains flat; preserve the established desktop summary presentation.
private struct SummaryItemSurface: ViewModifier {
    var isQuote = false
    func body(content: Content) -> some View {
#if os(iOS)
        content.padding(.vertical, 4)
#else
        if isQuote {
            content.padding(12).background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        } else {
            content.padding(10).background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        }
#endif
    }
}
