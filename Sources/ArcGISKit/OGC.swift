import Foundation

// OGC sources (M10): WMS, WFS and WMTS endpoints, including the UMN MapServer shape where the
// mapfile rides along as a `map=` parameter on every request. The app keeps to the minimum:
// what the endpoint serves, what each layer looks like, and a download where one makes sense
// (features from a WFS, a picture from a WMS). No filtering, no querying.

/// Which protocol family a remembered server speaks.
public enum ServerKind: String, Sendable, Equatable {
    case arcgis, ogc
}

// MARK: - Locations and requests

/// A pasted OGC URL, reduced to the endpoint it belongs to. `rootURL` is the endpoint plus
/// any vendor parameters (`map=`, and whatever else is not an OGC request parameter), sorted
/// so the same endpoint pasted twice is the same server. The OGC parameters themselves say
/// where the user was pointing: the service, and a layer or feature type.
public struct OGCLocation: Sendable, Equatable {
    public let rootURL: URL
    public let serviceHint: ServiceType?
    public let layerName: String?
    /// The pasted URL is a static capabilities document (`…/1.0.0/WMTSCapabilities.xml`).
    public let isCapabilitiesDocument: Bool

    public init(rootURL: URL, serviceHint: ServiceType? = nil, layerName: String? = nil, isCapabilitiesDocument: Bool = false) {
        self.rootURL = rootURL
        self.serviceHint = serviceHint
        self.layerName = layerName
        self.isCapabilitiesDocument = isCapabilitiesDocument
    }
}

public enum OGCURLError: Error, CustomStringConvertible, Equatable {
    case malformed(String)
    public var description: String {
        switch self { case .malformed(let s): return "'\(s)' is not a URL an OGC server could answer" }
    }
}

public enum OGCURL {
    /// Query parameters that belong to a request, not to the endpoint.
    static let requestParameters: Set<String> = [
        "service", "request", "version", "acceptversions", "sections", "updatesequence", "exceptions",
        "typename", "typenames", "outputformat", "resulttype", "count", "maxfeatures", "startindex",
        "propertyname", "filter", "cql_filter", "featureid", "sortby", "srsname", "namespaces", "bbox",
        "layers", "layer", "styles", "style", "crs", "srs", "width", "height", "format", "transparent",
        "bgcolor", "time", "elevation", "query_layers", "info_format", "feature_count", "i", "j", "x", "y",
        "tilematrixset", "tilematrix", "tilerow", "tilecol", "infoformat",
    ]

    public static func parse(_ text: String) throws -> OGCLocation {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.range(of: "://") == nil ? "https://" + trimmed : trimmed
        guard var components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty
        else { throw OGCURLError.malformed(trimmed) }
        components.scheme = scheme
        components.host = host
        components.fragment = nil
        let items = components.queryItems ?? []
        var hint: ServiceType?
        var layerName: String?
        var vendor = [URLQueryItem]()
        for item in items {
            let key = item.name.lowercased()
            switch key {
            case "service":
                switch item.value?.uppercased() { case "WFS": hint = .wfs; case "WMS": hint = .wms; case "WMTS": hint = .wmts; default: break }
            case "typename", "typenames", "layers", "layer", "query_layers":
                if layerName == nil, let value = item.value, let first = value.split(separator: ",").first {
                    layerName = String(first).trimmingCharacters(in: .whitespaces)
                }
            default:
                if !requestParameters.contains(key) { vendor.append(item) }
            }
        }
        let path = components.path
        let isDocument = path.lowercased().hasSuffix(".xml")
        if isDocument, path.lowercased().contains("wmts") { hint = .wmts }
        if path.hasSuffix("/") && path.count > 1 { components.path = String(path.dropLast()) }
        components.queryItems = vendor.isEmpty ? nil : vendor.sorted { $0.name.lowercased() < $1.name.lowercased() }
        guard let root = components.url else { throw OGCURLError.malformed(trimmed) }
        return OGCLocation(rootURL: root, serviceHint: hint, layerName: layerName, isCapabilitiesDocument: isDocument)
    }

    /// The endpoint without its query, and the vendor parameters the root carries, so a
    /// request can be built as endpoint + vendor parameters + request parameters.
    public static func split(_ root: URL) -> (endpoint: URL, vendor: [String: String]) {
        guard var components = URLComponents(url: root, resolvingAgainstBaseURL: false) else { return (root, [:]) }
        var vendor = [String: String]()
        for item in components.queryItems ?? [] { vendor[item.name] = item.value ?? "" }
        components.queryItems = nil
        components.query = nil
        return (components.url ?? root, vendor)
    }

    /// A GET URL for `params` against the root, vendor parameters included (for the path bar,
    /// the map page's tile templates, and anything else that needs a URL rather than a request).
    public static func url(root: URL, params: [String: String]) -> URL {
        let (endpoint, vendor) = split(root)
        var all = vendor
        for (key, value) in params { all[key] = value }
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return endpoint }
        components.percentEncodedQuery = ArcGISClient.formEncode(all)
        return components.url ?? endpoint
    }

    /// The EPSG code in any of the spellings capabilities documents use: `EPSG:27700`,
    /// `urn:ogc:def:crs:EPSG::27700`, `urn:x-ogc:def:crs:EPSG:27700`,
    /// `http://www.opengis.net/def/crs/EPSG/0/27700`. `CRS:84` is WGS 84 with lon/lat order.
    public static func epsgCode(_ crs: String) -> Int? {
        let text = crs.trimmingCharacters(in: .whitespaces)
        if text.uppercased() == "CRS:84" { return 4326 }
        guard let range = text.range(of: "EPSG", options: .caseInsensitive) else { return nil }
        let tail = text[range.upperBound...]
        let digits = tail.split(whereSeparator: { !$0.isNumber }).last.map(String.init) ?? ""
        return Int(digits)
    }
}

// MARK: - Service and layer detail

/// What the app keeps about an OGC service, from its capabilities document.
public struct OGCServiceDetail: Codable, Sendable, Equatable {
    public var version: String
    public var title: String?
    public var abstract: String?
    /// Operations the service advertises: GetMap, GetFeature, GetTile, …
    public var operations: [String] = []
    /// GetMap image formats (WMS), GetFeature output formats (WFS), tile formats (WMTS).
    public var formats: [String] = []
    /// WFS 2.0 `ImplementsResultPaging`.
    public var paging = false
    /// WFS 2.0 `CountDefault`: the page the server applies when asked for none.
    public var countDefault: Int?
    /// WMS `MaxWidth` / `MaxHeight` for a GetMap.
    public var maxWidth: Int?
    public var maxHeight: Int?
    public var tileMatrixSets: [OGCTileMatrixSet] = []

    public init(version: String, title: String? = nil, abstract: String? = nil) {
        self.version = version
        self.title = title
        self.abstract = abstract
    }

    /// The GeoJSON output format to ask for, when one is offered: a WFS GetFeature's, or a WMS
    /// GetMap's vector output (GeoServer's `application/json;type=geojson`). UTFGrid, TopoJSON
    /// and JSONP are JSON without being features.
    public var geoJSONFormat: String? {
        let candidates = formats.map { ($0, $0.lowercased()) }
        if let geo = candidates.first(where: { $0.1.contains("geojson") || $0.1.contains("geo+json") }) { return geo.0 }
        return candidates.first { pair in
            let f = pair.1
            let plainJSON = f == "json" || f.hasPrefix("application/json")
            return plainJSON && !f.contains("utfgrid") && !f.contains("topojson") && !f.contains("jsonp")
        }?.0
    }
    public var gmlFormat: String? {
        formats.first { $0.lowercased().contains("gml") } ?? (formats.isEmpty ? nil : nil)
    }
}

public struct OGCTileMatrixSet: Codable, Sendable, Equatable {
    public var identifier: String
    public var crs: String
    public var matrixIdentifiers: [String]
    public var tileWidth: Int?

    public init(identifier: String, crs: String, matrixIdentifiers: [String], tileWidth: Int? = nil) {
        self.identifier = identifier
        self.crs = crs
        self.matrixIdentifiers = matrixIdentifiers
        self.tileWidth = tileWidth
    }

    /// True for the Web Mercator sets a MapLibre raster source can draw.
    public var isWebMercator: Bool { [3857, 900913, 102100, 3785].contains(OGCURL.epsgCode(crs) ?? 0) }
}

/// What the app keeps about one OGC layer: a WMS layer, a WFS feature type, a WMTS layer.
public struct OGCLayerDetail: Codable, Sendable, Equatable {
    /// The identifier requests use (the WFS typeName, the WMS `Name`, the WMTS `Identifier`).
    public var name: String
    public var title: String
    public var abstract: String?
    public var keywords: [String] = []
    /// Every CRS the layer is offered in, as the document spells them.
    public var crs: [String] = []
    public var defaultCRS: String?
    public var bboxWGS84: BoundingBox?
    public var queryable: Bool?
    public var styles: [String] = []
    /// Per-layer formats (WMTS tile formats, WFS per-type output formats).
    public var formats: [String] = []
    public var tileMatrixSetLinks: [String] = []
    /// WMTS REST templates with `{TileMatrixSet}`, `{TileMatrix}`, `{TileRow}`, `{TileCol}`.
    public var resourceURLTemplates: [String] = []
    /// Esri-style geometry type from DescribeFeatureType, once known.
    public var geometryType: String?

    public init(name: String, title: String) {
        self.name = name
        self.title = title
    }

    public var supportsWebMercator: Bool { crs.contains { [3857, 900913, 102100, 3785].contains(OGCURL.epsgCode($0) ?? 0) } }
    public var supportsWGS84: Bool { crs.contains { OGCURL.epsgCode($0) == 4326 } }
    /// The Web Mercator CRS exactly as the layer spells it, for a request.
    public var webMercatorCRS: String? { crs.first { [3857, 900913, 102100, 3785].contains(OGCURL.epsgCode($0) ?? 0) } }
    public var wgs84CRS: String? { crs.first { OGCURL.epsgCode($0) == 4326 } }
}

/// One field of a WFS feature type, from DescribeFeatureType.
public struct OGCField: Sendable, Equatable {
    public var name: String
    /// The XSD type's local part: `string`, `int`, `double`, `dateTime`, `PointPropertyType`…
    public var xsdType: String
    public var nillable: Bool?

    public init(name: String, xsdType: String, nillable: Bool? = nil) {
        self.name = name
        self.xsdType = xsdType
        self.nillable = nillable
    }

    public var isGeometry: Bool { xsdType.hasSuffix("PropertyType") || xsdType.lowercased().contains("geometry") }

    /// The Esri field type the staging and export code understands.
    public var esriType: EsriFieldType {
        if isGeometry { return .geometry }
        switch xsdType.lowercased() {
        case "int", "integer", "nonnegativeinteger", "positiveinteger", "unsignedint": return .integer
        case "long", "unsignedlong": return .bigInteger
        case "short", "byte", "unsignedshort", "unsignedbyte": return .smallInteger
        case "double", "decimal": return .double
        case "float": return .single
        case "datetime": return .date
        case "date": return .dateOnly
        case "time": return .timeOnly
        case "base64binary", "hexbinary": return .blob
        default: return .string
        }
    }

    /// Esri-style geometry type for a GML property type, nil for non-geometry fields.
    public var geometryType: String? {
        guard isGeometry else { return nil }
        let t = xsdType.lowercased()
        if t.contains("multipoint") { return "esriGeometryMultipoint" }
        if t.contains("point") { return "esriGeometryPoint" }
        if t.contains("curve") || t.contains("line") { return "esriGeometryPolyline" }
        if t.contains("surface") || t.contains("polygon") { return "esriGeometryPolygon" }
        return nil
    }
}

public struct OGCFeatureType: Sendable, Equatable {
    /// The local part of the type name (`towns` for `ms:towns`).
    public var name: String
    public var fields: [OGCField]

    public init(name: String, fields: [OGCField]) {
        self.name = name
        self.fields = fields
    }
}

/// A parsed capabilities document.
public struct OGCCapabilitiesDocument: Sendable, Equatable {
    public var type: ServiceType
    public var detail: OGCServiceDetail
    public var layers: [OGCLayerDetail]
    /// Each layer's XML fragment, verbatim, for the Raw tab (parallel to `layers`).
    public var layerXML: [String]
}

public enum OGCError: Error, CustomStringConvertible, Equatable {
    /// The server answered with an OGC exception report (HTTP 200 and all).
    case exception(String, url: URL)
    /// Not the document we asked for: an HTML page, a different service's capabilities, or noise.
    case notCapabilities(expected: ServiceType, found: String, url: URL)
    case malformedXML(String, url: URL)
    /// None of WMS, WFS and WMTS answered at the endpoint.
    case noServices(url: URL, attempts: [String])
    case notAFeatureType(String)

    public var description: String {
        switch self {
        case .exception(let text, let url): return "the server reported: \(text) (\(url))"
        case .notCapabilities(let expected, let found, let url): return "\(url) did not answer with \(expected.name) capabilities (got \(found))"
        case .malformedXML(let why, let url): return "the response from \(url) is not well-formed XML: \(why)"
        case .noServices(let url, let attempts): return "\(url) answered none of WMS, WFS or WMTS: " + attempts.joined(separator: "; ")
        case .notAFeatureType(let name): return "\(name) is not a WFS feature type"
        }
    }
}

// MARK: - Requests

/// The request parameters for each operation, by service and version.
public enum OGCRequests {
    /// Capabilities for a service at the root; a static document URL is fetched as is.
    public static func capabilities(root: URL, type: ServiceType, location: OGCLocation? = nil) -> (url: URL, params: [String: String]) {
        if let location, location.isCapabilitiesDocument, location.serviceHint == type {
            return (location.rootURL, [:])
        }
        var params = ["service": type.name, "request": "GetCapabilities"]
        switch type {
        case .wmts: params["version"] = "1.0.0"
        case .wfs: params["acceptversions"] = "2.0.0,1.1.0,1.0.0"
        default: break
        }
        return (root, params)
    }

    /// WFS GetFeature for one type: `count` features from `startIndex` in `format`, in the
    /// type's default CRS unless `srsName` says otherwise.
    public static func getFeature(version: String, typeName: String, format: String?, startIndex: Int?, count: Int?,
                                  srsName: String? = nil, hits: Bool = false) -> [String: String] {
        var params = ["service": "WFS", "request": "GetFeature", "version": version]
        let v2 = version.hasPrefix("2")
        params[v2 ? "typeNames" : "typeName"] = typeName
        if let format { params["outputFormat"] = format }
        if let count { params[v2 ? "count" : "maxFeatures"] = String(count) }
        if let startIndex, startIndex > 0 { params["startIndex"] = String(startIndex) }
        if let srsName { params["srsName"] = srsName }
        if hits { params["resultType"] = "hits" }
        return params
    }

    /// A request that names one layer, for the path bar: a small GetFeature for a WFS type,
    /// the capabilities with the layer named for WMS and WMTS (which need a box and a size
    /// before they can draw anything).
    public static func layerParams(type: ServiceType, name: String, version: String?) -> [String: String] {
        switch type {
        case .wfs:
            let v = version ?? "2.0.0"
            return getFeature(version: v, typeName: name, format: nil, startIndex: nil, count: 10)
        case .wms:
            return ["service": "WMS", "request": "GetCapabilities", "layers": name]
        case .wmts:
            return ["service": "WMTS", "request": "GetCapabilities", "version": "1.0.0", "layer": name]
        default:
            return [:]
        }
    }

    public static func describeFeatureType(version: String, typeName: String? = nil) -> [String: String] {
        var params = ["service": "WFS", "request": "DescribeFeatureType", "version": version]
        if let typeName { params[version.hasPrefix("2") ? "typeNames" : "typeName"] = typeName }
        return params
    }

    /// WMS GetMap. `bbox` is minx,miny,maxx,maxy in `crs` as the caller orders it; WMS 1.3.0
    /// wants lat,lon order for EPSG:4326, which `getMapBBox` takes care of.
    public static func getMap(version: String, layer: String, style: String, crs: String, bbox: String,
                              width: Int, height: Int, format: String, transparent: Bool) -> [String: String] {
        var params = ["service": "WMS", "request": "GetMap", "version": version, "layers": layer, "styles": style,
                      "bbox": bbox, "width": String(width), "height": String(height), "format": format]
        params[version.hasPrefix("1.3") ? "crs" : "srs"] = crs
        if transparent { params["transparent"] = "TRUE" }
        return params
    }

    /// The bbox string for a GetMap: axis order follows the version and the CRS.
    public static func getMapBBox(version: String, crs: String, minX: Double, minY: Double, maxX: Double, maxY: Double) -> String {
        let latLonFirst = version.hasPrefix("1.3") && OGCURL.epsgCode(crs) == 4326 && crs.uppercased() != "CRS:84"
        return latLonFirst ? "\(minY),\(minX),\(maxY),\(maxX)" : "\(minX),\(minY),\(maxX),\(maxY)"
    }

    /// WMTS KVP GetTile with MapLibre's `{z}`, `{x}`, `{y}` placeholders.
    public static func getTile(layer: String, style: String, tileMatrixSet: String, matrixTemplate: String, format: String) -> [String: String] {
        ["service": "WMTS", "request": "GetTile", "version": "1.0.0", "layer": layer, "style": style,
         "tilematrixset": tileMatrixSet, "tilematrix": matrixTemplate, "tilerow": "{y}", "tilecol": "{x}", "format": format]
    }

    /// `{z}` with the set's identifier convention: plain numbers, or `prefix:{z}` when every
    /// matrix is spelled `prefix:number` (GeoServer's `EPSG:3857:5`).
    public static func matrixTemplate(_ set: OGCTileMatrixSet) -> String? {
        let ids = set.matrixIdentifiers
        guard !ids.isEmpty else { return nil }
        if ids.allSatisfy({ Int($0) != nil }) { return "{z}" }
        let prefixes = Set(ids.compactMap { id -> String? in
            guard let colon = id.lastIndex(of: ":"), Int(id[id.index(after: colon)...]) != nil else { return nil }
            return String(id[...colon])
        })
        guard prefixes.count == 1, let prefix = prefixes.first, ids.count == ids.compactMap({ $0.hasPrefix(prefix) ? $0 : nil }).count else { return nil }
        return prefix + "{z}"
    }
}

// MARK: - Capabilities parsing

/// Parsers for the capabilities documents and DescribeFeatureType, tolerant of versions and
/// namespaces (every element is matched by local name).
public enum OGCCapabilities {
    public static func parse(_ data: Data, expecting type: ServiceType, url: URL) throws -> OGCCapabilitiesDocument {
        let document = try XMLSupport.document(data, url: url)
        guard let root = document.rootElement() else { throw OGCError.malformedXML("no root element", url: url) }
        let rootName = root.localName ?? root.name ?? ""
        if rootName.hasSuffix("ExceptionReport") {
            throw OGCError.exception(exceptionText(root), url: url)
        }
        switch type {
        case .wms:
            guard rootName == "WMS_Capabilities" || rootName == "WMT_MS_Capabilities" else {
                throw OGCError.notCapabilities(expected: type, found: rootName, url: url)
            }
            return parseWMS(root)
        case .wfs:
            guard rootName == "WFS_Capabilities" else { throw OGCError.notCapabilities(expected: type, found: rootName, url: url) }
            return parseWFS(root)
        case .wmts:
            guard rootName == "Capabilities", !XMLSupport.nodes(root, "./*[local-name()='Contents']/*[local-name()='TileMatrixSet']").isEmpty
                || !XMLSupport.nodes(root, "./*[local-name()='Contents']/*[local-name()='Layer']").isEmpty
            else { throw OGCError.notCapabilities(expected: type, found: rootName, url: url) }
            return parseWMTS(root)
        default:
            throw OGCError.notCapabilities(expected: type, found: rootName, url: url)
        }
    }

    /// The text of an OGC or OWS exception report.
    public static func exceptionText(_ root: XMLNode) -> String {
        let texts = XMLSupport.nodes(root, ".//*[local-name()='ExceptionText' or local-name()='ServiceException']")
            .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !texts.isEmpty { return texts.joined(separator: "; ") }
        let codes = XMLSupport.nodes(root, ".//*[local-name()='Exception']").compactMap { XMLSupport.attr($0, "exceptionCode") }
        return codes.isEmpty ? "an exception report with no text" : codes.joined(separator: "; ")
    }

    /// True when the body is an exception report rather than the document asked for.
    public static func isExceptionReport(_ data: Data) -> Bool {
        guard let document = try? XMLDocument(data: data, options: []), let root = document.rootElement() else { return false }
        return (root.localName ?? root.name ?? "").hasSuffix("ExceptionReport")
    }

    // MARK: WMS

    static func parseWMS(_ root: XMLElement) -> OGCCapabilitiesDocument {
        let version = XMLSupport.attr(root, "version") ?? "1.3.0"
        var detail = OGCServiceDetail(version: version,
                                      title: XMLSupport.text(root, "./*[local-name()='Service']/*[local-name()='Title']"),
                                      abstract: XMLSupport.text(root, "./*[local-name()='Service']/*[local-name()='Abstract']"))
        detail.maxWidth = XMLSupport.text(root, "./*[local-name()='Service']/*[local-name()='MaxWidth']").flatMap(Int.init)
        detail.maxHeight = XMLSupport.text(root, "./*[local-name()='Service']/*[local-name()='MaxHeight']").flatMap(Int.init)
        let request = XMLSupport.nodes(root, "./*[local-name()='Capability']/*[local-name()='Request']").first
        detail.operations = request.map { XMLSupport.childNames($0) } ?? []
        detail.formats = request.map { XMLSupport.texts($0, "./*[local-name()='GetMap']/*[local-name()='Format']") } ?? []
        var layers = [OGCLayerDetail]()
        var xml = [String]()
        for node in XMLSupport.nodes(root, ".//*[local-name()='Layer'][*[local-name()='Name']]") {
            guard let element = node as? XMLElement, let name = XMLSupport.text(element, "./*[local-name()='Name']"), !name.isEmpty else { continue }
            var layer = OGCLayerDetail(name: name, title: XMLSupport.text(element, "./*[local-name()='Title']") ?? name)
            layer.abstract = XMLSupport.text(element, "./*[local-name()='Abstract']")
            layer.keywords = XMLSupport.texts(element, "./*[local-name()='KeywordList']/*[local-name()='Keyword']")
            layer.queryable = XMLSupport.attr(element, "queryable").map { $0 == "1" || $0.lowercased() == "true" }
            // CRS and the geographic box are inherited from enclosing layers. A group layer
            // that declares none of its own (MapServer writes an empty element) can only be
            // asked for in what its children answer, so it borrows theirs.
            let lineage = "ancestor-or-self::*[local-name()='Layer']"
            var crs = [String]()
            func collect(_ xpath: String) {
                for value in XMLSupport.texts(element, xpath) {
                    for part in value.split(whereSeparator: { $0.isWhitespace }) where !crs.contains(String(part)) { crs.append(String(part)) }
                }
            }
            collect("\(lineage)/*[local-name()='CRS' or local-name()='SRS']")
            if crs.isEmpty { collect("descendant::*[local-name()='Layer']/*[local-name()='CRS' or local-name()='SRS']") }
            layer.crs = crs
            layer.defaultCRS = crs.first
            if let box = XMLSupport.nodes(element, "\(lineage)/*[local-name()='EX_GeographicBoundingBox']").last,
               let west = XMLSupport.text(box, "./*[local-name()='westBoundLongitude']").flatMap(Double.init),
               let east = XMLSupport.text(box, "./*[local-name()='eastBoundLongitude']").flatMap(Double.init),
               let south = XMLSupport.text(box, "./*[local-name()='southBoundLatitude']").flatMap(Double.init),
               let north = XMLSupport.text(box, "./*[local-name()='northBoundLatitude']").flatMap(Double.init) {
                layer.bboxWGS84 = BoundingBox(minX: west, minY: south, maxX: east, maxY: north)
            } else if let box = XMLSupport.nodes(element, "\(lineage)/*[local-name()='LatLonBoundingBox']").last {
                layer.bboxWGS84 = XMLSupport.box(fromAttributes: box)
            }
            layer.styles = XMLSupport.texts(element, "./*[local-name()='Style']/*[local-name()='Name']")
            layers.append(layer)
            xml.append(element.xmlString(options: [.nodePrettyPrint]))
        }
        return OGCCapabilitiesDocument(type: .wms, detail: detail, layers: layers, layerXML: xml)
    }

    // MARK: WFS

    static func parseWFS(_ root: XMLElement) -> OGCCapabilitiesDocument {
        let version = XMLSupport.attr(root, "version") ?? "2.0.0"
        let identification = "./*[local-name()='ServiceIdentification']"
        var detail = OGCServiceDetail(
            version: version,
            title: XMLSupport.text(root, "\(identification)/*[local-name()='Title']") ?? XMLSupport.text(root, "./*[local-name()='Service']/*[local-name()='Title']"),
            abstract: XMLSupport.text(root, "\(identification)/*[local-name()='Abstract']") ?? XMLSupport.text(root, "./*[local-name()='Service']/*[local-name()='Abstract']"))
        let operations = "./*[local-name()='OperationsMetadata']/*[local-name()='Operation']"
        detail.operations = XMLSupport.nodes(root, operations).compactMap { XMLSupport.attr($0, "name") }
        if detail.operations.isEmpty, let request = XMLSupport.nodes(root, "./*[local-name()='Capability']/*[local-name()='Request']").first {
            detail.operations = XMLSupport.childNames(request)   // WFS 1.0
        }
        let getFeature = "\(operations)[@name='GetFeature']"
        detail.formats = XMLSupport.texts(root, "\(getFeature)/*[local-name()='Parameter'][@name='outputFormat']//*[local-name()='Value']")
        if detail.formats.isEmpty {
            detail.formats = XMLSupport.texts(root, "./*[local-name()='OperationsMetadata']/*[local-name()='Parameter'][@name='outputFormat']//*[local-name()='Value']")
        }
        if detail.formats.isEmpty, let result = XMLSupport.nodes(root, "./*[local-name()='Capability']/*[local-name()='Request']/*[local-name()='GetFeature']/*[local-name()='ResultFormat']").first {
            detail.formats = XMLSupport.childNames(result)   // WFS 1.0: GML2, GEOJSON, …
        }
        let constraints = "./*[local-name()='OperationsMetadata']//*[local-name()='Constraint']"
        detail.paging = XMLSupport.text(root, "\(constraints)[@name='ImplementsResultPaging']/*[local-name()='DefaultValue']")?.uppercased() == "TRUE"
        detail.countDefault = XMLSupport.text(root, "\(constraints)[@name='CountDefault']/*[local-name()='DefaultValue']").flatMap(Int.init)
        var layers = [OGCLayerDetail]()
        var xml = [String]()
        for node in XMLSupport.nodes(root, ".//*[local-name()='FeatureTypeList']/*[local-name()='FeatureType']") {
            guard let element = node as? XMLElement, let name = XMLSupport.text(element, "./*[local-name()='Name']"), !name.isEmpty else { continue }
            var layer = OGCLayerDetail(name: name, title: XMLSupport.text(element, "./*[local-name()='Title']") ?? name)
            layer.abstract = XMLSupport.text(element, "./*[local-name()='Abstract']")
            layer.keywords = XMLSupport.texts(element, ".//*[local-name()='Keyword']").flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }.filter { !$0.isEmpty }
            let defaultCRS = XMLSupport.text(element, "./*[local-name()='DefaultCRS' or local-name()='DefaultSRS' or local-name()='SRS']")
            layer.defaultCRS = defaultCRS
            var crs = defaultCRS.map { [$0] } ?? []
            for other in XMLSupport.texts(element, "./*[local-name()='OtherCRS' or local-name()='OtherSRS']") where !crs.contains(other) { crs.append(other) }
            layer.crs = crs
            if let box = XMLSupport.nodes(element, "./*[local-name()='WGS84BoundingBox']").first {
                let lower = XMLSupport.text(box, "./*[local-name()='LowerCorner']")?.split(whereSeparator: { $0.isWhitespace }).compactMap { Double($0) } ?? []
                let upper = XMLSupport.text(box, "./*[local-name()='UpperCorner']")?.split(whereSeparator: { $0.isWhitespace }).compactMap { Double($0) } ?? []
                if lower.count >= 2, upper.count >= 2 {
                    layer.bboxWGS84 = BoundingBox(minX: lower[0], minY: lower[1], maxX: upper[0], maxY: upper[1])
                }
            } else if let box = XMLSupport.nodes(element, "./*[local-name()='LatLongBoundingBox']").first {
                layer.bboxWGS84 = XMLSupport.box(fromAttributes: box)
            }
            layer.formats = XMLSupport.texts(element, "./*[local-name()='OutputFormats']/*[local-name()='Format']")
            layers.append(layer)
            xml.append(element.xmlString(options: [.nodePrettyPrint]))
        }
        return OGCCapabilitiesDocument(type: .wfs, detail: detail, layers: layers, layerXML: xml)
    }

    // MARK: WMTS

    static func parseWMTS(_ root: XMLElement) -> OGCCapabilitiesDocument {
        let version = XMLSupport.attr(root, "version") ?? "1.0.0"
        let identification = "./*[local-name()='ServiceIdentification']"
        var detail = OGCServiceDetail(version: version,
                                      title: XMLSupport.text(root, "\(identification)/*[local-name()='Title']"),
                                      abstract: XMLSupport.text(root, "\(identification)/*[local-name()='Abstract']"))
        detail.operations = XMLSupport.nodes(root, "./*[local-name()='OperationsMetadata']/*[local-name()='Operation']").compactMap { XMLSupport.attr($0, "name") }
        let contents = "./*[local-name()='Contents']"
        for node in XMLSupport.nodes(root, "\(contents)/*[local-name()='TileMatrixSet']") {
            guard let identifier = XMLSupport.text(node, "./*[local-name()='Identifier']") else { continue }
            let set = OGCTileMatrixSet(identifier: identifier,
                                       crs: XMLSupport.text(node, "./*[local-name()='SupportedCRS']") ?? "",
                                       matrixIdentifiers: XMLSupport.texts(node, "./*[local-name()='TileMatrix']/*[local-name()='Identifier']"),
                                       tileWidth: XMLSupport.text(node, "./*[local-name()='TileMatrix']/*[local-name()='TileWidth']").flatMap(Int.init))
            detail.tileMatrixSets.append(set)
        }
        var layers = [OGCLayerDetail]()
        var xml = [String]()
        var formats = Set<String>()
        for node in XMLSupport.nodes(root, "\(contents)/*[local-name()='Layer']") {
            guard let element = node as? XMLElement, let name = XMLSupport.text(element, "./*[local-name()='Identifier']"), !name.isEmpty else { continue }
            var layer = OGCLayerDetail(name: name, title: XMLSupport.text(element, "./*[local-name()='Title']") ?? name)
            layer.abstract = XMLSupport.text(element, "./*[local-name()='Abstract']")
            layer.keywords = XMLSupport.texts(element, ".//*[local-name()='Keyword']")
            layer.formats = XMLSupport.texts(element, "./*[local-name()='Format']")
            formats.formUnion(layer.formats)
            let styles = XMLSupport.nodes(element, "./*[local-name()='Style']")
            let defaultStyle = styles.first { XMLSupport.attr($0, "isDefault")?.lowercased() == "true" } ?? styles.first
            layer.styles = ([defaultStyle] + styles.filter { $0 !== defaultStyle }).compactMap { $0.flatMap { XMLSupport.text($0, "./*[local-name()='Identifier']") } }
            layer.tileMatrixSetLinks = XMLSupport.texts(element, "./*[local-name()='TileMatrixSetLink']/*[local-name()='TileMatrixSet']")
            layer.resourceURLTemplates = XMLSupport.nodes(element, "./*[local-name()='ResourceURL'][@resourceType='tile']").compactMap { XMLSupport.attr($0, "template") }
            layer.crs = layer.tileMatrixSetLinks.compactMap { link in detail.tileMatrixSets.first { $0.identifier == link }?.crs }
            layer.defaultCRS = layer.crs.first
            if let box = XMLSupport.nodes(element, "./*[local-name()='WGS84BoundingBox']").first {
                let lower = XMLSupport.text(box, "./*[local-name()='LowerCorner']")?.split(whereSeparator: { $0.isWhitespace }).compactMap { Double($0) } ?? []
                let upper = XMLSupport.text(box, "./*[local-name()='UpperCorner']")?.split(whereSeparator: { $0.isWhitespace }).compactMap { Double($0) } ?? []
                if lower.count >= 2, upper.count >= 2 {
                    layer.bboxWGS84 = BoundingBox(minX: lower[0], minY: lower[1], maxX: upper[0], maxY: upper[1])
                }
            }
            layers.append(layer)
            xml.append(element.xmlString(options: [.nodePrettyPrint]))
        }
        detail.formats = formats.sorted()
        return OGCCapabilitiesDocument(type: .wmts, detail: detail, layers: layers, layerXML: xml)
    }

    // MARK: DescribeFeatureType

    /// The feature types described by an XSD: each top-level element's complex type, its
    /// elements as fields. Types are matched by local name, so `ms:towns` and `towns` meet.
    public static func parseFeatureTypes(_ data: Data, url: URL) throws -> [OGCFeatureType] {
        let document = try XMLSupport.document(data, url: url)
        guard let root = document.rootElement() else { throw OGCError.malformedXML("no root element", url: url) }
        let rootName = root.localName ?? root.name ?? ""
        if rootName.hasSuffix("ExceptionReport") { throw OGCError.exception(exceptionText(root), url: url) }
        guard rootName == "schema" else { throw OGCError.malformedXML("expected an XML Schema, got \(rootName)", url: url) }
        var types = [OGCFeatureType]()
        for element in XMLSupport.nodes(root, "./*[local-name()='element']") {
            guard let name = XMLSupport.attr(element, "name") else { continue }
            let typeName = XMLSupport.attr(element, "type").map(XMLSupport.localPart)
            let complex: XMLNode?
            if let typeName {
                complex = XMLSupport.nodes(root, "./*[local-name()='complexType'][@name='\(typeName)']").first
            } else {
                complex = XMLSupport.nodes(element, "./*[local-name()='complexType']").first
            }
            guard let complex else { continue }
            let fields = XMLSupport.nodes(complex, ".//*[local-name()='sequence']/*[local-name()='element']").compactMap { field -> OGCField? in
                guard let fieldName = XMLSupport.attr(field, "name") else { return nil }
                let xsd = XMLSupport.attr(field, "type").map(XMLSupport.localPart)
                    ?? XMLSupport.nodes(field, ".//*[local-name()='restriction']").first.flatMap { XMLSupport.attr($0, "base") }.map(XMLSupport.localPart)
                    ?? "string"
                let nillable = XMLSupport.attr(field, "nillable").map { $0.lowercased() == "true" }
                return OGCField(name: fieldName, xsdType: xsd, nillable: nillable)
            }
            types.append(OGCFeatureType(name: name, fields: fields))
        }
        return types
    }

    /// `numberMatched` (WFS 2.0) or `numberOfFeatures` (1.1) from a `resultType=hits` answer.
    public static func parseHits(_ data: Data, url: URL) throws -> Int64? {
        let document = try XMLSupport.document(data, url: url)
        guard let root = document.rootElement() else { throw OGCError.malformedXML("no root element", url: url) }
        if (root.localName ?? "").hasSuffix("ExceptionReport") { throw OGCError.exception(exceptionText(root), url: url) }
        for name in ["numberMatched", "numberOfFeatures"] {
            if let value = XMLSupport.attr(root, name), let n = Int64(value) { return n }
        }
        return nil
    }
}

/// Foundation's `XMLDocument` with namespace-blind XPath, which is all these documents need.
enum XMLSupport {
    static func document(_ data: Data, url: URL) throws -> XMLDocument {
        do {
            return try XMLDocument(data: data, options: [.nodePreserveWhitespace])
        } catch {
            let preview = String(decoding: data.prefix(160), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let hint = preview.lowercased().contains("<html") ? "an HTML page" : (preview.isEmpty ? "an empty body" : "starts with '\(preview.prefix(60))'")
            throw OGCError.malformedXML(hint, url: url)
        }
    }

    static func nodes(_ node: XMLNode, _ xpath: String) -> [XMLNode] {
        (try? node.nodes(forXPath: xpath)) ?? []
    }

    static func text(_ node: XMLNode, _ xpath: String) -> String? {
        let value = nodes(node, xpath).first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func texts(_ node: XMLNode, _ xpath: String) -> [String] {
        nodes(node, xpath).compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func attr(_ node: XMLNode, _ name: String) -> String? {
        (node as? XMLElement)?.attribute(forName: name)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Local names of the element's children, in order, without repeats.
    static func childNames(_ node: XMLNode) -> [String] {
        var names = [String]()
        for child in node.children ?? [] where child.kind == .element {
            let name = child.localName ?? child.name ?? ""
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        return names
    }

    static func localPart(_ qualified: String) -> String {
        qualified.split(separator: ":").last.map(String.init) ?? qualified
    }

    /// `minx miny maxx maxy` attributes (WMS 1.1.1 LatLonBoundingBox, WFS 1.0 LatLongBoundingBox).
    static func box(fromAttributes node: XMLNode) -> BoundingBox? {
        guard let minx = attr(node, "minx").flatMap(Double.init), let miny = attr(node, "miny").flatMap(Double.init),
              let maxx = attr(node, "maxx").flatMap(Double.init), let maxy = attr(node, "maxy").flatMap(Double.init) else { return nil }
        return BoundingBox(minX: minx, minY: miny, maxX: maxx, maxY: maxy)
    }
}
