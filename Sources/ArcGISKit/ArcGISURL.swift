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
    /// the unit the app remembers and names.
    public let rootURL: URL
    /// Folder path below the root, `"A/B"`, or nil at the root. When a service is present this
    /// is the folder that contains it.
    public let folderPath: String?
    /// Service name as ArcGIS lists it in the directory: `"Folder/Name"` or `"Name"`.
    public let servicePath: String?
    public let serviceType: ServiceType?
    public let layerID: Int?

    public init(rootURL: URL, folderPath: String? = nil, servicePath: String? = nil,
                serviceType: ServiceType? = nil, layerID: Int? = nil) {
        self.rootURL = rootURL
        self.folderPath = folderPath
        self.servicePath = servicePath
        self.serviceType = serviceType
        self.layerID = layerID
    }

    /// `https://host/…/rest/services/Folder/Name/FeatureServer`, when a service is named.
    public var serviceURL: URL? {
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
    /// The URL has no `rest/services` segment, so it is not an ArcGIS REST endpoint.
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
        guard !trimmed.isEmpty else { throw ArcGISURLError.empty }
        let withScheme = trimmed.range(of: "://") == nil ? "https://" + trimmed : trimmed
        guard let components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty
        else { throw ArcGISURLError.malformed(trimmed) }

        let segments = components.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        // Find `rest/services` (case-insensitive) — the anchor of every ArcGIS REST URL.
        guard let servicesIndex = zip(segments.indices, segments.dropFirst()).first(where: { i, next in
            segments[i].lowercased() == "rest" && next.lowercased() == "services"
        })?.0.advanced(by: 1) else { throw ArcGISURLError.notArcGIS(trimmed) }

        var root = URLComponents()
        root.scheme = scheme
        root.host = host
        root.port = components.port
        root.path = "/" + segments[...servicesIndex].joined(separator: "/")
        guard let rootURL = root.url else { throw ArcGISURLError.malformed(trimmed) }

        let rest = Array(segments[(servicesIndex + 1)...])
        // Walk to the first service-type segment: everything before it is folders + name.
        guard let typeIndex = rest.firstIndex(where: ServiceType.matches) else {
            return ArcGISLocation(rootURL: rootURL, folderPath: rest.isEmpty ? nil : rest.joined(separator: "/"))
        }
        let nameSegments = Array(rest[..<typeIndex])
        guard let name = nameSegments.last else {
            // `…/rest/services/MapServer` — a type with no service name.
            throw ArcGISURLError.notArcGIS(trimmed)
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

    /// `https://host[:port]` for a URL — the default `Origin` header value.
    public static func origin(of url: URL) -> String {
        var c = URLComponents()
        c.scheme = url.scheme?.lowercased()
        c.host = url.host?.lowercased()
        c.port = url.port
        return c.string ?? ""
    }
}
