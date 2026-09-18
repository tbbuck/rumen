import Foundation

/// The kind of ArcGIS service a URL segment names. Only Map and Feature services carry
/// queryable layers; the rest are listed and described, never downloaded.
public enum ServiceType: Sendable, Equatable, Hashable {
    case mapServer
    case featureServer
    case imageServer
    /// OGC services at an OGC endpoint (M10), never ArcGIS's own `WMSServer` extensions.
    case wms
    case wfs
    case wmts
    case other(String)

    /// Canonical casing as ArcGIS publishes it, e.g. `FeatureServer`; the plain acronym for OGC.
    public var name: String {
        switch self {
        case .mapServer: return "MapServer"
        case .featureServer: return "FeatureServer"
        case .imageServer: return "ImageServer"
        case .wms: return "WMS"
        case .wfs: return "WFS"
        case .wmts: return "WMTS"
        case .other(let s): return s
        }
    }

    /// True when the service can contain layers/tables that `query` applies to, or OGC layers.
    public var hasLayers: Bool { self == .mapServer || self == .featureServer || isOGC }

    public var isOGC: Bool { self == .wms || self == .wfs || self == .wmts }

    /// Every service type ArcGIS REST can list, matched case-insensitively.
    static let known = ["MapServer", "FeatureServer", "ImageServer", "GPServer", "GeocodeServer",
                        "GeometryServer", "NAServer", "SceneServer", "VectorTileServer",
                        "WFSServer", "WMSServer", "WCSServer", "WMTSServer", "StreamServer",
                        "GlobeServer", "MobileServer", "SchematicsServer", "OGCFeatureServer",
                        "KnowledgeGraphServer", "VideoServer", "UtilityNetworkServer",
                        "ParcelFabricServer", "ValidationServer", "VersionManagementServer"]

    init(_ raw: String) {
        switch raw.lowercased() {
        case "mapserver": self = .mapServer
        case "featureserver": self = .featureServer
        case "imageserver": self = .imageServer
        case "wms": self = .wms
        case "wfs": self = .wfs
        case "wmts": self = .wmts
        default:
            self = .other(Self.known.first { $0.lowercased() == raw.lowercased() } ?? raw)
        }
    }

    static func matches(_ segment: String) -> Bool {
        known.contains { $0.lowercased() == segment.lowercased() }
    }
}

/// Where in an ArcGIS REST hierarchy a pasted URL points (SPEC §5.1).
public struct ArcGISLocation: Sendable, Equatable {
    /// The server root, `https://host[/instance]/rest/services`, no trailing slash. This is
    /// the unit the app remembers and names. For a lone service (`rootIsService`) it is the
    /// service URL itself.
    public let rootURL: URL
    /// Folder path below the root, `"A/B"`, or nil at the root. When a service is present this
    /// is the folder that contains it.
    public let folderPath: String?
    /// Service name as ArcGIS lists it in the directory: `"Folder/Name"` or `"Name"`.
    public let servicePath: String?
    public let serviceType: ServiceType?
    public let layerID: Int?
    /// The root is itself the service (`ServerKind.service`): a Map or Feature service reached
    /// on its own, with no directory above it (decision 19).
    public let rootIsService: Bool

    public init(rootURL: URL, folderPath: String? = nil, servicePath: String? = nil,
                serviceType: ServiceType? = nil, layerID: Int? = nil, rootIsService: Bool = false) {
        self.rootURL = rootURL
        self.folderPath = folderPath
        self.servicePath = servicePath
        self.serviceType = serviceType
        self.layerID = layerID
        self.rootIsService = rootIsService
    }

    /// `https://host/…/rest/services/Folder/Name/FeatureServer`, when a service is named; the
    /// root itself for a lone service.
    public var serviceURL: URL? {
        if rootIsService { return rootURL }
        guard let servicePath, let serviceType else { return nil }
        return rootURL.appendingPathComponent(servicePath).appendingPathComponent(serviceType.name)
    }

    /// `…/FeatureServer/3`, when a layer is named.
    public var layerURL: URL? {
        guard let serviceURL, let layerID else { return nil }
        return serviceURL.appendingPathComponent(String(layerID))
    }

    /// `…/rest/services/Folder`, or the root when at the top.
    public var folderURL: URL {
        guard let folderPath else { return rootURL }
        return rootURL.appendingPathComponent(folderPath)
    }

    /// The origin the app sends as `Origin` (and, with a trailing slash, as `Referer`).
    public var origin: String { ArcGISURL.origin(of: rootURL) }
}

public enum ArcGISURLError: Error, Equatable, CustomStringConvertible {
    case empty
    case malformed(String)
    /// The URL has no `rest/services` segment, so it is not an ArcGIS REST endpoint by shape.
    /// It may still be one behind a proxy: see `ArcGISURL.resolve` and `Crawler.probeArcGIS`.
    case notArcGIS(String)

    public var description: String {
        switch self {
        case .empty: return "no URL given"
        case .malformed(let s): return "'\(s)' is not a valid URL"
        case .notArcGIS(let s):
            return "'\(s)' is not an ArcGIS REST URL (expected …/rest/services/…)"
        }
    }
}

/// Parses anything in an ArcGIS REST hierarchy — root, folder, service, layer, or a
/// `/query` URL someone pasted — into an `ArcGISLocation`. Query strings (`f=json`, tokens,
/// where clauses) and fragments are dropped; scheme and host are lowercased; a missing scheme
/// is assumed to be https.
public enum ArcGISURL {
    public static func parse(_ text: String) throws -> ArcGISLocation {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = try parts(of: trimmed)
        let segments = parts.segments
        // Find `rest/services` (case-insensitive) — the anchor of every ArcGIS REST URL.
        guard let servicesIndex = zip(segments.indices, segments.dropFirst()).first(where: { i, next in
            segments[i].lowercased() == "rest" && next.lowercased() == "services"
        })?.0.advanced(by: 1) else { throw ArcGISURLError.notArcGIS(trimmed) }
        let rootURL = try url(parts, segments: segments[...servicesIndex], original: trimmed)
        return try walk(rootURL: rootURL, rest: Array(segments[(servicesIndex + 1)...]), original: trimmed)
    }

    /// A pasted URL as a node address: scheme and host lowercased, query and fragment dropped,
    /// no trailing slash, and a trailing operation (`/query`, `/layers`, `/legend`) removed.
    /// What a probe asks, and what a `ServerKind.service` root is.
    public static func bareURL(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = try parts(of: trimmed)
        var segments = parts.segments
        if let last = segments.last, operationSegments.contains(last.lowercased()) { segments.removeLast() }
        return try url(parts, segments: segments[...], original: trimmed)
    }

    /// A URL outside the `rest/services` shape that a registered root owns: a proxied
    /// directory's folder, service or layer, or a lone service's layer (`ServerKind.service`).
    /// Nil when no root is a prefix of it. Paths compare case-insensitively (IIS fronts most
    /// such proxies), and the longest root wins, so a lone service registered under a proxied
    /// directory is found before the directory. OGC roots own nothing here.
    public static func resolve(_ text: String, against servers: [ServerRecord]) throws -> ArcGISLocation? {
        let bare = try bareURL(text)
        let segments = bare.path.split(separator: "/").map { $0.lowercased() }
        let candidates = servers.filter { $0.kind != .ogc }
            .sorted { $0.rootURL.path.count > $1.rootURL.path.count }
        for server in candidates {
            guard origin(of: bare) == origin(of: server.rootURL) else { continue }
            let rootSegments = server.rootURL.path.split(separator: "/").map { $0.lowercased() }
            guard segments.count >= rootSegments.count, Array(segments.prefix(rootSegments.count)) == rootSegments else { continue }
            // The rest keeps the pasted casing: service and folder names go into requests as given.
            let rest = Array(bare.path.split(separator: "/").map(String.init).dropFirst(rootSegments.count))
            switch server.kind {
            case .service:
                let layerID = rest.first.flatMap { Int($0) }
                guard rest.isEmpty || (rest.count == 1 && layerID != nil) else { continue }
                return ArcGISLocation(rootURL: server.rootURL, servicePath: lastSegment(of: server.rootURL),
                                      layerID: layerID, rootIsService: true)
            case .arcgis:
                return try walk(rootURL: server.rootURL, rest: rest, original: text)
            case .ogc:
                continue
            }
        }
        return nil
    }

    /// Below a root: folders, then a service (name and type), then a layer id. Anything after
    /// the layer id (`query`, `legend`) or after a service with no id (`layers`) is ignored.
    static func walk(rootURL: URL, rest: [String], original: String) throws -> ArcGISLocation {
        guard let typeIndex = rest.firstIndex(where: ServiceType.matches) else {
            return ArcGISLocation(rootURL: rootURL, folderPath: rest.isEmpty ? nil : rest.joined(separator: "/"))
        }
        let nameSegments = Array(rest[..<typeIndex])
        guard let name = nameSegments.last else {
            // `…/rest/services/MapServer` — a type with no service name.
            throw ArcGISURLError.notArcGIS(original)
        }
        let folders = nameSegments.dropLast()
        let folderPath = folders.isEmpty ? nil : folders.joined(separator: "/")
        let servicePath = (folders + [name]).joined(separator: "/")
        let serviceType = ServiceType(rest[typeIndex])
        let afterType = rest.dropFirst(typeIndex + 1)
        let layerID = afterType.first.flatMap { Int($0) }

        return ArcGISLocation(rootURL: rootURL, folderPath: folderPath, servicePath: servicePath,
                              serviceType: serviceType, layerID: layerID)
    }

    /// Operations a pasted URL may end in that are not part of the node's address.
    static let operationSegments: Set<String> = ["query", "layers", "legend"]

    private struct Parts {
        let scheme: String
        let host: String
        let port: Int?
        let segments: [String]
    }

    /// Scheme, host, port and the non-empty path segments; https when no scheme was given.
    private static func parts(of trimmed: String) throws -> Parts {
        guard !trimmed.isEmpty else { throw ArcGISURLError.empty }
        let withScheme = trimmed.range(of: "://") == nil ? "https://" + trimmed : trimmed
        guard let components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty
        else { throw ArcGISURLError.malformed(trimmed) }
        let segments = components.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        return Parts(scheme: scheme, host: host, port: components.port, segments: segments)
    }

    private static func url(_ parts: Parts, segments: ArraySlice<String>, original: String) throws -> URL {
        var c = URLComponents()
        c.scheme = parts.scheme
        c.host = parts.host
        c.port = parts.port
        c.path = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
        guard let url = c.url else { throw ArcGISURLError.malformed(original) }
        return url
    }

    /// The last path segment of a URL, or the host when the path is empty: a lone service's name.
    public static func lastSegment(of url: URL) -> String {
        url.path.split(separator: "/").last.map(String.init) ?? (url.host ?? url.absoluteString)
    }

    /// The URL one path segment up, without query or fragment; nil at the host.
    public static func parent(of url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var segments = components.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard !segments.isEmpty else { return nil }
        segments.removeLast()
        components.path = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// `https://host[:port]` for a URL — the default `Origin` header value.
    public static func origin(of url: URL) -> String {
        var c = URLComponents()
        c.scheme = url.scheme?.lowercased()
        c.host = url.host?.lowercased()
        c.port = url.port
        return c.string ?? ""
    }
}
