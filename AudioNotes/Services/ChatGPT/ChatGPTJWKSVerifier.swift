import Foundation
import Security

struct JWK: Codable, Sendable {
    let kty: String
    let kid: String?
    let alg: String?
    let use: String?
    let n: String?
    let e: String?
    let crv: String?
    let x: String?
    let y: String?
}

struct JWKS: Codable, Sendable {
    let keys: [JWK]
}

struct Audience: Codable, Sendable, Equatable {
    let values: [String]

    init(values: [String]) {
        self.values = values
    }

    init(single: String) {
        self.values = [single]
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let single = try? container.decode(String.self) {
            values = [single]
        } else if let array = try? container.decode([String].self) {
            values = array
        } else {
            throw DecodingError.typeMismatch(
                Audience.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected String or [String] for aud claim")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if values.count == 1, let first = values.first {
            try container.encode(first)
        } else {
            try container.encode(values)
        }
    }

    func matches(_ expected: String) -> Bool {
        if values.contains(expected) {
            return true
        }
        if values.contains(where: { $0.caseInsensitiveCompare(expected) == .orderedSame }) {
            return true
        }
        if !expected.isEmpty && values.contains(where: { $0.contains(expected) }) {
            return true
        }
        // If expected is an issued oaiapp_... client ID, but token aud contains dynamic_agent_client during registration
        if expected.hasPrefix("oaiapp_") && values.contains("dynamic_agent_client") {
            return true
        }
        // If expected is dynamic_agent_client, but token aud contains an issued oaiapp_...
        if expected == "dynamic_agent_client" && values.contains(where: { $0.hasPrefix("oaiapp_") }) {
            return true
        }
        return false
    }

    var displayString: String {
        values.joined(separator: ", ")
    }
}

struct IDTokenClaims: Codable, Sendable {
    let iss: String
    let aud: Audience
    let sub: String
    let exp: TimeInterval?
    let iat: TimeInterval?
    let nonce: String?
    let email: String?
    let name: String?
    let chatgptUserID: String?
    let chatgptPlanType: String?

    enum CodingKeys: String, CodingKey {
        case iss, aud, sub, exp, iat, nonce, email, name
        case authNamespace = "https://api.openai.com/auth"
    }

    struct AuthNamespaceClaims: Codable, Sendable {
        let chatgptUserID: String?
        let chatgptAccountID: String?
        let chatgptPlanType: String?

        enum CodingKeys: String, CodingKey {
            case chatgptUserID = "chatgpt_user_id"
            case chatgptAccountID = "chatgpt_account_id"
            case chatgptPlanType = "chatgpt_plan_type"
        }
    }

    init(
        iss: String,
        aud: Audience,
        sub: String,
        exp: TimeInterval?,
        iat: TimeInterval? = nil,
        nonce: String? = nil,
        email: String? = nil,
        name: String? = nil,
        chatgptUserID: String? = nil,
        chatgptPlanType: String? = nil
    ) {
        self.iss = iss
        self.aud = aud
        self.sub = sub
        self.exp = exp
        self.iat = iat
        self.nonce = nonce
        self.email = email
        self.name = name
        self.chatgptUserID = chatgptUserID
        self.chatgptPlanType = chatgptPlanType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.iss = try container.decodeIfPresent(String.self, forKey: .iss) ?? ""
        self.aud = try container.decode(Audience.self, forKey: .aud)
        self.sub = try container.decodeIfPresent(String.self, forKey: .sub) ?? ""

        // Handle exp as Double, Int, or String
        if let expDouble = try? container.decode(Double.self, forKey: .exp) {
            self.exp = expDouble
        } else if let expInt = try? container.decode(Int.self, forKey: .exp) {
            self.exp = Double(expInt)
        } else if let expStr = try? container.decode(String.self, forKey: .exp), let expDouble = Double(expStr) {
            self.exp = expDouble
        } else {
            self.exp = nil
        }

        // Handle iat as Double, Int, or String
        if let iatDouble = try? container.decode(Double.self, forKey: .iat) {
            self.iat = iatDouble
        } else if let iatInt = try? container.decode(Int.self, forKey: .iat) {
            self.iat = Double(iatInt)
        } else if let iatStr = try? container.decode(String.self, forKey: .iat), let iatDouble = Double(iatStr) {
            self.iat = iatDouble
        } else {
            self.iat = nil
        }

        self.nonce = try container.decodeIfPresent(String.self, forKey: .nonce)
        self.email = try container.decodeIfPresent(String.self, forKey: .email)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)

        if let auth = try? container.decodeIfPresent(AuthNamespaceClaims.self, forKey: .authNamespace) {
            self.chatgptUserID = auth.chatgptUserID
            self.chatgptPlanType = auth.chatgptPlanType
        } else {
            self.chatgptUserID = nil
            self.chatgptPlanType = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(iss, forKey: .iss)
        try container.encode(aud, forKey: .aud)
        try container.encode(sub, forKey: .sub)
        try container.encodeIfPresent(exp, forKey: .exp)
        try container.encodeIfPresent(iat, forKey: .iat)
        try container.encodeIfPresent(nonce, forKey: .nonce)
        try container.encodeIfPresent(email, forKey: .email)
        try container.encodeIfPresent(name, forKey: .name)
        if chatgptUserID != nil || chatgptPlanType != nil {
            let auth = AuthNamespaceClaims(chatgptUserID: chatgptUserID, chatgptAccountID: nil, chatgptPlanType: chatgptPlanType)
            try container.encode(auth, forKey: .authNamespace)
        }
    }

    static func parseClaims(from payloadData: Data) throws -> IDTokenClaims {
        // Try strongly-typed JSONDecoder first
        if let claims = try? JSONDecoder().decode(IDTokenClaims.self, from: payloadData) {
            return claims
        }

        // Fallback: parse via JSONSerialization
        guard let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            let snippet = String(data: payloadData.prefix(200), encoding: .utf8) ?? "<non-utf8>"
            throw TokenValidationError.invalidPayload(message: "Payload is not valid JSON: \(snippet)")
        }

        let iss = (json["iss"] as? String) ?? ""
        let aud: Audience
        if let audStr = json["aud"] as? String {
            aud = Audience(single: audStr)
        } else if let audArr = json["aud"] as? [String] {
            aud = Audience(values: audArr)
        } else {
            throw TokenValidationError.invalidPayload(message: "Missing or invalid 'aud' claim in ID token.")
        }

        let authDict = json["https://api.openai.com/auth"] as? [String: Any]
        let chatgptUserID = authDict?["chatgpt_user_id"] as? String
        let chatgptPlanType = authDict?["chatgpt_plan_type"] as? String

        let sub = (json["sub"] as? String) ?? chatgptUserID ?? (json["email"] as? String) ?? "chatgpt_user"

        var exp: TimeInterval?
        if let d = json["exp"] as? Double {
            exp = d
        } else if let i = json["exp"] as? Int {
            exp = Double(i)
        } else if let s = json["exp"] as? String, let d = Double(s) {
            exp = d
        }

        var iat: TimeInterval?
        if let d = json["iat"] as? Double {
            iat = d
        } else if let i = json["iat"] as? Int {
            iat = Double(i)
        } else if let s = json["iat"] as? String, let d = Double(s) {
            iat = d
        }

        let nonce = json["nonce"] as? String
        let email = (json["email"] as? String) ?? (authDict?["email"] as? String)
        let name = (json["name"] as? String) ?? (json["given_name"] as? String)

        return IDTokenClaims(
            iss: iss,
            aud: aud,
            sub: sub,
            exp: exp,
            iat: iat,
            nonce: nonce,
            email: email,
            name: name,
            chatgptUserID: chatgptUserID,
            chatgptPlanType: chatgptPlanType
        )
    }
}

enum TokenValidationError: LocalizedError, Equatable {
    case invalidTokenFormat
    case invalidHeader
    case invalidPayload(message: String)
    case invalidSignature
    case unsupportedAlgorithm(String)
    case keyNotFound(kid: String?)
    case invalidKeyData
    case issuerMismatch(expected: String, got: String)
    case audienceMismatch(expected: String, got: String)
    case nonceMismatch(expected: String, got: String?)
    case tokenExpired(expiredAt: Date)
    case missingSubject
    case networkError(String)

    static var invalidPayload: TokenValidationError {
        .invalidPayload(message: "Could not parse identity claims from the ID token.")
    }

    var errorDescription: String? {
        switch self {
        case .invalidTokenFormat:
            "The ID token format is invalid."
        case .invalidHeader:
            "Could not parse the ID token header."
        case .invalidPayload(let msg):
            if msg.isEmpty || msg == "Could not parse identity claims from the ID token." {
                "Could not parse identity claims from the ID token."
            } else {
                "Could not parse identity claims from the ID token: \(msg)"
            }
        case .invalidSignature:
            "The ID token signature could not be verified with OpenAI's public keys."
        case .unsupportedAlgorithm(let alg):
            "The token algorithm '\(alg)' is not supported."
        case .keyNotFound(let kid):
            "No matching public key found for kid: '\(kid ?? "unknown")'."
        case .invalidKeyData:
            "The public key in the JWKS could not be initialized."
        case .issuerMismatch(let exp, let got):
            "ID token issuer '\(got)' does not match expected '\(exp)'."
        case .audienceMismatch(let exp, let got):
            "ID token audience '\(got)' does not match expected client ID '\(exp)'."
        case .nonceMismatch:
            "ID token nonce does not match the authorization request."
        case .tokenExpired(let date):
            "The ID token has expired at \(date)."
        case .missingSubject:
            "The ID token does not contain a user subject identifier."
        case .networkError(let msg):
            "Failed to load public keys from OpenAI: \(msg)"
        }
    }
}

protocol JWKSFetching: Sendable {
    func fetchJWKS() async throws -> JWKS
}

final class URLSessionJWKSFetcher: JWKSFetching, Sendable {
    private let session: URLSession
    private let jwksURL: URL

    init(
        session: URLSession = .shared,
        jwksURL: URL = URL(string: "https://auth.openai.com/.well-known/jwks.json")!
    ) {
        self.session = session
        self.jwksURL = jwksURL
    }

    func fetchJWKS() async throws -> JWKS {
        let (data, response) = try await session.data(from: jwksURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw TokenValidationError.networkError("Invalid HTTP response when loading JWKS.")
        }
        do {
            return try JSONDecoder().decode(JWKS.self, from: data)
        } catch {
            throw TokenValidationError.networkError("Failed to decode JWKS: \(error.localizedDescription)")
        }
    }
}

final class MockJWKSFetcher: JWKSFetching, @unchecked Sendable {
    var jwks: JWKS

    init(jwks: JWKS) {
        self.jwks = jwks
    }

    func fetchJWKS() async throws -> JWKS {
        jwks
    }
}

final class ChatGPTIDTokenValidator: Sendable {
    private let jwksFetcher: any JWKSFetching
    private let expectedIssuer: String

    init(
        jwksFetcher: any JWKSFetching = URLSessionJWKSFetcher(),
        expectedIssuer: String = "https://auth.openai.com"
    ) {
        self.jwksFetcher = jwksFetcher
        self.expectedIssuer = expectedIssuer
    }

    func validate(
        idToken: String,
        expectedNonce: String,
        expectedAudience: String,
        clockTolerance: TimeInterval = 60,
        currentDate: Date = Date()
    ) async throws -> IDTokenClaims {
        let trimmedToken = idToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmedToken.components(separatedBy: ".")
        guard components.count == 3 else {
            throw TokenValidationError.invalidTokenFormat
        }

        let headerSegment = components[0]
        let payloadSegment = components[1]
        let signatureSegment = components[2]

        guard let headerData = PKCEHelper.base64URLDecode(headerSegment),
              let headerJson = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let alg = headerJson["alg"] as? String else {
            throw TokenValidationError.invalidHeader
        }

        let kid = headerJson["kid"] as? String

        guard let payloadData = PKCEHelper.base64URLDecode(payloadSegment) else {
            throw TokenValidationError.invalidPayload(message: "Base64URL decoding failed for payload segment.")
        }

        let claims = try IDTokenClaims.parseClaims(from: payloadData)

        // Validate claims: normalize issuers by removing trailing slashes
        let normalizedGotIss = claims.iss.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedExpIss = expectedIssuer.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard normalizedGotIss == normalizedExpIss else {
            throw TokenValidationError.issuerMismatch(expected: expectedIssuer, got: claims.iss)
        }

        guard claims.aud.matches(expectedAudience) else {
            throw TokenValidationError.audienceMismatch(expected: expectedAudience, got: claims.aud.displayString)
        }

        if let exp = claims.exp {
            let tokenExpiry = Date(timeIntervalSince1970: exp)
            if tokenExpiry.addingTimeInterval(clockTolerance) < currentDate {
                throw TokenValidationError.tokenExpired(expiredAt: tokenExpiry)
            }
        }

        if let tokenNonce = claims.nonce, !tokenNonce.isEmpty {
            guard tokenNonce == expectedNonce else {
                throw TokenValidationError.nonceMismatch(expected: expectedNonce, got: tokenNonce)
            }
        }

        guard !claims.sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TokenValidationError.missingSubject
        }

        // Cryptographic signature verification
        let jwks = try await jwksFetcher.fetchJWKS()
        guard let matchingJWK = jwks.keys.first(where: { key in
            if let kid, let keyKid = key.kid {
                return keyKid == kid
            }
            return key.alg == alg
        }) else {
            throw TokenValidationError.keyNotFound(kid: kid)
        }

        let signingInput = "\(headerSegment).\(payloadSegment)"
        guard let signatureData = PKCEHelper.base64URLDecode(signatureSegment) else {
            throw TokenValidationError.invalidSignature
        }

        try verifySignature(
            signingInput: signingInput,
            signatureData: signatureData,
            jwk: matchingJWK,
            algorithm: alg
        )

        return claims
    }

    private func verifySignature(
        signingInput: String,
        signatureData: Data,
        jwk: JWK,
        algorithm: String
    ) throws {
        guard let signedData = signingInput.data(using: .utf8) else {
            throw TokenValidationError.invalidTokenFormat
        }

        switch algorithm {
        case "RS256":
            guard let nStr = jwk.n, let eStr = jwk.e,
                  let modulus = PKCEHelper.base64URLDecode(nStr),
                  let exponent = PKCEHelper.base64URLDecode(eStr) else {
                throw TokenValidationError.invalidKeyData
            }
            let derKey = buildRSAPublicKeyDER(modulus: modulus, exponent: exponent)
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
                kSecAttrKeySizeInBits as String: modulus.count * 8
            ]
            var error: Unmanaged<CFError>?
            guard let secKey = SecKeyCreateWithData(derKey as CFData, attributes as CFDictionary, &error) else {
                throw TokenValidationError.invalidKeyData
            }

            let verified = SecKeyVerifySignature(
                secKey,
                .rsaSignatureMessagePKCS1v15SHA256,
                signedData as CFData,
                signatureData as CFData,
                &error
            )
            guard verified else {
                throw TokenValidationError.invalidSignature
            }

        case "ES256":
            guard let xStr = jwk.x, let yStr = jwk.y,
                  let xData = PKCEHelper.base64URLDecode(xStr),
                  let yData = PKCEHelper.base64URLDecode(yStr) else {
                throw TokenValidationError.invalidKeyData
            }
            var point = Data([0x04])
            point.append(xData)
            point.append(yData)

            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeyClass as String: kSecAttrKeyClassPublic
            ]
            var error: Unmanaged<CFError>?
            guard let secKey = SecKeyCreateWithData(point as CFData, attributes as CFDictionary, &error) else {
                throw TokenValidationError.invalidKeyData
            }

            let verified = SecKeyVerifySignature(
                secKey,
                .ecdsaSignatureMessageX962SHA256,
                signedData as CFData,
                signatureData as CFData,
                &error
            )
            guard verified else {
                throw TokenValidationError.invalidSignature
            }

        default:
            throw TokenValidationError.unsupportedAlgorithm(algorithm)
        }
    }

    /// Builds a PKCS#1 DER RSAPublicKey: SEQUENCE { modulus INTEGER, publicExponent INTEGER }
    private func buildRSAPublicKeyDER(modulus: Data, exponent: Data) -> Data {
        let encMod = encodeIntegerDER(modulus)
        let encExp = encodeIntegerDER(exponent)
        return encodeSequenceDER(encMod + encExp)
    }

    private func encodeIntegerDER(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        // If highest bit is 1, prepend 0x00 for positive integer in two's complement
        if let first = bytes.first, (first & 0x80) != 0 {
            bytes.insert(0x00, at: 0)
        }
        var result = Data([0x02])
        result.append(encodeLengthDER(bytes.count))
        result.append(contentsOf: bytes)
        return result
    }

    private func encodeSequenceDER(_ content: Data) -> Data {
        var result = Data([0x30])
        result.append(encodeLengthDER(content.count))
        result.append(content)
        return result
    }

    private func encodeLengthDER(_ length: Int) -> Data {
        if length < 128 {
            return Data([UInt8(length)])
        } else if length < 256 {
            return Data([0x81, UInt8(length)])
        } else {
            return Data([0x82, UInt8((length >> 8) & 0xff), UInt8(length & 0xff)])
        }
    }
}
