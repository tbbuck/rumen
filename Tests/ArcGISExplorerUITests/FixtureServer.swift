import Foundation
import Network

/// A small ArcGIS REST server on the loopback interface, synthesised in this process, so the
/// app under test can open a server, crawl it, preview a layer and download it with no
/// network and no recorded fixtures. One folder, a JSON-only FeatureServer with a layer and a
/// table, and a MapServer; every query is answered from the request's parameters.
final class FixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fixture-server")
    private let lock = NSLock()
    private var requestPaths: [String] = []
    private(set) var port: UInt16 = 0

    static let root = "/arcgis/rest/services"
    static let featureCount = 120
    static let pageSize = 50

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else {
            throw FixtureServerError.notReady
        }
        self.port = port
    }

    deinit { listener.cancel() }

    var rootURL: String { "http://127.0.0.1:\(port)\(Self.root)" }
    var layerURL: String { rootURL + "/Places/FeatureServer/0" }

    /// Every request path served so far.
    var paths: [String] { lock.withLock { requestPaths } }

    // MARK: - HTTP

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = HTTPRequest(buffer) {
                self.respond(connection, to: request)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.read(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, to request: HTTPRequest) {
        lock.withLock { requestPaths.append(request.path) }
        let reply = route(request)
        var head = "HTTP/1.1 \(reply.status) \(reply.status == 200 ? "OK" : "Error")\r\n"
        head += "Content-Type: \(reply.contentType)\r\nContent-Length: \(reply.body.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(reply.body)
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - Routing

    struct Reply {
        var status = 200
        var contentType = "application/json; charset=utf-8"
        var body: Data
        static func json(_ text: String, status: Int = 200) -> Reply { Reply(status: status, body: Data(text.utf8)) }
    }

    private func route(_ request: HTTPRequest) -> Reply {
        let r = Self.root
        switch request.path {
        case r:
            return .json(#"{"currentVersion":11.1,"folders":["Utilities"],"services":[{"name":"Places","type":"FeatureServer"},{"name":"Basemap","type":"MapServer"}]}"#)
        case "\(r)/Utilities":
            return .json(#"{"currentVersion":11.1,"folders":[],"services":[{"name":"Utilities/Geometry","type":"GeometryServer"}]}"#)
        case "\(r)/Places/FeatureServer":
            return .json(#"{"currentVersion":11.1,"serviceDescription":"Towns and notes, synthesised for the UI tests.","supportedQueryFormats":"JSON","maxRecordCount":\#(Self.pageSize),"capabilities":"Query","spatialReference":{"wkid":4326},"fullExtent":\#(Self.extentJSON),"layers":[{"id":0,"name":"Towns","type":"Feature Layer","geometryType":"esriGeometryPoint"}],"tables":[{"id":1,"name":"Notes","type":"Table"}]}"#)
        case "\(r)/Places/FeatureServer/layers":
            return .json(#"{"layers":[\#(Self.townsJSON)],"tables":[\#(Self.notesJSON)]}"#)
        case "\(r)/Places/FeatureServer/0":
            return .json(Self.townsJSON)
        case "\(r)/Places/FeatureServer/1":
            return .json(Self.notesJSON)
        case "\(r)/Places/FeatureServer/0/query":
            return query(request.params)
        case "\(r)/Places/FeatureServer/1/query":
            return .json(#"{"fields":[{"name":"OBJECTID","type":"esriFieldTypeOID"},{"name":"NOTE","type":"esriFieldTypeString","length":80}],"features":[{"attributes":{"OBJECTID":1,"NOTE":"First note"}}],"exceededTransferLimit":false}"#)
        case "\(r)/Basemap/MapServer":
            return .json(#"{"currentVersion":11.1,"serviceDescription":"A drawn basemap.","capabilities":"Map,Query","supportedQueryFormats":"JSON","maxRecordCount":1000,"spatialReference":{"wkid":4326},"fullExtent":\#(Self.extentJSON),"layers":[{"id":0,"name":"Roads","type":"Feature Layer","geometryType":"esriGeometryPolyline"}],"tables":[]}"#)
        case "\(r)/Basemap/MapServer/layers":
            return .json("missing", status: 404)   // forces the per-layer fallback, as older servers do
        case "\(r)/Basemap/MapServer/0":
            return .json(#"{"id":0,"name":"Roads","type":"Feature Layer","geometryType":"esriGeometryPolyline","capabilities":"Map,Query","supportedQueryFormats":"JSON","maxRecordCount":1000,"objectIdField":"OBJECTID","extent":\#(Self.extentJSON),"fields":[{"name":"OBJECTID","type":"esriFieldTypeOID"},{"name":"NAME","type":"esriFieldTypeString","length":40}]}"#)
        default:
            if request.path.hasSuffix("/GeometryServer") { return .json(#"{"currentVersion":11.1,"serviceDescription":"Geometry"}"#) }
            return .json(#"{"error":{"code":404,"message":"not served: \#(request.path)","details":[]}}"#, status: 200)
        }
    }

    static let extentJSON = #"{"xmin":-3.5,"ymin":50.2,"xmax":-2.0,"ymax":51.0,"spatialReference":{"wkid":4326}}"#
    static let fieldsJSON = #"[{"name":"OBJECTID","type":"esriFieldTypeOID","alias":"OBJECTID"},{"name":"NAME","type":"esriFieldTypeString","alias":"Name","length":40},{"name":"POP","type":"esriFieldTypeInteger","alias":"Population"},{"name":"WHEN","type":"esriFieldTypeDate","alias":"Recorded"}]"#
    static let townsJSON = #"{"id":0,"name":"Towns","type":"Feature Layer","description":"Every town, synthesised.","geometryType":"esriGeometryPoint","objectIdField":"OBJECTID","displayField":"NAME","hasZ":false,"hasM":false,"maxRecordCount":\#(pageSize),"supportedQueryFormats":"JSON","capabilities":"Query","supportsStatistics":true,"advancedQueryCapabilities":{"supportsPagination":true,"supportsStatistics":true,"supportsOrderBy":true,"supportsDistinct":true,"supportsReturningQueryExtent":true},"extent":\#(extentJSON),"fields":\#(fieldsJSON)}"#
    static let notesJSON = #"{"id":1,"name":"Notes","type":"Table","objectIdField":"OBJECTID","maxRecordCount":\#(pageSize),"supportedQueryFormats":"JSON","capabilities":"Query","advancedQueryCapabilities":{"supportsPagination":true},"fields":[{"name":"OBJECTID","type":"esriFieldTypeOID"},{"name":"NOTE","type":"esriFieldTypeString","length":80}]}"#

    private static func feature(_ oid: Int) -> String {
        let x = -3.5 + Double(oid % 30) * 0.05
        let y = 50.2 + Double(oid / 30) * 0.2
        return #"{"attributes":{"OBJECTID":\#(oid),"NAME":"Town \#(oid)","POP":\#(oid * 250),"WHEN":1782132691000},"geometry":{"x":\#(x),"y":\#(y)}}"#
    }

    /// Answers a layer query the way a JSON-only, paging ArcGIS Server would.
    private func query(_ params: [String: String]) -> Reply {
        let total = Self.featureCount
        if params["f"] == "pbf" { return .json(#"{"error":{"code":400,"message":"Unsupported format: pbf","details":[]}}"#) }
        if params["returnCountOnly"] == "true" { return .json(#"{"count":\#(total)}"#) }
        if params["returnExtentOnly"] == "true" { return .json(#"{"extent":\#(Self.extentJSON)}"#) }
        if params["returnIdsOnly"] == "true" {
            return .json(#"{"objectIdFieldName":"OBJECTID","objectIds":[\#((1...total).map(String.init).joined(separator: ","))]}"#)
        }
        if let stats = params["outStatistics"], let data = stats.data(using: .utf8),
           let definitions = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let values = definitions.map { definition -> String in
                let name = definition["outStatisticFieldName"] as? String ?? "value"
                let value: Int = switch definition["statisticType"] as? String { case "min": 1; case "max": total; case "count": total; default: 42 }
                return "\"\(name)\":\(value)"
            }
            return .json(#"{"fields":[],"features":[{"attributes":{\#(values.joined(separator: ","))}}]}"#)
        }
        if params["returnDistinctValues"] == "true" {
            let rows = (1...10).map { #"{"attributes":{"NAME":"Town \#($0)"}}"# }.joined(separator: ",")
            return .json(#"{"fields":[{"name":"NAME","type":"esriFieldTypeString"}],"features":[\#(rows)]}"#)
        }
        var ids: [Int]
        var exceeded = false
        if let offset = params["resultOffset"].flatMap(Int.init) {
            let count = params["resultRecordCount"].flatMap(Int.init) ?? Self.pageSize
            ids = offset < total ? Array((offset + 1)...min(total, offset + count)) : []
            exceeded = offset + count < total
        } else if let list = params["objectIds"] {
            ids = list.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        } else {
            let count = params["resultRecordCount"].flatMap(Int.init) ?? Self.pageSize
            ids = Array(1...min(total, count))
            exceeded = total > count
        }
        let features = ids.map(Self.feature).joined(separator: ",")
        return .json(#"{"geometryType":"esriGeometryPoint","spatialReference":{"wkid":4326},"fields":\#(Self.fieldsJSON),"features":[\#(features)],"exceededTransferLimit":\#(exceeded)}"#)
    }
}

enum FixtureServerError: Error { case notReady }

/// The parts of an HTTP/1.1 request the fixture server needs: the path, and the parameters
/// from the query string and a form body combined.
struct HTTPRequest {
    let path: String
    let params: [String: String]

    /// nil until the whole request (head plus any Content-Length body) has arrived.
    init?(_ data: Data) {
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<headEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let contentLength = lines.dropFirst().compactMap { line -> Int? in
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2, pair[0].lowercased() == "content-length" else { return nil }
            return Int(pair[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        let body = data[headEnd.upperBound...]
        guard body.count >= contentLength else { return nil }
        let target = String(parts[1])
        let split = target.split(separator: "?", maxSplits: 1)
        path = String(split[0])
        var params = Self.decodeForm(split.count > 1 ? String(split[1]) : "")
        for (key, value) in Self.decodeForm(String(decoding: body.prefix(contentLength), as: UTF8.self)) { params[key] = value }
        self.params = params
    }

    private static func decodeForm(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            let key = String(kv[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(kv[0])
            let value = kv.count > 1 ? (String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(kv[1])) : ""
            result[key] = value
        }
        return result
    }
}
