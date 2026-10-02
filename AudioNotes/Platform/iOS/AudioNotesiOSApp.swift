#if os(iOS)
import SwiftUI
import SwiftData

@main
struct AudioNotesiOSApp: App {
    @State private var services = AppServices()
    @State private var startup = LibraryStartup()
    private var container: ModelContainer? { startup.container }

    var body: some Scene {
        WindowGroup {
            if let container {
                IOSRootView(services: services)
                    .modelContainer(container)
                    .environment(services.llmConfiguration.localAI)
            } else {
                LibraryRecoveryView(startup: startup)
            }
        }
    }
}
#endif
