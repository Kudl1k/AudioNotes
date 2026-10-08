#if os(macOS)
import AppKit
import UniformTypeIdentifiers

/// Native macOS open/save panels. Features describe what to choose; AppKit stays here.
@MainActor
enum FilePanels {
    /// Returns the chosen files, or an empty array when the user cancels.
    static func chooseFiles(title: String, prompt: String? = nil, types: [UTType],
                            allowsMultipleSelection: Bool = true) async -> [URL] {
        let panel = NSOpenPanel()
        panel.title = title
        if let prompt { panel.prompt = prompt }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.canChooseDirectories = false
        guard await panel.begin() == .OK else { return [] }
        return panel.urls
    }

    /// Returns the chosen destination, or nil when the user cancels.
    static func chooseSaveDestination(fileName: String, types: [UTType], message: String? = nil,
                                      showsTagField: Bool = true) async -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.showsTagField = showsTagField
        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes = types
        if let message { panel.message = message }
        guard await panel.begin() == .OK else { return nil }
        return panel.url
    }
}
#endif
