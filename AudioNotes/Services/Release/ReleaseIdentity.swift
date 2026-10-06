import Foundation

struct ReleaseIdentity: Codable, Sendable {
    let name: String
    let bundleIdentifier: String
    let version: String
    let build: String
    let copyright: String

    init(bundle: Bundle = .main) {
        name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Soniquill"
        bundleIdentifier = bundle.bundleIdentifier ?? "unknown"
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        copyright = bundle.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? ""
    }
}

struct UpdateConfiguration: Sendable {
    let feedURL: URL
    let publicKey: String

    init?(feed: String?, publicKey: String?) {
        guard let feed, let url = URL(string: feed), url.scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              !host.hasSuffix(".example"), !feed.contains("$("),
              let publicKey, let decoded = Data(base64Encoded: publicKey), decoded.count == 32 else { return nil }
        self.feedURL = url
        self.publicKey = publicKey
    }

    init?(bundle: Bundle = .main) {
        self.init(feed: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
                  publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
    }
}

/// Fixture switches have no effect in a production binary.
enum BuildEnvironment {
    static var isDevelopmentHost: Bool {
#if DEBUG
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.arguments.contains("--performance-fixtures")
            || ProcessInfo.processInfo.arguments.contains("--performance-empty-library")
#else
        false
#endif
    }
}
