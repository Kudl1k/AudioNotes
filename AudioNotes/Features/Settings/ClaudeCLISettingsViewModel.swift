import Foundation
import Combine

@MainActor
final class ClaudeCLISettingsViewModel: ObservableObject {
    @Published private(set) var account: ProviderAccount?
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    private let runner: any ClaudeCLIRunning
    private var task: Task<Void, Never>?

    init(runner: any ClaudeCLIRunning = ClaudeCLIRunner()) { self.runner = runner }

    func refresh(path: String) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do { account = try await ClaudeCLIClient(executable: path, runner: runner).account() }
        catch is CancellationError { }
        catch { account = nil; errorMessage = error.localizedDescription }
    }

    func signIn(path: String) {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        task = Task {
            defer { isBusy = false; task = nil }
            do { account = try await ClaudeCLIClient(executable: path, runner: runner).signIn() }
            catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func cancelSignIn() { task?.cancel() }
}
