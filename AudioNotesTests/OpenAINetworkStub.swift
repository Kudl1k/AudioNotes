import Foundation
import Synchronization

/// Each session has its own scenario; parallel tests cannot steal one another's requests.
final class NetworkProbe: Sendable {
    let requests = Mutex<[URLRequest]>([])
    let requestBodies = Mutex<[Data]>([])
    let started: AsyncStream<Void>
    let stopped: AsyncStream<Void>
    let startSignal: AsyncStream<Void>.Continuation
    let stopSignal: AsyncStream<Void>.Continuation

    init() {
        (started, startSignal) = AsyncStream.makeStream(of: Void.self)
        (stopped, stopSignal) = AsyncStream.makeStream(of: Void.self)
    }
}

final class OpenAIStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Scenario: Sendable {
        struct Response: Sendable {
            let status: Int
            let data: Data
            let errorsBeforeSuccess: [URLError.Code]

            init(status: Int, data: Data, errorsBeforeSuccess: [URLError.Code] = []) {
                self.status = status
                self.data = data
                self.errorsBeforeSuccess = errorsBeforeSuccess
            }
        }
        let status: Int
        let data: Data
        let error: URLError.Code?
        let suspend: Bool
        let probe: NetworkProbe
        let responsesByPath: [String: Response]
    }
    static let scenarios = Mutex<[String: Scenario]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let scenario = scenario else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        scenario.probe.requests.withLock { $0.append(request) }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        scenario.probe.requestBodies.withLock { $0.append(body) }
        scenario.probe.startSignal.yield(())
        if scenario.suspend { return }
        if let error = scenario.error {
            client?.urlProtocol(self, didFailWithError: URLError(error))
            return
        }
        let route = scenario.responsesByPath[request.url?.path ?? ""]
        let pathAttempt = scenario.probe.requests.withLock { requests in
            requests.filter { $0.url?.path == request.url?.path }.count
        }
        if let route, pathAttempt <= route.errorsBeforeSuccess.count {
            client?.urlProtocol(self, didFailWithError: URLError(route.errorsBeforeSuccess[pathAttempt - 1]))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: route?.status ?? scenario.status,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: route?.data ?? scenario.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { scenario?.probe.stopSignal.yield(()) }

    private var scenario: Scenario? {
        guard let id = request.value(forHTTPHeaderField: "X-AudioNotes-Test-ID") else { return nil }
        return Self.scenarios.withLock { $0[id] }
    }
}

struct OpenAINetworkFixture {
    let id = UUID().uuidString
    let probe = NetworkProbe()
    let session: URLSession

    init(status: Int = 200, data: Data, error: URLError.Code? = nil, suspend: Bool = false,
         responsesByPath: [String: OpenAIStubURLProtocol.Scenario.Response] = [:]) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenAIStubURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-AudioNotes-Test-ID": id]
        session = URLSession(configuration: configuration)
        OpenAIStubURLProtocol.scenarios.withLock {
            $0[id] = .init(status: status, data: data, error: error, suspend: suspend, probe: probe, responsesByPath: responsesByPath)
        }
    }

    func cleanUp() {
        session.invalidateAndCancel()
        _ = OpenAIStubURLProtocol.scenarios.withLock { $0.removeValue(forKey: id) }
        probe.startSignal.finish()
        probe.stopSignal.finish()
    }
}
