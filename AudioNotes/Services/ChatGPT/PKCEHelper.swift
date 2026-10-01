import CryptoKit
import Foundation
import Security

enum PKCEHelper {
    /// Generates cryptographically secure random bytes.
    static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw PKCEError.randomGenerationFailed(status: status)
        }
        return Data(bytes)
    }

    /// Generates a PKCE code verifier (32 cryptographically random bytes, Base64URL-encoded).
    static func generateCodeVerifier() throws -> String {
        let bytes = try randomBytes(count: 32)
        return base64URLEncode(bytes)
    }

    /// Computes the S256 code challenge for a given code verifier.
    static func generateCodeChallenge(from verifier: String) -> String {
        guard let data = verifier.data(using: .utf8) else { return "" }
        let digest = SHA256.hash(data: data)
        return base64URLEncode(Data(digest))
    }

    /// Generates a cryptographically random token for `state` or `nonce`.
    static func generateRandomToken(byteCount: Int = 32) throws -> String {
        let bytes = try randomBytes(count: byteCount)
        return base64URLEncode(bytes)
    }

    /// Encodes data into Base64URL format without padding.
    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decodes a Base64URL string into Data.
    static func base64URLDecode(_ string: String) -> Data? {
        let unescaped = string.removingPercentEncoding ?? string
        let cleaned = unescaped.trimmingCharacters(in: .whitespacesAndNewlines)
        var base64 = cleaned
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingLength = (4 - (base64.count % 4)) % 4
        base64.append(String(repeating: "=", count: paddingLength))
        return Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
    }
}

enum PKCEError: LocalizedError, Equatable {
    case randomGenerationFailed(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .randomGenerationFailed(let status):
            "Failed to generate cryptographically secure random bytes (status \(status))."
        }
    }
}
