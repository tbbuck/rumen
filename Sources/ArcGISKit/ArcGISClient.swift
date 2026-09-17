import Foundation

/// The two headers every request to an ArcGIS server carries (SPEC §5.1, hard rule).
public struct ServerHeaders: Sendable, Equatable {
    public let origin: String
    public let referer: String

    public init(origin: String, referer: String) {
        self.origin = origin
        self.referer = referer
    }

    /// Origin = the server's own origin, Referer = that origin plus `/`; either overridable.
    public static func resolve(rootURL: URL, originOverride: String? = nil, refererOverride: String? = nil) -> ServerHeaders {
        let origin = ArcGISURL.origin(of: rootURL)
        return ServerHeaders(origin: nonBlank(originOverride) ?? origin,
                             referer: nonBlank(refererOverride) ?? origin + "/")
    }

    private static func nonBlank(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}

/// Everything the client needs to talk to one registered server.
public struct ServerConnection: Sendable, Equatable {
    public let rootURL: URL
    public let headers: ServerHeaders
    /// ArcGIS token or API key, sent as the `token` parameter (SPEC §5.10). Nil for public servers.
    public var token: String?
    /// A raw `Cookie` header sent on every request, as curl's `-b` would; the session's own
    /// cookie handling is switched off for such requests so exactly this is sent.
    public var cookie: String?

    public init(rootURL: URL, headers: ServerHeaders? = nil, token: String? = nil, cookie: String? = nil) {
        self.rootURL = rootURL
        self.headers = headers ?? .resolve(rootURL: rootURL)
        self.token = token
        self.cookie = cookie
    }

    /// `https://host[:port]` — the key for the per-host concurrency cap.
    var hostKey: String { ArcGISURL.origin(of: rootURL) }
}

/// Exponential backoff with full jitter. `baseDelay` 0 makes retries immediate (tests).
public struct RetryPolicy: Sendable, Equatable {
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval

    public init(maxAttempts: Int = 5, baseDelay: TimeInterval = 0.5, maxDelay: TimeInterval = 8) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    /// Delay before retry number `attempt` (1 = the first retry).
    public func delay(beforeRetry attempt: Int) -> TimeInterval {
        guard baseDelay > 0 else { return 0 }
        let cap = min(maxDelay, baseDelay * pow(2, Double(attempt - 1)))
        return Double.random(in: 0...cap)
    }
}

public enum ArcGISClientError: Error, CustomStringConvertible, Equatable {
    /// A non-2xx HTTP status.
    case http(status: Int, url: URL)
    /// An ArcGIS error envelope (HTTP 200 with `{"error": …}`).
    case server(code: Int?, message: String, details: [String], url: URL)
    /// ArcGIS codes 498 (invalid token) and 499 (token required).
    case tokenRequired(code: Int, message: String, url: URL)
    /// URLSession-level failure (DNS, TLS, timeout, offline), after retries.
    case transport(String, url: URL)
    /// The body was not the JSON we expected (often an HTML sign-in page).
    case decoding(String, url: URL)
    /// Cancelled via task cancellation.
    case cancelled

    public var description: String {
        switch self {
        case .http(let s, let u): return "HTTP \(s) from \(u)"
        case .server(let c, let m, let d, let u):
            let code = c.map { "\($0) " } ?? ""
            let details = d.isEmpty ? "" : " (" + d.joined(separator: "; ") + ")"
            return "ArcGIS error \(code)\(m)\(details) from \(u)"
        case .tokenRequired(let c, let m, let u): return "ArcGIS \(c): \(m) — a token is required for \(u)"
        case .transport(let m, let u): return "network error: \(m) (\(u))"
        case .decoding(let m, let u): return "unexpected response from \(u): \(m)"
        case .cancelled: return "cancelled"
        }
    }

    /// Whether another attempt could plausibly succeed.
    var isRetryable: Bool {
        switch self {
        case .http(let status, _): return status == 429 || status == 500 || (502...504).contains(status)
        case .server(let code, let message, _, _):
            if code == 429 || code == 503 { return true }
            return message.lowercased().contains("timeout") || message.lowercased().contains("timed out")
        case .transport: return true
        case .tokenRequired, .decoding, .cancelled: return false
        }
    }
}

/// Bytes received so far and the total the server announced, when it announced one that can be
/// trusted (no content encoding in the way).
public struct TransferProgress: Sendable, Equatable {
    public var received: Int64
    public var expected: Int64?
    public init(received: Int64, expected: Int64?) {
        self.received = received
        self.expected = expected
    }
    /// 0...1 when the total is known.
    public var fraction: Double? { expected.flatMap { $0 > 0 ? min(1, Double(received) / Double($0)) : nil } }
}

public typealias TransferProgressHandler = @Sendable (TransferProgress) -> Void

/// The HTTP seam: `URLSession` in the app, a stub in tests.
public protocol HTTPTransport: Sendable {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Like `perform`, reporting the body as it arrives. The default reports nothing.
    func perform(_ request: URLRequest, progress: @escaping TransferProgressHandler) async throws -> (Data, HTTPURLResponse)
}

public extension HTTPTransport {
    func perform(_ request: URLRequest, progress: @escaping TransferProgressHandler) async throws -> (Data, HTTPURLResponse) {
        try await perform(request)
    }
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    /// Streams the body, reporting every 64 KB. `Content-Length` counts encoded bytes while
    /// `URLSession` hands back decoded ones, so the total is only trusted without an encoding.
    public func perform(_ request: URLRequest, progress: @escaping TransferProgressHandler) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        let encoded = http.value(forHTTPHeaderField: "Content-Encoding").map { !$0.isEmpty && $0 != "identity" } ?? false
        let expected: Int64? = (!encoded && http.expectedContentLength >= 0) ? http.expectedContentLength : nil
        var data = Data()
        if let expected { data.reserveCapacity(Int(expected)) }
        var sinceReport = 0
        progress(TransferProgress(received: 0, expected: expected))
        for try await byte in bytes {
            data.append(byte)
            sinceReport += 1
            if sinceReport >= 65_536 {
                sinceReport = 0
                progress(TransferProgress(received: Int64(data.count), expected: expected))
            }
        }
        progress(TransferProgress(received: Int64(data.count), expected: expected))
        return (data, http)
    }
}

public enum HTTPMethod: String, Sendable { case get = "GET", post = "POST" }

/// The one path to any ArcGIS server (SPEC §7.3). Sets the Origin/Referer headers on every
/// request, appends the token, caps in-flight requests per host, retries transient failures
/// with backoff, and turns HTTP failures and ArcGIS error envelopes into typed errors.
public actor ArcGISClient {
    public static let userAgent = "ArcGIS Explorer/0.1 (macOS)"

    private let transport: HTTPTransport
    private var retry: RetryPolicy
    private var maxConcurrentPerHost: Int
    private var inFlight: [String: Int] = [:]
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init(transport: HTTPTransport = URLSessionTransport(), retry: RetryPolicy = RetryPolicy(),
                maxConcurrentPerHost: Int = 4) {
        self.transport = transport
        self.retry = retry
        self.maxConcurrentPerHost = max(1, maxConcurrentPerHost)
    }

    public var limits: (maxConcurrentPerHost: Int, retry: RetryPolicy) { (maxConcurrentPerHost, retry) }

    /// Preferences changed (M9): new requests use the new retry policy at once; a raised cap
    /// wakes waiters up to it, a lowered one takes effect as requests in flight finish.
    public func setLimits(maxConcurrentPerHost: Int, retry: RetryPolicy) {
        self.maxConcurrentPerHost = max(1, maxConcurrentPerHost)
        self.retry = retry
        for host in Array(waiters.keys) {
            while inFlight[host, default: 0] < self.maxConcurrentPerHost, var queue = waiters[host], !queue.isEmpty {
                let next = queue.removeFirst()
                waiters[host] = queue
                inFlight[host, default: 0] += 1
                next.resume()
            }
        }
    }

    // MARK: - Raw requests

    /// Performs a request and returns the raw body after HTTP-status and error-envelope checks.
    /// `params` are query parameters for GET and the form body for POST; `f=json` is added
    /// unless the caller set `f`.
    public func request(_ method: HTTPMethod, url: URL, params: [String: String] = [:],
                        server: ServerConnection, maxAttempts: Int? = nil,
                        progress: TransferProgressHandler? = nil) async throws -> Data {
        var params = params
        if params["f"] == nil { params["f"] = "json" }
        if let token = server.token, params["token"] == nil { params["token"] = token }
        let request = try Self.build(method, url: url, params: params, server: server)

        await acquire(server.hostKey)
        defer { release(server.hostKey) }

        var attempt = 1
        while true {
            if Task.isCancelled { throw ArcGISClientError.cancelled }
            do {
                return try await performOnce(request, url: url, progress: progress)
            } catch let error as ArcGISClientError {
                guard error.isRetryable, attempt < (maxAttempts ?? retry.maxAttempts) else { throw error }
                let delay = retry.delay(beforeRetry: attempt)
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                attempt += 1
            }
        }
    }

    private func performOnce(_ request: URLRequest, url: URL, progress: TransferProgressHandler?) async throws -> Data {
        let data: Data
        let response: HTTPURLResponse
        do {
            if let progress {
                // Unencoded, so Content-Length counts the bytes that arrive and the percentage is honest.
                var streamed = request
                streamed.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                (data, response) = try await transport.perform(streamed, progress: progress)
            } else {
                (data, response) = try await transport.perform(request)
            }
        } catch is CancellationError {
            throw ArcGISClientError.cancelled
        } catch {
            throw ArcGISClientError.transport(error.localizedDescription, url: url)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ArcGISClientError.http(status: response.statusCode, url: url)
        }
        if let envelope = ArcGISJSON.errorEnvelope(in: data) {
            let message = envelope.error.message ?? "unknown error"
            if let code = envelope.error.code, code == 498 || code == 499 {
                throw ArcGISClientError.tokenRequired(code: code, message: message, url: url)
            }
            throw ArcGISClientError.server(code: envelope.error.code, message: message,
                                           details: envelope.error.details ?? [], url: url)
        }
        return data
    }

    /// Performs a request and decodes the JSON body. Returns the raw data too, so callers can
    /// cache it verbatim.
    public func json<T: Decodable>(_ type: T.Type, _ method: HTTPMethod = .get, url: URL,
                                   params: [String: String] = [:],
                                   server: ServerConnection, maxAttempts: Int? = nil,
                                   progress: TransferProgressHandler? = nil) async throws -> (value: T, raw: Data) {
        let data = try await request(method, url: url, params: params, server: server, maxAttempts: maxAttempts, progress: progress)
        do {
            return (try ArcGISJSON.decode(type, from: data), data)
        } catch {
            let preview = String(decoding: data.prefix(120), as: UTF8.self)
            let hint = preview.lowercased().contains("<html") ? "HTML page instead of JSON" : String(describing: error)
            throw ArcGISClientError.decoding(hint, url: url)
        }
    }

    // MARK: - Endpoint helpers

    /// The root directory, or a folder's listing when `folder` is given.
    public func serviceDirectory(_ server: ServerConnection, folder: String? = nil) async throws -> (value: ServiceDirectory, raw: Data) {
        let url = folder.map { server.rootURL.appendingPathComponent($0) } ?? server.rootURL
        return try await json(ServiceDirectory.self, url: url, server: server)
    }

    public func serviceInfo(_ server: ServerConnection, serviceURL: URL) async throws -> (value: ServiceInfo, raw: Data) {
        try await json(ServiceInfo.self, url: serviceURL, server: server)
    }

    /// The bulk `layers` endpoint: every layer and table definition in one response.
    public func layers(_ server: ServerConnection, serviceURL: URL) async throws -> (value: LayersResponse, raw: Data) {
        try await json(LayersResponse.self, url: serviceURL.appendingPathComponent("layers"), server: server)
    }

    public func layerInfo(_ server: ServerConnection, layerURL: URL) async throws -> (value: LayerInfo, raw: Data) {
        try await json(LayerInfo.self, url: layerURL, server: server)
    }

    /// `query?returnCountOnly=true` — the extractability probe and the pre-download count.
    public func count(_ server: ServerConnection, layerURL: URL, where whereClause: String = "1=1") async throws -> Int {
        let params = ["where": whereClause, "returnCountOnly": "true"]
        return try await json(CountResponse.self, .post, url: layerURL.appendingPathComponent("query"),
                              params: params, server: server).value.count
    }

    // MARK: - Request building

    static func build(_ method: HTTPMethod, url: URL, params: [String: String], server: ServerConnection) throws -> URLRequest {
        let encoded = formEncode(params)
        var request: URLRequest
        switch method {
        case .get:
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw ArcGISClientError.decoding("unbuildable URL", url: url)
            }
            components.percentEncodedQuery = encoded.isEmpty ? nil : encoded
            guard let full = components.url else { throw ArcGISClientError.decoding("unbuildable URL", url: url) }
            request = URLRequest(url: full)
        case .post:
            request = URLRequest(url: url)
            request.httpBody = Data(encoded.utf8)
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        request.httpMethod = method.rawValue
        request.setValue(server.headers.origin, forHTTPHeaderField: "Origin")
        request.setValue(server.headers.referer, forHTTPHeaderField: "Referer")
        if let cookie = server.cookie?.trimmingCharacters(in: .whitespacesAndNewlines), !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            request.httpShouldHandleCookies = false
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120
        return request
    }

    /// `application/x-www-form-urlencoded` with a strict unreserved set, sorted for stable
    /// output (tests, caching). Spaces become `%20`.
    public static func formEncode(_ params: [String: String]) -> String {
        params.keys.sorted().map { key in
            "\(percentEncode(key))=\(percentEncode(params[key] ?? ""))"
        }.joined(separator: "&")
    }

    private static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func percentEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    // MARK: - Per-host concurrency cap

    private func acquire(_ host: String) async {
        if inFlight[host, default: 0] < maxConcurrentPerHost {
            inFlight[host, default: 0] += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters[host, default: []].append(continuation)
        }
        // A releaser handed us its slot; the count was left incremented on our behalf.
    }

    private func release(_ host: String) {
        if var queue = waiters[host], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[host] = queue
            next.resume()          // slot passes straight to the waiter; inFlight unchanged
        } else {
            inFlight[host, default: 1] -= 1
        }
    }
}
