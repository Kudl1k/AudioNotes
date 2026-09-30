import SwiftData
import SwiftUI

@main
struct AudioNotesApp: App {
    private let container: ModelContainer?
    private let startupError: String?

    init() {
        do {
            container = try LibraryStorage().makeContainer()
            startupError = nil
        } catch {
            container = nil
            startupError = error.localizedDescription
        }
    }

    var body: some Scene {
        WindowGroup("AudioNotes") {
            if let container {
                LibraryView()
                    .modelContainer(container)
                    .frame(minWidth: 760, minHeight: 500)
            } else {
                ContentUnavailableView {
                    Label("Library could not be opened", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(startupError ?? "An unknown storage error occurred.")
                    Text("Quit and reopen AudioNotes after checking access to Application Support.")
                }
                .frame(width: 550, height: 300)
            }
        }
        .defaultSize(width: 1100, height: 750)
        .commands { ImportCommands() }
    }
}

private struct ImportAudioKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var importAudio: (() -> Void)? {
        get { self[ImportAudioKey.self] }
        set { self[ImportAudioKey.self] = newValue }
    }
}

private struct ImportCommands: Commands {
    @FocusedValue(\.importAudio) private var importAudio

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Import Audio…") { importAudio?() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(importAudio == nil)
        }
    }
}
