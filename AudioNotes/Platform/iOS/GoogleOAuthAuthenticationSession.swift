#if os(iOS)
import AuthenticationServices
import UIKit

@MainActor
final class GoogleOAuthAuthenticationSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var activeSession: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private let anchor: ASPresentationAnchor

    private init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }

    static func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try Task.checkCancellation()
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .filter({ $0.activationState == .foregroundActive })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) else {
            throw GoogleGeminiOAuthError.authorization("No active window for Google sign-in.")
        }
        return try await GoogleOAuthAuthenticationSession(anchor: window).run(url: url, callbackScheme: callbackScheme)
    }

    private func run(url: URL, callbackScheme: String) async throws -> URL {
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callbackURL, error in
                    let result: Result<URL, GoogleGeminiOAuthError>
                    if let callbackURL {
                        result = .success(callbackURL)
                    } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                        result = .failure(.cancelled)
                    } else {
                        result = .failure(.authorization("The system sign-in session ended without a callback."))
                    }
                    Task { @MainActor [weak self] in self?.finish(result) }
                }
                session.presentationContextProvider = self
                activeSession = session
                if !session.start() {
                    finish(.failure(.authorization("Could not start the system sign-in session.")))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.activeSession?.cancel()
                self?.finish(.failure(.cancelled))
            }
        }
    }

    private func finish(_ result: Result<URL, GoogleGeminiOAuthError>) {
        guard let continuation else { return }
        self.continuation = nil
        activeSession = nil
        continuation.resume(with: result)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}
#endif
