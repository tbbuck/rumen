import Foundation

// A URL outside the `rest/services` shape is neither refused nor taken for OGC until it has
// been asked what it is (decision 19). Councils put ArcGIS services behind proxies that hide
// the directory: `…/EplanningV2/API/v1/Map/3?f=json` answers with an ordinary MapServer layer.

/// What one `f=json` body is, judged by its keys.
public enum ArcGISDocument: Sendable, Equatable {
    /// A services directory: `services` and/or `folders`.
    case directory(version: Double?)
    /// A Map or Feature service: `layers` beside the service-level keys.
    case service(type: ServiceType, version: Double?)
    /// A layer or table: an `id` and a `name`, with fields, a geometry type or a layer type.
    case layer(id: Int, version: Double?)
}

/// What a URL outside the `rest/services` shape turned out to be, at the root it belongs to.
public enum ArcGISProbeFinding: Sendable, Equatable {
    /// A services directory reached without the usual `rest/services` path.
    case directory(rootURL: URL, version: Double?)
    /// A lone Map or Feature service with no directory above it.
    case service(serviceURL: URL, type: ServiceType, version: Double?)
    /// A layer of such a service.
    case layer(serviceURL: URL, type: ServiceType, layerID: Int, version: Double?)

    /// The server kind the finding registers as: a directory is an ordinary ArcGIS root.
    public var kind: ServerKind {
        if case .directory = self { return .arcgis }
        return .service
    }

    /// Where the URL pointed, in the real or the one-service hierarchy.
    public var location: ArcGISLocation {
        switch self {
        case .directory(let rootURL, _):
            return ArcGISLocation(rootURL: rootURL)
        case .service(let serviceURL, let type, _):
            return ArcGISLocation(rootURL: serviceURL, servicePath: ArcGISURL.lastSegment(of: serviceURL),
                                  serviceType: type, rootIsService: true)
        case .layer(let serviceURL, let type, let layerID, _):
            return ArcGISLocation(rootURL: serviceURL, servicePath: ArcGISURL.lastSegment(of: serviceURL),
                                  serviceType: type, layerID: layerID, rootIsService: true)
        }
    }
}

/// The outcome of asking a URL what it is.
public enum ArcGISProbeOutcome: Sendable, Equatable {
    case found(ArcGISProbeFinding)
    /// The URL answered with ArcGIS's token wall (498 or 499): it is ArcGIS, and it wants a
    /// token or a cookie. The error is the server's, verbatim. Any other error envelope is
    /// only a hint, so it goes into the reason and OGC is still tried.
    case refused(ArcGISClientError)
    /// Not ArcGIS, and why — for the message when OGC does not answer either.
    case notArcGIS(reason: String)
}

public enum ArcGISProbeError: Error, CustomStringConvertible, Equatable {
    /// Outside the `rest/services` shape, and neither ArcGIS nor WMS, WFS or WMTS answered.
    case nothingAnswered(url: URL, arcgis: String, ogc: [String])
    /// A `ServerKind.service` root that no longer answers as a service.
    case notAService(url: URL, found: String)

    public var description: String {
        switch self {
        case .nothingAnswered(let url, let arcgis, let ogc):
            return "\(url) is not in the rest/services shape, did not answer as ArcGIS (\(arcgis)), "
                + "and answered none of WMS, WFS or WMTS: " + ogc.joined(separator: "; ")
        case .notAService(let url, let found):
            return "\(url) no longer answers as an ArcGIS service (got \(found))"
        }
    }
}

public enum ArcGISProbe {
    /// Layer `type` values ArcGIS uses, for a layer body with neither fields nor a geometry
    /// type (a group layer).
    static let layerTypes: Set<String> = ["Feature Layer", "Table", "Group Layer", "Raster Layer", "Annotation Layer",
                                          "Dimension Layer", "Mosaic Layer", "Network Analysis Layer", "Catalog Layer",
                                          "Utility Network Layer"]

    /// Classifies one `f=json` body by its keys. Nil when it is not JSON, or JSON that is not
    /// an ArcGIS directory, service or layer.
    public static func classify(_ data: Data) -> ArcGISDocument? {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data), let object = json.objectValue else { return nil }
        let version = object["currentVersion"].flatMap { $0.doubleValue ?? $0.stringValue.flatMap(Double.init) }
        if object["services"]?.arrayValue != nil || object["folders"]?.arrayValue != nil {
            return .directory(version: version)
        }
        if object["layers"]?.arrayValue != nil,
           object["mapName"] != nil || object["serviceDescription"] != nil || object["capabilities"] != nil
            || object["tables"] != nil || object["spatialReference"] != nil {
            // A map service names its map and its image formats; a feature service does neither.
            let isMap = object["mapName"] != nil || object["singleFusedMapCache"] != nil
                || object["supportedImageFormatTypes"] != nil
            return .service(type: isMap ? .mapServer : .featureServer, version: version)
        }
        if let id = object["id"]?.intValue, object["name"]?.stringValue != nil,
           object["fields"]?.arrayValue != nil || object["geometryType"] != nil
            || layerTypes.contains(object["type"]?.stringValue ?? "") {
            return .layer(id: id, version: version)
        }
        return nil
    }

    /// A few words on what a body is, for a message: its top-level keys, or its first bytes.
    public static func describe(_ data: Data) -> String {
        if let json = try? JSONDecoder().decode(JSONValue.self, from: data), let object = json.objectValue {
            let keys = object.keys.sorted().prefix(6).joined(separator: ", ")
            return "JSON with keys \(keys)\(object.count > 6 ? ", …" : "")"
        }
        let preview = String(decoding: data.prefix(80), as: UTF8.self).replacingOccurrences(of: "\n", with: " ")
        if preview.lowercased().contains("<html") { return "an HTML page" }
        return preview.isEmpty ? "an empty body" : "'\(preview)'"
    }
}

private extension ArcGISClientError {
    /// ArcGIS's own 498/499: nothing else answers `f=json` that way.
    var isTokenWall: Bool {
        if case .tokenRequired = self { return true }
        return false
    }
}

extension Crawler {
    /// Asks a URL outside the `rest/services` shape what it is, with the headers and cookie a
    /// new server would use: one `f=json` request, and a second for the parent when the first
    /// answers as a layer (a layer is addressed by its id under its service, so the URL must
    /// end in that id and the parent must be a service). Two attempts per request, so a dead
    /// host is quick to say so.
    public func probeArcGIS(_ text: String, headerOverrides: (origin: String?, referer: String?)? = nil,
                            cookie: String? = nil, proxyURL: String? = nil) async throws -> ArcGISProbeOutcome {
        let bare = try ArcGISURL.bareURL(text)
        func ask(_ url: URL) async throws -> Result<Data, ArcGISClientError> {
            let connection = ServerConnection(rootURL: url,
                                              headers: .resolve(rootURL: url, originOverride: headerOverrides?.origin,
                                                                refererOverride: headerOverrides?.referer),
                                              cookie: cookie, proxyURL: proxyURL)
            do {
                return .success(try await client.request(.get, url: url, server: connection, maxAttempts: 2))
            } catch let error as ArcGISClientError {
                if error == .cancelled { throw error }
                return .failure(error)
            }
        }
        let first: Data
        switch try await ask(bare) {
        case .success(let data): first = data
        case .failure(let error):
            return error.isTokenWall ? .refused(error) : .notArcGIS(reason: String(describing: error))
        }
        switch ArcGISProbe.classify(first) {
        case nil:
            return .notArcGIS(reason: "\(bare)?f=json answered with \(ArcGISProbe.describe(first))")
        case .directory(let version)?:
            return .found(.directory(rootURL: bare, version: version))
        case .service(let type, let version)?:
            return .found(.service(serviceURL: bare, type: type, version: version))
        case .layer(let id, _)?:
            guard ArcGISURL.lastSegment(of: bare) == String(id), let parent = ArcGISURL.parent(of: bare) else {
                return .notArcGIS(reason: "\(bare)?f=json answered as layer \(id), but the URL does not end in /\(id)")
            }
            let second: Data
            switch try await ask(parent) {
            case .success(let data): second = data
            case .failure(let error):
                if error.isTokenWall { return .refused(error) }
                return .notArcGIS(reason: "\(bare)?f=json answered as layer \(id), but its service \(parent) did not: \(error)")
            }
            guard case .service(let type, let version)? = ArcGISProbe.classify(second) else {
                return .notArcGIS(reason: "\(bare)?f=json answered as layer \(id), but \(parent) is not a service "
                                  + "(got \(ArcGISProbe.describe(second)))")
            }
            return .found(.layer(serviceURL: parent, type: type, layerID: id, version: version))
        }
    }
}
