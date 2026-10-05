#if os(iOS)
import AuthenticationServices
import UIKit

@MainActor
final class GoogleOAuthAuthenticationSession: NSObject, ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {
    private var activeSession: ASWebAuthenticationSession?

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callbackURL, error in
                    self?.activeSession = nil
                    if let callbackURL { continuation.resume(returning: callbackURL) }
                    else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                        continuation.resume(throwing: GoogleGeminiOAuthError.cancelled)
                    } else {
                        continuation.resume(throwing: error ?? GoogleGeminiOAuthError.authorization("The Google sign-in session ended without a callback."))
                    }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                activeSession = session
                guard session.start() else {
                    activeSession = nil
                    continuation.resume(throwing: GoogleGeminiOAuthError.authorization("Could not start the system sign-in session."))
                    return
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.activeSession?.cancel() }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? UIWindow()
    }
}
#endif
