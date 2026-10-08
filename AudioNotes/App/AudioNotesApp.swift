#if os(macOS)
import SwiftUI
import SwiftData

@main
struct AudioNotesApp: App {
#if DEBUG
    @NSApplicationDelegateAdaptor(PerformanceFixtureApplicationDelegate.self) private var fixtureDelegate
#endif
    @State private var services = AppServices()
    @State private var startup = LibraryStartup()
    @StateObject private var updates = UpdateService(enabled: !BuildEnvironment.isDevelopmentHost)
    private var container: ModelContainer? { startup.container }

    var body: some Scene {
        WindowGroup("Soniquill", id: "library") {
            if let container {
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--performance-fixtures") {
                    PerformanceFixtureLibrary().modelContainer(container).environment(services.llmConfiguration.localAI).frame(minWidth: 760, minHeight: 500)
                } else {
                    library(container: container)
                }
#else
                library(container: container)
#endif
            } else {
                LibraryRecoveryView(startup: startup)
            }
        }
        .defaultSize(width: 1100, height: 750)
        .commands {
            ImportCommands()
            ExportCommands()
            SidebarCommands()
            ReleaseCommands(updates: updates, startup: startup)
        }
        WindowGroup("Information", id: ReleaseInformationView.windowID, for: ReleaseInformationView.Page.self) { $page in
            if let page { ReleaseInformationView(page: page) }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)
        .commandsRemoved()
        Settings {
            if let container {
                ProviderSettingsView(
                    transcriptionConfig: services.configuration,
                    llmConfig: services.llmConfiguration,
                    credentials: services.credentials,
                    chatGPTAuth: services.chatGPTAuthService,
                    tokenRefresher: services.chatGPTTokenRefresher,
                    modelsClient: services.modelsClient,
                    googleOAuth: services.googleGeminiOAuth,
                    whisperStore: services.whisperStore,
                    localAISettings: services.localAISettings,
                    updates: updates
                )
                .modelContainer(container)
                .environment(services.llmConfiguration.localAI)
                .frame(minWidth: 580, minHeight: 520)
            } else {
                ContentUnavailableView("Settings unavailable", systemImage: "externaldrive.badge.exclamationmark",
                                       description: Text("Soniquill could not initialize its local database."))
                    .frame(minWidth: 580, minHeight: 520)
            }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
    }
    private func library(container: ModelContainer) -> some View {
        LibraryView(transcriptionResolver: services.transcriptionResolver, llmResolver: services.llmResolver)
            .modelContainer(container)
            .environment(services.llmConfiguration.localAI)
            .frame(minWidth: 760, minHeight: 500)
            .modifier(WelcomePresentation())
    }

}

private struct NewProjectKey: FocusedValueKey { typealias Value = () -> Void }

private struct ImportAudioKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct ExportKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var newProject: (() -> Void)? {
        get { self[NewProjectKey.self] }
        set { self[NewProjectKey.self] = newValue }
    }

    var importAudio: (() -> Void)? {
        get { self[ImportAudioKey.self] }
        set { self[ImportAudioKey.self] = newValue }
    }

    var exportAction: (() -> Void)? {
        get { self[ExportKey.self] }
        set { self[ExportKey.self] = newValue }
    }
}

private struct ImportCommands: Commands {
    @FocusedValue(\.importAudio) private var importAudio
    @FocusedValue(\.newProject) private var newProject

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project…") { newProject?() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(newProject == nil)
            Button("Import…") { importAudio?() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(importAudio == nil)
        }
    }
}

private struct ExportCommands: Commands {
    @FocusedValue(\.exportAction) private var exportAction

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Export…") { exportAction?() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(exportAction == nil)
        }
    }
}

#endif
