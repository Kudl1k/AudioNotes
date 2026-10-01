import SwiftUI
import AppKit

struct LibraryRecoveryView: View {
    let startup: LibraryStartup
    var body: some View {
        ContentUnavailableView {
            Label("Library could not be opened", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text("Your original library has been preserved. Check available disk space and folder access, then retry. Do not delete the database. Metadata backups are in AudioNotes/Backups inside the data folder; they do not include audio or documents.")
        } actions: {
            Button("Retry") { startup.retry() }
            Button("Open Data Folder") { NSWorkspace.shared.open(startup.support) }
            Button("Open Backup Location") {
                // Reveal an existing parent without creating or replacing any user files.
                let url = FileManager.default.fileExists(atPath: startup.backups.path) ? startup.backups : startup.support
                NSWorkspace.shared.open(url)
            }
        }.frame(minWidth: 760, minHeight: 500)
    }
}
