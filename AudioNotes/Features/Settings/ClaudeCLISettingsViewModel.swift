import Foundation
import Combine

@MainActor
final class ClaudeCLISettingsViewModel: ObservableObject {
    enum Operation {
        case checking, signingIn
    }

    @Published private(set) var account: ProviderAccount?
    @Published private(set) var operation: Operation?
    @Published private(set) var errorMessage: String?
    private let statusRunner: any ClaudeCLIRunning
    private let signInRunner: any ClaudeCLIRunning

    init(runner: (any ClaudeCLIRunning)? = nil) {
        statusRunner = runner ?? ClaudeCLIRunner(timeout: .seconds(12))
        signInRunner = runner ?? ClaudeCLIRunner()
    }

    func refresh(path: String) async -> Bool {
        await run(.checking, path: path)
    }

    func signIn(path: String) async -> Bool {
        await run(.signingIn, path: path)
    }

    private func run(_ operation: Operation, path: String) async -> Bool {
        guard self.operation == nil, !Task.isCancelled else { return false }
        self.operation = operation
        errorMessage = nil
        defer { self.operation = nil }

        do {
            let updatedAccount: ProviderAccount
            switch operation {
            case .checking:
                updatedAccount = try await ClaudeCLIClient(executable: path, runner: statusRunner).account()
            case .signingIn:
                updatedAccount = try await ClaudeCLIClient(executable: path, runner: signInRunner).signIn()
            }
            try Task.checkCancellation()
            account = updatedAccount
            return updatedAccount.state == .connected
        } catch is CancellationError {
            return false
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
            return false
        }
    }
}
