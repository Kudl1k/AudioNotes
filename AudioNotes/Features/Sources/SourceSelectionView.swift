import SwiftUI

struct SourceSelectionView: View {
    let recording: Recording
    @Binding var selectedSourceIDs: Set<UUID>?
    @Binding var allowImageUpload: Bool
    let supportsImages: Bool
    @State private var expanded = false

    private var ready: [RecordingSource] { recording.sources.filter(\.isContextReady).sorted { $0.importedAt < $1.importedAt } }
    private var count: Int { selectedSourceIDs.map { ids in ready.filter { ids.contains($0.id) }.count } ?? ready.count }
    var body: some View {
        Button("Sources: \(selectedSourceIDs == nil ? "All " : "")\(count)", systemImage: "doc.on.doc") { expanded.toggle() }
            .accessibilityHint("Choose which sources the assistant can use")
            .accessibilityIdentifier("chat.sources")
            .popover(isPresented: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("AI context sources").font(.headline)
                    HStack {
                        Button("All ready") { selectedSourceIDs = nil }
                        Button("Transcript only") {
                            selectedSourceIDs = Set(ready.filter { $0.type == .audio }.map(\.id))
                        }
                    }
                    ForEach(ready) { source in
                        Toggle(isOn: Binding(get: { selectedSourceIDs?.contains(source.id) ?? true }, set: { enabled in
                            var ids = selectedSourceIDs ?? Set(ready.map(\.id))
                            if enabled { ids.insert(source.id) } else { ids.remove(source.id) }
                            selectedSourceIDs = ids
                        })) { Label(source.displayName, systemImage: source.type.icon).lineLimit(2) }
                    }
                    if ready.contains(where: { $0.type == .image }) {
                        Divider()
                        Toggle("Allow selected images to be sent to the AI provider", isOn: $allowImageUpload)
                            .disabled(!supportsImages)
                        Text(supportsImages
                            ? "Images are sent only when relevant, at most two per request. Otherwise the AI receives local OCR text."
                            : "This model uses OCR text only. It cannot inspect diagrams or visual structure.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Unavailable sources are excluded. Earlier answers using excluded sources are omitted from AI context; history stays visible.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding().frame(width: 340)
            }
    }
}

struct SourceReferenceChips: View {
    let references: [SourceReference]
    let onOpen: (SourceReference) -> Void
    @State private var expanded = false
    var body: some View {
        let groups = SourceReferencePresentation.groups(references)
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sources").font(.caption).foregroundStyle(.secondary)
                FlowLayout {
                    ForEach(expanded ? groups : Array(groups.prefix(5))) { group in
                        Button { onOpen(group.primary) } label: {
                            Label(group.label, systemImage: group.primary.sourceType.icon).font(.caption).lineLimit(1)
                        }.buttonStyle(.bordered).controlSize(.small).help(group.excerpt)
                            .accessibilityLabel("Open citation, \(group.label)")
                    }
                    if groups.count > 5 {
                        Button(expanded ? "Show fewer" : "+\(groups.count - 5) more") { expanded.toggle() }
                            .font(.caption).buttonStyle(.borderless)
                            .accessibilityLabel(expanded ? "Show fewer sources" : "Show \(groups.count - 5) more sources")
                    }
                }
            }
        }
    }
}
