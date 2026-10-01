import Combine
import Sparkle

/// Sparkle owns scheduling, signatures, installation and standard error presentation.
@MainActor
final class UpdateService: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published var automaticallyChecksForUpdates = false
    let isConfigured: Bool
    private let controller: SPUStandardUpdaterController?
    private var observations = Set<AnyCancellable>()

    init(enabled: Bool = true, configuration: UpdateConfiguration? = UpdateConfiguration()) {
        isConfigured = enabled && configuration != nil
        guard isConfigured else { controller = nil; return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: RunLoop.main)
            .assign(to: &$automaticallyChecksForUpdates)
        $automaticallyChecksForUpdates.dropFirst().removeDuplicates().sink { [weak controller] value in
            guard let updater = controller?.updater, updater.automaticallyChecksForUpdates != value else { return }
            updater.automaticallyChecksForUpdates = value
        }.store(in: &observations)
        controller.startUpdater()
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }
}
