import Foundation
import Network

/// A one-endpoint HTTP server on the loopback interface, so the real `URLSessionTransport` can
/// be exercised without a network or a recorded fixture. It answers every request with the same
/// body, written in chunks so a streaming reader sees more than one.
final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-server")
    private let body: Data
    private let chunkSize: Int
    private let headers: [String: String]
    private(set) var port: UInt16 = 0

    init(body: Data, chunkSize: Int = 32 * 1024, headers: [String: String] = [:]) throws {
        self.body = body
        self.chunkSize = max(1, chunkSize)
        self.headers = headers
        // Loopback only: listening on every interface asks for macOS's Local Network permission.
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)

        let ready = DispatchSemaphore(value: 0)
        let box = PortBox()
        listener.stateUpdateHandler = { [listener] state in
            switch state {
            case .ready: box.port = listener.port?.rawValue ?? 0; ready.signal()
            case .failed(let error): box.failure = String(describing: error); ready.signal()
            case .cancelled: box.failure = "cancelled"; ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, box.failure == nil else {
            listener.cancel()
            throw LoopbackError.notReady(box.failure ?? "no ready state within 5s")
        }
        port = box.port
    }

    deinit { listener.cancel() }

    func stop() { listener.cancel() }

    var url: URL { URL(string: "http://127.0.0.1:\(port)/thing")! }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(connection, accumulated: Data())
    }

    /// Reads until the end of the request head, then answers. The body of a POST is drained
    /// along with it; nothing here inspects it.
    private func readRequest(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }
            if error != nil || (isComplete && buffer.isEmpty) {
                connection.cancel()
                return
            }
            guard buffer.range(of: Data("\r\n\r\n".utf8)) != nil else {
                self.readRequest(connection, accumulated: buffer)
                return
            }
            self.respond(connection)
        }
    }

    private func respond(_ connection: NWConnection) {
        var head = "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nContent-Type: application/json\r\n"
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        head += "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })

        var offset = 0
        while offset < body.count {
            let end = min(body.count, offset + chunkSize)
            connection.send(content: body.subdata(in: offset..<end), completion: .contentProcessed { _ in })
            offset = end
        }
        // Half-close rather than cancel: `cancel()` tears the socket down, and a client that has
        // not yet drained what was queued sees a truncated body and waits for the rest forever.
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    private final class PortBox: @unchecked Sendable {
        var port: UInt16 = 0
        var failure: String?
    }
}

enum LoopbackError: Error, CustomStringConvertible {
    case notReady(String)
    var description: String {
        switch self {
        case .notReady(let why): return "loopback server not ready: \(why)"
        }
    }
}
