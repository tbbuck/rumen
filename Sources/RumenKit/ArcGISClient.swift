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
        case .http(let status, _): return status == 408 || status == 429 || status == 500 || (502...504).contains(status)
        case .server(let code, let message, _, _):
            if code == 429 || code == 503 { return true }
            return message.lowercased().contains("timeout") || message.lowercased().contains("timed out")
        case .transport: return true
        case .tokenRequired, .decoding, .cancelled: return false
        }
    }

    /// Whether this failure is the host saying "too much": the signal that drives the per-host
    /// concurrency back down. A 404 or a bad where clause says nothing about capacity, so it
    /// does not count — only overload, timeouts, and the gateway errors a struggling box emits.
    var isPushback: Bool {
        switch self {
        case .http(let status, _): return status == 408 || status == 429 || (500...504).contains(status)
        case .server(let code, let message, _, _):
            if code == 429 || code == 503 { return true }
            return message.lowercased().contains("timeout") || message.lowercased().contains("timed out")
        case .transport(let message, _):
            // A timed-out or dropped connection is the commonest way an overloaded server says no.
            let text = message.lowercased()
            return text.contains("timed out") || text.contains("timeout")
                || text.contains("connection lost") || text.contains("network connection was lost")
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
    public static let userAgent = "Rumen/0.1 (macOS)"

    /// What one host has shown it can actually take, discovered rather than assumed.
    ///
    /// Slow start: the cap opens at 1 and gains a slot per clean response, so it doubles each
    /// round and reaches the ceiling in a handful of requests. The first time the host pushes
    /// back the cap halves and the climb turns additive — one slot per `limit` clean responses
    /// — which is where it stays, because a box that has said no once will say it again.
    ///
    /// Probing upward from 1 costs a healthy server almost nothing (the early requests are the
    /// ones that would have run anyway), while starting at the ceiling costs a weak one a
    /// timeout per request before anything learns. The asymmetry is the whole argument.
    struct HostCapacity: Sendable {
        var limit = 1
        var ceiling: Int
        /// Clean responses since the cap last changed.
        var successes = 0
        /// True until the host first pushes back: the fast, doubling phase.
        var slowStart = true
        /// When the host asked us to come back later (`Retry-After`), the earliest time to try.
        var retryAfter: Date?
    }

    private let transport: HTTPTransport
    private var retry: RetryPolicy
    /// The user's preference: the ceiling a host may climb to, never the starting point.
    private var maxConcurrentPerHost: Int
    private var capacity: [String: HostCapacity] = [:]
    private var inFlight: [String: Int] = [:]
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// Origins that answered `405 Allow: GET` to a POST. Some proxies in front of ArcGIS route
    /// only GET; once one has said so, its later requests go out as GET without the wasted POST.
    private var getOnlyOrigins: Set<String> = []

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
        // Snapshot the keys: mutating the dictionary while iterating its own `keys` view is an
        // exclusivity violation, and traps at runtime.
        for host in Array(capacity.keys) {
            var state = capacity[host] ?? HostCapacity(ceiling: self.maxConcurrentPerHost)
            state.ceiling = self.maxConcurrentPerHost
            // A lowered ceiling takes effect at once for new requests; those already in flight
            // finish and their slots retire rather than passing on (see `release`).
            state.limit = min(state.limit, self.maxConcurrentPerHost)
            capacity[host] = state
        }
        for host in Array(waiters.keys) { wake(host) }
    }

    // MARK: - Raw requests

    /// Performs a request and returns the raw body after HTTP-status and error-envelope checks.
    /// `params` are query parameters for GET and the form body for POST; `f=json` is added
    /// unless the caller set `f`.
    public func request(_ method: HTTPMethod, url: URL, params: [String: String] = [:],
                        server: ServerConnection, maxAttempts: Int? = nil,
                        progress: TransferProgressHandler? = nil) async throws -> Data {
        var all = params
        if all["f"] == nil { all["f"] = "json" }
        if let token = server.token, all["token"] == nil { all["token"] = token }
        let sent = all
        func attempt(_ method: HTTPMethod) async throws -> Data {
            let request = try Self.build(method, url: url, params: sent, server: server)
            return try await send(request, url: url, maxAttempts: maxAttempts, progress: progress)
        }
        let origin = ArcGISURL.origin(of: url)
        guard method == .post else { return try await attempt(method) }
        if getOnlyOrigins.contains(origin) { return try await attempt(.get) }
        do {
            return try await attempt(.post)
        } catch let error as ArcGISClientError {
            guard case .http(405, _) = error else { throw error }
            // The params go into the URL instead; a long one may then be refused in its turn,
            // which the caller (the download engine) already answers by splitting the chunk.
            getOnlyOrigins.insert(origin)
            return try await attempt(.get)
        }
    }

    /// Origins known to route only GET — what a POST of theirs answered `405` to.
    public var postRefusingOrigins: Set<String> { getOnlyOrigins }

    /// A GET against an OGC endpoint (M10): the same headers, cap and retries, but no `f=json`
    /// and no token, and the root's vendor parameters (`map=`) ride along with every request.
    /// An OGC exception report in a 200 body becomes a `server` error, verbatim.
    public func fetch(root: URL, params: [String: String], server: ServerConnection, accept: String = "*/*",
                      maxAttempts: Int? = nil, progress: TransferProgressHandler? = nil) async throws -> Data {
        let (endpoint, vendor) = OGCURL.split(root)
        var all = vendor
        for (key, value) in params { all[key] = value }
        var request = try Self.build(.get, url: endpoint, params: all, server: server)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let url = request.url ?? endpoint
        let data = try await send(request, url: url, maxAttempts: maxAttempts, progress: progress)
        if Self.looksLikeXML(data), OGCCapabilities.isExceptionReport(data),
           let document = try? XMLDocument(data: data, options: []), let rootElement = document.rootElement() {
            throw ArcGISClientError.server(code: nil, message: OGCCapabilities.exceptionText(rootElement), details: [], url: url)
        }
        return data
    }

    /// Some proxies in front of ArcGIS are web-framework actions that return the server's
    /// answer as a *string*: asked for `application/json` they serialise that string, so the
    /// body is a JSON string whose content is the real document
    /// (`"{\"currentVersion\":10.81,…}"`). It is unwrapped here, once, so the probe, the crawl,
    /// queries and downloads all see the document itself — and so a wrapped `{"error":…}` is
    /// still recognised as the error it is. Anything else is returned untouched: the body must
    /// begin with the quote, parse as a JSON string, and hold an object or an array, which no
    /// ArcGIS response and no PBF body does.
    public static func unwrapJSONString(_ data: Data) -> Data {
        guard data.first == 0x22 else { return data }
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let text = parsed as? String else { return data }
        let start = text.first { !$0.isWhitespace }
        guard start == "{" || start == "[" else { return data }
        return Data(text.utf8)
    }

    public static func looksLikeXML(_ data: Data) -> Bool {
        for byte in data.prefix(64) {
            if byte == 0x3C { return true }          // '<'
            if byte != 0x20 && byte != 0x0A && byte != 0x0D && byte != 0x09 && byte != 0xEF && byte != 0xBB && byte != 0xBF { return false }
        }
        return false
    }

    /// Sends with retries, holding one of the host's slots only while a request is actually in
    /// flight. Backing off outside the slot matters: a struggling host is exactly the one whose
    /// requests retry, and sleeping on its slots starves the very requests that might succeed.
    private func send(_ request: URLRequest, url: URL, maxAttempts: Int?, progress: TransferProgressHandler?) async throws -> Data {
        let host = server(for: request)
        var attempt = 1
        while true {
            if Task.isCancelled { throw ArcGISClientError.cancelled }
            if let wait = retryAfterDelay(host) { try await Task.sleep(for: .seconds(wait)) }

            await acquire(host)
            let outcome: Result<Data, SendFailure>
            do {
                outcome = .success(try await performOnce(request, url: url, progress: progress))
            } catch let failure as SendFailure {
                outcome = .failure(failure)
            }

            switch outcome {
            case .success(let data):
                noteSuccess(host)
                release(host)
                return data
            case .failure(let failure):
                release(host)          // free the slot before any backoff
                if failure.error.isPushback { notePushback(host, retryAfter: failure.retryAfter) }
                guard failure.error.isRetryable, attempt < (maxAttempts ?? retry.maxAttempts) else { throw failure.error }
                // The host's own Retry-After beats our guess at a delay.
                let delay = failure.retryAfter ?? retry.delay(beforeRetry: attempt)
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                attempt += 1
            }
        }
    }

    /// A failed attempt plus what the host said about coming back, kept internal so the public
    /// error enum (which callers pattern-match on) does not grow a case for it.
    private struct SendFailure: Error {
        let error: ArcGISClientError
        let retryAfter: TimeInterval?
    }

    /// `Retry-After`, as either delay-seconds or an HTTP date. Absurd values are ignored rather
    /// than trusted: a server asking us to wait an hour gets our own backoff instead.
    public static func retryAfter(_ header: String?) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
        if let seconds = TimeInterval(header) {
            return seconds > 0 && seconds <= 300 ? seconds : nil
        }
        guard let date = httpDateFormatter.date(from: header) else { return nil }
        let delay = date.timeIntervalSinceNow
        return delay > 0 && delay <= 300 ? delay : nil
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    /// The per-host key of a built request.
    private func server(for request: URLRequest) -> String {
        request.url.map { ArcGISURL.origin(of: $0) } ?? ""
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
            throw SendFailure(error: .cancelled, retryAfter: nil)
        } catch {
            throw SendFailure(error: .transport(error.localizedDescription, url: url), retryAfter: nil)
        }
        let retryAfter = Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After"))
        guard (200..<300).contains(response.statusCode) else {
            throw SendFailure(error: .http(status: response.statusCode, url: url), retryAfter: retryAfter)
        }
        let body = Self.unwrapJSONString(data)
        if let envelope = ArcGISJSON.errorEnvelope(in: body) {
            let message = envelope.error.message ?? "unknown error"
            if let code = envelope.error.code, code == 498 || code == 499 {
                throw SendFailure(error: .tokenRequired(code: code, message: message, url: url), retryAfter: nil)
            }
            throw SendFailure(error: .server(code: envelope.error.code, message: message,
                                             details: envelope.error.details ?? [], url: url),
                              retryAfter: retryAfter)
        }
        return body
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

    /// This host's learned capacity, opened at one slot on first sight and climbed from there.
    private func capacity(for host: String) -> HostCapacity {
        if let existing = capacity[host] { return existing }
        let fresh = HostCapacity(limit: 1, ceiling: maxConcurrentPerHost)
        capacity[host] = fresh
        return fresh
    }

    /// What a host has been allowed to reach, for the UI and the tests.
    public func concurrencyLimit(forHost host: String) -> Int { capacity(for: host).limit }

    /// Seeds a host's cap from what a previous run learned, clamped to the current ceiling.
    /// A remembered cap skips the climb; it never exceeds the user's preference.
    public func seedConcurrency(_ limit: Int, forHost host: String) {
        var state = capacity(for: host)
        state.limit = max(1, min(limit, state.ceiling))
        state.slowStart = false      // a remembered value is already past the probing phase
        state.successes = 0
        capacity[host] = state
        wake(host)
    }

    /// A clean response: climb, doubling while still in slow start and additively after.
    private func noteSuccess(_ host: String) {
        var state = capacity(for: host)
        state.retryAfter = nil
        guard state.limit < state.ceiling else {
            state.successes = 0
            capacity[host] = state
            return
        }
        state.successes += 1
        // Slow start gains a slot per response (so the cap doubles each round); afterwards one
        // slot per full round of clean responses at the current cap.
        let needed = state.slowStart ? 1 : state.limit
        if state.successes >= needed {
            state.limit = min(state.ceiling, state.limit + 1)
            state.successes = 0
        }
        capacity[host] = state
        wake(host)
    }

    /// The host pushed back: halve the cap and leave slow start for good.
    private func notePushback(_ host: String, retryAfter: TimeInterval?) {
        var state = capacity(for: host)
        state.limit = max(1, state.limit / 2)
        state.slowStart = false
        state.successes = 0
        if let retryAfter { state.retryAfter = Date().addingTimeInterval(retryAfter) }
        capacity[host] = state
    }

    /// How long this host asked us to wait, if it did and the moment has not passed.
    private func retryAfterDelay(_ host: String) -> TimeInterval? {
        guard let until = capacity[host]?.retryAfter else { return nil }
        let remaining = until.timeIntervalSinceNow
        return remaining > 0 ? remaining : nil
    }

    private func acquire(_ host: String) async {
        if inFlight[host, default: 0] < capacity(for: host).limit {
            inFlight[host, default: 0] += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters[host, default: []].append(continuation)
        }
        // A releaser handed us its slot; the count was left incremented on our behalf.
    }

    private func release(_ host: String) {
        // Hand the slot straight on only while the cap still allows it: after a halving the
        // in-flight count can sit above the new limit, and those slots must retire, not pass on.
        if inFlight[host, default: 0] <= capacity(for: host).limit, var queue = waiters[host], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[host] = queue
            next.resume()          // slot passes straight to the waiter; inFlight unchanged
        } else {
            inFlight[host, default: 1] -= 1
        }
    }

    /// Lets waiters in up to the host's current cap.
    private func wake(_ host: String) {
        while inFlight[host, default: 0] < capacity(for: host).limit, var queue = waiters[host], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[host] = queue
            inFlight[host, default: 0] += 1
            next.resume()
        }
    }
}
