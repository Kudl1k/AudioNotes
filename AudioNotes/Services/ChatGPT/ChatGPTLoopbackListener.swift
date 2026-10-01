import Foundation
import Network

struct ChatGPTCallbackResult: Sendable {
    let code: String?
    let state: String?
    let clientID: String?
    let error: String?
    let errorDescription: String?
    let scope: String?
}

enum LoopbackError: LocalizedError, Equatable {
    case listenerFailed(String)
    case cancelled
    case timedOut
    case invalidRequest

    var errorDescription: String? {
        switch self {
        case .listenerFailed(let msg):
            "Authentication listener failed: \(msg)"
        case .cancelled:
            "Authentication was cancelled."
        case .timedOut:
            "Authentication timed out waiting for browser sign-in."
        case .invalidRequest:
            "Received an invalid authentication callback."
        }
    }
}

protocol ChatGPTLoopbackListening: Sendable {
    func start() async throws -> (redirectURI: String, port: UInt16)
    func waitForCallback(timeout: TimeInterval) async throws -> ChatGPTCallbackResult
    func cancel()
}

private final class StartContinuationBox: @unchecked Sendable {
    private var continuation: CheckedContinuation<(String, UInt16), Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<(String, UInt16), Error>) {
        self.continuation = continuation
    }

    func resume(returning value: (String, UInt16)) {
        lock.lock()
        defer { lock.unlock() }
        continuation?.resume(returning: value)
        continuation = nil
    }

    func resume(throwing error: Error) {
        lock.lock()
        defer { lock.unlock() }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

final class ChatGPTLoopbackListener: ChatGPTLoopbackListening, @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "cz.kudladev.AudioNotes.loopback-listener")
    private var continuation: CheckedContinuation<ChatGPTCallbackResult, Error>?
    private var isCompleted = false
    private let lock = NSLock()

    func start() async throws -> (redirectURI: String, port: UInt16) {
        let tcpOptions = NWProtocolTCP.Options()
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        // Bind strictly to IPv4 127.0.0.1 as required by OpenAI specifications
        guard let localHost = IPv4Address("127.0.0.1") else {
            throw LoopbackError.listenerFailed("Could not resolve 127.0.0.1")
        }
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(localHost), port: .any)

        let nwListener = try NWListener(using: parameters)
        self.listener = nwListener

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(String, UInt16), Error>) in
            let box = StartContinuationBox(continuation)

            nwListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = nwListener.port?.rawValue {
                        let redirectURI = "http://127.0.0.1:\(port)/auth/callback"
                        box.resume(returning: (redirectURI, port))
                    } else {
                        box.resume(throwing: LoopbackError.listenerFailed("Listener port could not be determined."))
                    }
                case .failed(let error):
                    box.resume(throwing: LoopbackError.listenerFailed(error.localizedDescription))
                default:
                    break
                }
            }

            nwListener.newConnectionHandler = { [weak self] connection in
                self?.handleIncomingConnection(connection)
            }

            nwListener.start(queue: self.queue)
        }
    }

    func waitForCallback(timeout: TimeInterval = 300) async throws -> ChatGPTCallbackResult {
        try await withThrowingTaskGroup(of: ChatGPTCallbackResult.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        self.lock.lock()
                        if self.isCompleted {
                            self.lock.unlock()
                            continuation.resume(throwing: LoopbackError.cancelled)
                            return
                        }
                        self.continuation = continuation
                        self.lock.unlock()
                    }
                } onCancel: {
                    self.cancel()
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw LoopbackError.timedOut
            }

            guard let result = try await group.next() else {
                throw LoopbackError.invalidRequest
            }
            group.cancelAll()
            self.cancel()
            return result
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        if !isCompleted {
            isCompleted = true
            continuation?.resume(throwing: LoopbackError.cancelled)
            continuation = nil
        }
        listener?.cancel()
        listener = nil
    }

    private func handleIncomingConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] content, _, _, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }

            guard let content, let requestString = String(data: content, encoding: .utf8) else {
                connection.cancel()
                return
            }

            let result = self.parseHTTPRequest(requestString)
            let htmlBody = self.generateHTMLResponse(for: result)
            let responseData = self.buildHTTPResponseData(body: htmlBody)

            connection.send(content: responseData, completion: .contentProcessed({ _ in
                connection.cancel()
            }))

            self.lock.lock()
            if !self.isCompleted, let continuation = self.continuation {
                self.isCompleted = true
                self.continuation = nil
                self.lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.lock.unlock()
            }
        }
    }

    private func parseHTTPRequest(_ request: String) -> ChatGPTCallbackResult {
        // e.g. "GET /auth/callback?code=...&state=...&client_id=... HTTP/1.1"
        guard let firstLine = request.components(separatedBy: "\r\n").first,
              let uriPart = firstLine.components(separatedBy: " ").dropFirst().first,
              let urlComponents = URLComponents(string: uriPart) else {
            return ChatGPTCallbackResult(code: nil, state: nil, clientID: nil, error: "invalid_request", errorDescription: "Malformed HTTP request", scope: nil)
        }

        let queryItems = urlComponents.queryItems ?? []
        func value(for name: String) -> String? {
            queryItems.first(where: { $0.name == name })?.value
        }

        return ChatGPTCallbackResult(
            code: value(for: "code"),
            state: value(for: "state"),
            clientID: value(for: "client_id"),
            error: value(for: "error"),
            errorDescription: value(for: "error_description"),
            scope: value(for: "scope")
        )
    }

    private func buildHTTPResponseData(body: String) -> Data {
        let bodyData = Data(body.utf8)
        let response = "HTTP/1.1 200 OK\r\n" +
            "Content-Type: text/html; charset=utf-8\r\n" +
            "Content-Length: \(bodyData.count)\r\n" +
            "Connection: close\r\n\r\n"
        var fullData = Data(response.utf8)
        fullData.append(bodyData)
        return fullData
    }

    private func generateHTMLResponse(for result: ChatGPTCallbackResult) -> String {
        let isSuccess = result.error == nil && (result.code != nil)
        let title = isSuccess ? "Sign-in successful" : "Authorization canceled"
        let message = isSuccess
            ? "You can close this window and return to AudioNotes."
            : (result.errorDescription ?? "Sign in was canceled. You can return to AudioNotes.")

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>AudioNotes - \(title)</title>
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    min-height: 100vh;
                    margin: 0;
                    background-color: #f5f5f7;
                    color: #1d1d1f;
                }
                .card {
                    background: white;
                    padding: 36px 44px;
                    border-radius: 14px;
                    box-shadow: 0 4px 20px rgba(0, 0, 0, 0.08);
                    text-align: center;
                    max-width: 420px;
                }
                h1 {
                    font-size: 22px;
                    font-weight: 600;
                    margin-top: 0;
                    margin-bottom: 12px;
                }
                p {
                    font-size: 15px;
                    color: #6e6e73;
                    margin: 0;
                    line-height: 1.4;
                }
            </style>
        </head>
        <body>
            <div class="card">
                <h1>\(title)</h1>
                <p>\(message)</p>
            </div>
        </body>
        </html>
        """
    }
}
