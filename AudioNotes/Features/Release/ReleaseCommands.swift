import SwiftUI

struct ReleaseCommands: Commands {
    @ObservedObject var updates: UpdateService
    let startup: LibraryStartup
    @State private var support = ReleaseSupportViewModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updates.checkForUpdates() }.disabled(!updates.canCheckForUpdates)
        }
        CommandGroup(replacing: .help) {
            Button("AudioNotes Help") { openInformation(.help) }
            Button("Privacy") { openInformation(.privacy) }
            Button("Third-Party Licenses") { openInformation(.licenses) }
            Divider()
            Button("Export Diagnostics…") { exportDiagnostics() }.disabled(support.exporting)
            Button("Reveal Data Folder") { Workspace.open(startup.support) }
        }
    }

    private func openInformation(_ page: ReleaseInformationView.Page) {
        // One window per page; reopening a page brings its existing window forward.
        openWindow(id: ReleaseInformationView.windowID, value: page)
    }

    private func exportDiagnostics() {
        Task {
            guard let url = await FilePanels.chooseSaveDestination(
                fileName: ReleaseSupportViewModel.diagnosticsFileName, types: ReleaseSupportViewModel.diagnosticsTypes,
                message: ReleaseSupportViewModel.diagnosticsDisclosure) else { return }
            await support.exportDiagnostics(to: url, updateConfigured: updates.isConfigured, libraryOpenFailed: startup.failed)
            if let message = support.errorMessage { Alerts.show(message) }
        }
    }
}
