import Foundation
#if os(macOS)
import Darwin
#endif

enum ClaudeCLIError: LocalizedError, Equatable, Sendable {
    case notInstalled, notSignedIn, unsupportedAuthentication, launchFailed, timedOut, invalidResponse, invalidModel, requestFailed
    case executionFailed(Int32)
    var errorDescription: String? {
        switch self {
        case .notInstalled: "Install Claude Code, then refresh its connection in Settings → Anthropic."
        case .notSignedIn: "Sign in with Claude Code in Settings → Anthropic before generating summaries or chatting."
        case .unsupportedAuthentication: "Claude Code must use a Claude account login. Run claude auth login without --console, then refresh the connection."
        case .launchFailed: "Could not launch Claude Code. Check its executable path in Settings → Anthropic."
        case .timedOut: "Claude Code timed out. Try again or check your login in Terminal."
        case .invalidResponse: "Claude Code returned an invalid response. Update Claude Code and try again."
        case .invalidModel: "Enter a Claude model or alias in Settings → General, such as sonnet, opus, or haiku."
        case .requestFailed: "Claude Code could not complete this request. Check your account login, model access, and usage limits in Claude Code."
        case .executionFailed(let code): "Claude Code stopped with exit code \(code). Check your login, model access, and usage limits in Claude Code."
        }
    }
}

protocol ClaudeCLIRunning: Sendable {
    func run(executable: String, arguments: [String], input: Data, systemPrompt: String?) -> AsyncThrowingStream<Data, Error>
}

#if os(macOS)
/// Bridges Foundation process/pipe callbacks into structured concurrency. A locked
/// process handle makes cancellation safe before, during, and after launch.
struct ClaudeCLIRunner: ClaudeCLIRunning {
    var timeout: Duration = .seconds(300)

    static func executable(configuredPath: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                           home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        let path = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = path.isEmpty
            ? [home.appending(path: ".local/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
                + (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/claude" }
            : [(path as NSString).expandingTildeInPath]
        guard let match = candidates.first(where: { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ClaudeCLIError.notInstalled
        }
        return URL(fileURLWithPath: match)
    }

    static func environment(_ original: [String: String]) -> [String: String] {
        // Keep the CLI's own Keychain login, never inherited keys, tokens or provider routing.
        original.filter { key, _ in
            !key.hasPrefix("ANTHROPIC_") && !key.hasPrefix("CLAUDE_") && key != "CLAUDECODE"
                && !["AWS_BEARER_TOKEN_BEDROCK", "GOOGLE_APPLICATION_CREDENTIALS"].contains(key)
        }
    }

    func run(executable: String, arguments: [String], input: Data, systemPrompt: String?) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let invocation = ClaudeCLIInvocation()
            let worker = Task.detached {
                let directory = FileManager.default.temporaryDirectory.appending(path: "AudioNotes-Claude-\(UUID())")
                do {
                    try Task.checkCancellation()
                    let binary = try Self.executable(configuredPath: executable)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                           attributes: [.posixPermissions: 0o700])
                    defer { try? FileManager.default.removeItem(at: directory) }
                    let inputURL = directory.appending(path: "input")
                    guard FileManager.default.createFile(atPath: inputURL.path, contents: input, attributes: [.posixPermissions: 0o600]) else {
                        throw ClaudeCLIError.launchFailed
                    }
                    let stdin = try FileHandle(forReadingFrom: inputURL)
                    defer { try? stdin.close() }
                    let process = Process()
                    process.executableURL = binary
                    var resolvedArguments = arguments
                    if let systemPrompt {
                        let systemURL = directory.appending(path: "system")
                        guard FileManager.default.createFile(atPath: systemURL.path, contents: Data(systemPrompt.utf8),
                                                             attributes: [.posixPermissions: 0o600]) else { throw ClaudeCLIError.launchFailed }
                        resolvedArguments += ["--system-prompt-file", systemURL.path]
                    }
                    process.arguments = resolvedArguments
                    process.environment = Self.environment(ProcessInfo.processInfo.environment)
                    process.currentDirectoryURL = directory
                    process.standardInput = stdin
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    let output = AsyncStream<Data>.makeStream()
                    pipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        if data.isEmpty {
                            handle.readabilityHandler = nil
                            output.continuation.finish()
                        } else {
                            output.continuation.yield(data)
                        }
                    }
                    let termination = AsyncStream<Void>.makeStream()
                    process.terminationHandler = { _ in termination.continuation.finish() }
                    defer {
                        pipe.fileHandleForReading.readabilityHandler = nil
                        output.continuation.finish()
                        termination.continuation.finish()
                    }
                    // Never log CLI diagnostics: they can contain source content or credentials.
                    process.standardError = FileHandle.nullDevice
                    try invocation.launch(process)
                    let deadline = Task {
                        try await Task.sleep(for: timeout)
                        invocation.stop(timedOut: true)
                    }
                    defer { deadline.cancel(); invocation.stop() }
                    var bytes = 0
                    for await data in output.stream {
                        bytes += data.count
                        guard bytes <= 32 * 1_024 * 1_024 else { throw ClaudeCLIError.invalidResponse }
                        try Task.checkCancellation()
                        continuation.yield(data)
                    }
                    for await _ in termination.stream { }
                    try invocation.checkCancellation()
                    try Task.checkCancellation()
                    guard process.terminationStatus == 0 else { throw ClaudeCLIError.executionFailed(process.terminationStatus) }
                    try? stdin.close()
                    try FileManager.default.removeItem(at: directory)
                    continuation.finish()
                } catch {
                    invocation.stop()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable reason in
                if case .cancelled = reason { invocation.stop(); worker.cancel() }
            }
        }
    }
}

private final class ClaudeCLIInvocation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false
    private var timedOut = false

    func launch(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { throw CancellationError() }
        self.process = process
        do { try process.run() } catch { throw ClaudeCLIError.launchFailed }
    }

    func checkCancellation() throws {
        lock.lock()
        defer { lock.unlock() }
        if timedOut { throw ClaudeCLIError.timedOut }
        if stopped { throw CancellationError() }
    }

    func stop(timedOut: Bool = false) {
        lock.lock()
        stopped = true
        self.timedOut = self.timedOut || timedOut
        let running = process
        if let running, running.isRunning { running.terminate() }
        lock.unlock()
        Task.detached {
            try? await Task.sleep(for: .seconds(1))
            if let running, running.isRunning { kill(running.processIdentifier, SIGKILL) }
        }
    }
}
#else
/// Inert stub for non-macOS platforms where Process is unavailable.
struct ClaudeCLIRunner: ClaudeCLIRunning {
    func run(executable: String, arguments: [String], input: Data, systemPrompt: String?) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: ClaudeCLIError.launchFailed)
        }
    }
}
#endif
