import Foundation

public enum DebugLogLevel: String, Sendable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

public struct DebugLogEntry: Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let level: DebugLogLevel
    public let subsystem: String
    public let message: String

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        level: DebugLogLevel,
        subsystem: String,
        message: String
    ) {
        self.id = id
        self.date = date
        self.level = level
        self.subsystem = subsystem
        self.message = message
    }
}

public final class DebugLogService: @unchecked Sendable {
    public static let shared = DebugLogService()

    private let lock = NSLock()
    private var entries: [DebugLogEntry] = []
    private let maxEntries = 500

    private init() {}

    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.isEmpty
    }

    public func log(level: DebugLogLevel, subsystem: String, message: String) {
#if !DEBUG
        // Free-form messages can contain private payloads; production never records them.
        return
#else
        let sanitized = Self.redact(message)
        let entry = DebugLogEntry(level: level, subsystem: subsystem, message: sanitized)
        lock.lock()
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        lock.unlock()
#endif
    }

    public func debug(subsystem: String, message: String) {
        log(level: .debug, subsystem: subsystem, message: message)
    }

    public func info(subsystem: String, message: String) {
        log(level: .info, subsystem: subsystem, message: message)
    }

    public func warning(subsystem: String, message: String) {
        log(level: .warning, subsystem: subsystem, message: message)
    }

    public func error(subsystem: String, message: String) {
        log(level: .error, subsystem: subsystem, message: message)
    }

    public func formattedLogs() -> String {
        lock.lock()
        let snapshot = entries
        lock.unlock()

        guard !snapshot.isEmpty else {
            return "--- No diagnostic logs recorded ---"
        }

        return snapshot.map { entry in
            let dateStr = entry.date.formatted(.iso8601)
            return "[\(dateStr)] [\(entry.level.rawValue)] [\(entry.subsystem)] \(entry.message)"
        }.joined(separator: "\n")
    }

    public func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    public static func redact(_ raw: String) -> String {
        var text = raw

        // Redact Authorization: Bearer tokens
        if let bearerRegex = try? NSRegularExpression(pattern: "(Bearer\\s+)([A-Za-z0-9_.-]{10,})", options: .caseInsensitive) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = bearerRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1[REDACTED token]")
        }

        // Redact OpenAI API keys (sk-...)
        if let skRegex = try? NSRegularExpression(pattern: "sk-[A-Za-z0-9_-]{20,}", options: []) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = skRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "sk-...[REDACTED]")
        }

        // Redact JSON access_token / refresh_token / id_token values
        if let tokenRegex = try? NSRegularExpression(pattern: "\"((?:access|refresh|id)_token)\"\\s*:\\s*\"([^\"]+)\"", options: []) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = tokenRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "\"$1\": \"[REDACTED]\"")
        }

        return text
    }
}
