import Foundation
import RumenKit

/// An `HTTPTransport` that answers from a handler and records every request, so client
/// behaviour (headers, encoding, retries, concurrency) is testable without a network.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    struct Reply {
        var status: Int = 200
        var body: Data = Data()
        static func json(_ text: String, status: Int = 200) -> Reply { Reply(status: status, body: Data(text.utf8)) }
        static func fixture(_ name: String) throws -> Reply { Reply(body: try Fixtures.data(name)) }
    }

    typealias Handler = @Sendable (URLRequest, Int) throws -> Reply

    private let lock = NSLock()
    private var handler: Handler
    private(set) var requests: [URLRequest] = []
    private var concurrent = 0
    private(set) var maxConcurrent = 0
    var delay: Duration = .zero
    /// Awaited before answering; lets a test hold selected requests open (cancellation-aware).
    var gate: (@Sendable (URLRequest) async throws -> Void)?

    init(_ handler: @escaping Handler) { self.handler = handler }

    convenience init(reply: Reply) { self.init { _, _ in reply } }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index: Int = lock.withLock {
            requests.append(request)
            concurrent += 1
            maxConcurrent = max(maxConcurrent, concurrent)
            return requests.count
        }
        defer { lock.withLock { concurrent -= 1 } }
        if delay > .zero { try await Task.sleep(for: delay) }
        if let gate { try await gate(request) }
        let reply = try handler(request, index)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        return (reply.body, response)
    }

    var count: Int { lock.withLock { requests.count } }
    var last: URLRequest? { lock.withLock { requests.last } }
}

extension URLRequest {
    /// The form body as a string (POST) or the percent-encoded query (GET).
    var encodedParams: String {
        if let body = httpBody { return String(decoding: body, as: UTF8.self) }
        return url?.query ?? ""
    }
}
