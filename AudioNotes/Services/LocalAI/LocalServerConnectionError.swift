import Foundation

/// Retains the transport cause without recording request content or credentials.
struct LocalServerConnectionError: LocalizedError, Equatable, Sendable {
    let provider: LLMProviderID
    let address: String
    let operation: String
    let code: URLError.Code

    var errorDescription: String? {
        let guidance: String = switch code {
        case .appTransportSecurityRequiresSecureConnection:
            "macOS blocked this HTTP connection. Use HTTPS or an address permitted by the app's transport security settings."
        case .networkConnectionLost:
            "The connection dropped while the request was in progress. Try again; if it repeats, check the server log, network connection, and any proxy or VPN. For a LAN server, also check Soniquill access in System Settings → Privacy & Security → Local Network."
        case .notConnectedToInternet:
            "Network access is unavailable or was interrupted. For a LAN server, check Soniquill access in System Settings → Privacy & Security → Local Network, then check the network connection."
        case .cannotFindHost, .dnsLookupFailed:
            "The server hostname could not be resolved. Check the address or use its IP address."
        case .timedOut:
            "The server did not respond before the timeout. Check the server, published port, and firewall."
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            "The secure connection failed. Check the server's HTTPS configuration and certificate."
        default:
            "Check that the server is running and listening on this address, and that its port is reachable through the firewall."
        }
        return "\(provider.title) connection failed at \(address) (\(operation), URLSession \(code.rawValue)). \(guidance)"
    }
}
