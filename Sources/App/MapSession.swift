import Foundation
import Observation
import ArcGISKit

/// The Map tab's state for one layer: what is drawn (a server sample, a stored download, or
/// the query preview), the extent, the graticule for the current viewport, and the feature
/// the user clicked.
@MainActor @Observable
final class MapSession {
    enum Source: Hashable {
        case sample
        case stored(Int64)
        case query
    }

    let layer: LayerRecord
    let service: ServiceRecord
    private let client: ArcGISClient
    private let database: AppDatabase
    private let connection: ServerConnection
    private(set) var storedRuns: [DownloadRecord]
    var querySet: FeatureSet?
    var queryWkid: Int?

    var source: Source = .sample
    private(set) var content = MapContent()
    private(set) var caption = ""
    private(set) var isLoading = false
    /// The sample body as it arrives; nil while the server is still thinking.
    private(set) var transfer: TransferProgress?
    private(set) var error: String?
    private(set) var graticule: Graticule?
    private(set) var viewport: MapViewport?
    var storedWhere = ""
    /// The clicked feature's attributes, in field order, for the info panel.
    private(set) var selectedFeature: [(String, String)]?
    private var graticuleTask: Task<Void, Never>?

    init(layer: LayerRecord, service: ServiceRecord, client: ArcGISClient, database: AppDatabase,
         connection: ServerConnection, storedRuns: [DownloadRecord], querySet: FeatureSet?, queryWkid: Int?) {
        self.layer = layer
        self.service = service
        self.client = client
        self.database = database
        self.connection = connection
        self.storedRuns = storedRuns
        self.querySet = querySet
        self.queryWkid = queryWkid
        content.extent = layer.extentWGS84
        content.fit = layer.extentWGS84.flatMap { $0.isDefaultLike ? nil : $0 }
    }

    var layerURL: URL { service.url.appendingPathComponent(String(layer.layerID)) }
    var sampleSize: Int { min(layer.maxRecordCount ?? 1000, 800) }
    var hasQueryPreview: Bool { querySet?.hasGeometry == true }
    /// A WMS or WMTS layer draws as raster (M10): no features, no sample to redraw.
    var isRaster: Bool { service.type == .wms || service.type == .wmts }

    /// Answers the page's tile requests through the app's client, with this server's headers
    /// and cookie (M10). The media type is the request's own `format` when it names one.
    var tileFetcher: @Sendable (URL) async throws -> (Data, String?) {
        let client = client
        let connection = connection
        return { url in
            let (endpoint, params) = OGCURL.split(url)
            let data = try await client.fetch(root: endpoint, params: params, server: connection, maxAttempts: 2)
            let type = params.first { $0.key.lowercased() == "format" }?.value
            return (data, type.flatMap { $0.hasPrefix("image/") ? $0 : nil } ?? "image/png")
        }
    }

    /// True when the native spatial reference is projected (metres), so the sheet margins carry
    /// eastings and northings rather than degrees.
    var isProjected: Bool {
        guard let e = layer.nativeExtent else { return false }
        return abs(e.xmin) > 180 || abs(e.xmax) > 180 || abs(e.ymin) > 90 || abs(e.ymax) > 90
    }

    var nativeName: String {
        layer.effectiveWkid.map { "\(srName($0)) (\($0))" } ?? "its native spatial reference"
    }

    func updateStoredRuns(_ runs: [DownloadRecord]) { storedRuns = runs }

    // MARK: - Loading

    func load() async {
        isLoading = true
        error = nil
        selectedFeature = nil
        transfer = nil
        defer { isLoading = false; transfer = nil }
        do {
            if service.type.isOGC, source == .sample {
                try await loadOGCSample()
                return
            }
            content.rasterTiles = nil
            content.rasterImage = nil
            switch source {
            case .sample:
                var options = QueryOptions(outFields: nil, returnGeometry: true, outWkid: 4326, count: sampleSize)
                options.geometryPrecision = 6
                let set = try await client.features(connection, layerURL: layerURL, options: options, progress: { progress in
                    Task { @MainActor in self.transfer = progress }
                }).value
                let page = FeaturePage(json: set)
                let features = Self.features(page)
                content.featuresGeoJSON = GeoJSON.featureCollection(features)
                let extent = layer.extentWGS84.flatMap { $0.isDefaultLike ? nil : $0 }
                content.fit = extent ?? bounds(of: page) ?? layer.extentWGS84
                content.fitToken += 1
                let total = layer.featureCount.map { $0.grouped } ?? "an unknown number of"
                caption = "\(features.count.grouped) of \(total) features, drawn in WGS 84. Dashed box is the layer extent in \(nativeName)."
                if set.exceededTransferLimit == false, layer.featureCount == nil {
                    caption = "All \(features.count.grouped) features, drawn in WGS 84. Dashed box is the layer extent in \(nativeName)."
                }
            case .stored(let id):
                guard let run = storedRuns.first(where: { $0.id == id }), let path = run.outputPath else {
                    throw MetadataStoreError.notFound("download \(id)")
                }
                let sample = try await database.storedSample(path: path, whereClause: storedWhere)
                content.featuresGeoJSON = sample.geoJSON
                content.fit = layer.extentWGS84
                content.fitToken += 1
                let simplified = sample.simplified ? ", simplified for the screen" : ""
                caption = "\(sample.shown.grouped) of \(sample.total.grouped) stored features\(simplified), from \(URL(fileURLWithPath: path).lastPathComponent)."
            case .query:
                guard let set = querySet else { throw MetadataStoreError.notFound("query preview") }
                guard queryWkid == 4326 || queryWkid == nil && layer.effectiveWkid == 4326 else {
                    throw MapError.previewNotGeographic
                }
                let page = FeaturePage(json: set)
                let features = Self.features(page)
                content.featuresGeoJSON = GeoJSON.featureCollection(features)
                content.fit = bounds(of: page) ?? layer.extentWGS84
                content.fitToken += 1
                caption = "The \(features.count.grouped) features of the current query preview."
            }
        } catch {
            self.error = String(describing: error)
        }
    }

    // MARK: - OGC layers (M10)

    /// What the map can show of an OGC layer: a WFS type as a sample of its features in WGS 84;
    /// a WMS layer as tiles in Web Mercator, or as one picture of its extent when it offers no
    /// Web Mercator; a WMTS layer as tiles from a Web Mercator matrix set.
    private func loadOGCSample() async throws {
        guard let detail = service.ogcDetail, let ogc = layer.ogcDetail, let name = layer.ogcName else {
            throw MapError.noCapabilities
        }
        content.rasterTiles = nil
        content.rasterImage = nil
        let extent = layer.extentWGS84.flatMap { $0.isDefaultLike ? nil : $0 }
        switch service.type {
        case .wfs:
            let native = layer.effectiveWkid ?? 4326
            let askWGS84 = native != 4326 && ogc.wgs84CRS != nil
            let format = detail.geoJSONFormat
            let params = OGCRequests.getFeature(version: detail.version, typeName: name, format: format, startIndex: nil,
                                                count: sampleSize, srsName: askWGS84 ? ogc.wgs84CRS : nil)
            let data = try await client.fetch(root: connection.rootURL, params: params, server: connection, progress: { progress in
                Task { @MainActor in self.transfer = progress }
            })
            let geoJSON: String
            if format != nil, askWGS84 || native == 4326 {
                geoJSON = String(decoding: data, as: UTF8.self)
            } else {
                // GML, or a projected reference the server would not translate: the spatial engine does.
                geoJSON = try await database.geoJSONInWGS84(data: data, fileExtension: format != nil ? "json" : "gml", sourceWkid: native)
            }
            content.featuresGeoJSON = geoJSON
            content.fit = extent ?? layer.extentWGS84
            content.fitToken += 1
            let drawn = Self.featureCount(in: geoJSON)
            let total = layer.featureCount.map { $0.grouped } ?? "an unknown number of"
            caption = "\(drawn.grouped) of \(total) features, drawn in WGS 84 from a \(format != nil ? "GeoJSON" : "GML") GetFeature. Dashed box is the layer extent."
        case .wms:
            let style = ogc.styles.first ?? ""
            let picture = detail.formats.first { $0.lowercased().hasPrefix("image/png") } ?? detail.formats.first ?? "image/png"
            if let mercator = ogc.webMercatorCRS {
                let params = OGCRequests.getMap(version: detail.version, layer: name, style: style, crs: mercator, bbox: "{bbox-epsg-3857}",
                                                width: 256, height: 256, format: picture, transparent: true)
                content.rasterTiles = TileProxy.proxied(Self.withPlaceholders(OGCURL.url(root: connection.rootURL, params: params).absoluteString))
                caption = "WMS layer drawn as 256px tiles in Web Mercator. Dashed box is the layer extent."
            } else if let wgs = ogc.wgs84CRS ?? (ogc.crs.isEmpty ? "EPSG:4326" : nil), let box = layer.extentWGS84, !box.isDegenerate {
                let width = 1024
                let height = max(1, Int((Double(width) * box.height / box.width).rounded()))
                let bbox = OGCRequests.getMapBBox(version: detail.version, crs: wgs, minX: box.minX, minY: box.minY, maxX: box.maxX, maxY: box.maxY)
                let params = OGCRequests.getMap(version: detail.version, layer: name, style: style, crs: wgs, bbox: bbox,
                                                width: width, height: min(height, 4096), format: picture, transparent: true)
                let url = TileProxy.proxied(OGCURL.url(root: connection.rootURL, params: params).absoluteString)
                content.rasterImage = MapContent.RasterImage(url: url, coordinates: [[box.minX, box.maxY], [box.maxX, box.maxY], [box.maxX, box.minY], [box.minX, box.minY]])
                caption = "WMS layer drawn as one picture of its extent in WGS 84 (it offers no Web Mercator). Dashed box is the layer extent."
            } else {
                throw MapError.noDrawableCRS(ogc.crs)
            }
            content.fit = extent ?? layer.extentWGS84
            content.fitToken += 1
        case .wmts:
            guard let setID = ogc.tileMatrixSetLinks.first(where: { link in detail.tileMatrixSets.first { $0.identifier == link }?.isWebMercator == true }),
                  let set = detail.tileMatrixSets.first(where: { $0.identifier == setID }),
                  let matrix = OGCRequests.matrixTemplate(set) else {
                throw MapError.noWebMercatorTiles(ogc.tileMatrixSetLinks)
            }
            let style = ogc.styles.first ?? "default"
            let template: String
            if let resource = ogc.resourceURLTemplates.first {
                template = resource
                    .replacingOccurrences(of: "{TileMatrixSet}", with: setID)
                    .replacingOccurrences(of: "{TileMatrix}", with: matrix)
                    .replacingOccurrences(of: "{TileRow}", with: "{y}")
                    .replacingOccurrences(of: "{TileCol}", with: "{x}")
                    .replacingOccurrences(of: "{Style}", with: style)
            } else {
                let params = OGCRequests.getTile(layer: name, style: style, tileMatrixSet: setID, matrixTemplate: matrix,
                                                 format: ogc.formats.first ?? "image/png")
                template = Self.withPlaceholders(OGCURL.url(root: connection.rootURL, params: params).absoluteString)
            }
            content.rasterTiles = TileProxy.proxied(template)
            content.fit = extent ?? layer.extentWGS84
            content.fitToken += 1
            caption = "WMTS tiles from the \(setID) matrix set, \(set.tileWidth ?? 256)px, Web Mercator. Dashed box is the layer extent."
        default:
            throw MapError.noCapabilities
        }
    }

    /// The client percent-encodes every parameter; MapLibre's placeholders must come back.
    private static func withPlaceholders(_ url: String) -> String {
        url.replacingOccurrences(of: "%7Bbbox-epsg-3857%7D", with: "{bbox-epsg-3857}")
            .replacingOccurrences(of: "%7Bz%7D", with: "{z}")
            .replacingOccurrences(of: "%7Bx%7D", with: "{x}")
            .replacingOccurrences(of: "%7By%7D", with: "{y}")
    }

    private static func featureCount(in geoJSON: String) -> Int {
        guard let data = geoJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = object["features"] as? [Any] else { return 0 }
        return features.count
    }

    /// GeoJSON features with every attribute as a display string (dates ISO, NULLs named), so
    /// a click can show them without another request. Keys carry their position so the panel
    /// keeps field order.
    static func features(_ page: FeaturePage) -> [String] {
        page.features.compactMap { feature in
            guard let geometry = feature.geometry else { return nil }
            var properties = [String: String]()
            for (index, (field, value)) in zip(page.fields, feature.attributes).enumerated() {
                properties[String(format: "%03d|%@", index, field.name)] = QueryGrid.cell(json(value), type: field.type)
            }
            return GeoJSON.feature(geometry, properties: properties)
        }
    }

    private static func json(_ v: AttributeValue) -> JSONValue? {
        switch v {
        case .null: return nil
        case .int(let i): return .number(Double(i))
        case .double(let d): return .number(d)
        case .string(let s): return .string(s)
        case .bool(let b): return .bool(b)
        }
    }

    // MARK: - Selection

    /// A clicked feature (from the web page) or a click on empty map (nil).
    func featureClicked(_ properties: [String: String]?) {
        guard let properties else { selectedFeature = nil; return }
        let ordered = properties.filter { !$0.key.hasPrefix("__") }.sorted { $0.key < $1.key }
            .map { key, value -> (String, String) in
                let name = key.split(separator: "|", maxSplits: 1).last.map(String.init) ?? key
                return (name, value)
            }
        selectedFeature = ordered.isEmpty ? [("geometry", properties["__geometry"] ?? "feature")] : ordered
    }

    func clearSelection() {
        selectedFeature = nil
        content.clearToken += 1
    }

    private func bounds(of page: FeaturePage) -> BoundingBox? {
        var box: BoundingBox?
        func visit(_ c: [Double]) {
            guard c.count >= 2 else { return }
            let b = BoundingBox(minX: c[0], minY: c[1], maxX: c[0], maxY: c[1])
            box = box.map { $0.union(b) } ?? b
        }
        for feature in page.features {
            switch feature.geometry {
            case .point(let c)?: visit(c)
            case .multipoint(let p)?: p.forEach(visit)
            case .polyline(let paths)?: paths.forEach { $0.forEach(visit) }
            case .polygon(let rings)?: rings.forEach { $0.forEach(visit) }
            case .envelope(let xmin, let ymin, let xmax, let ymax)?: visit([xmin, ymin]); visit([xmax, ymax])
            case nil: break
            }
        }
        return box
    }

    // MARK: - Graticule

    func viewportChanged(_ v: MapViewport) {
        viewport = v
        graticuleTask?.cancel()
        graticuleTask = Task { [weak self] in
            guard let self else { return }
            let g: Graticule
            if isProjected, let wkid = layer.effectiveWkid {
                let database = self.database
                do {
                    g = try await Graticule.projected(v,
                        toNative: { try await database.transform($0, from: 4326, to: wkid) },
                        toGeographic: { try await database.transform($0, from: wkid, to: 4326) })
                } catch {
                    g = Graticule.geographic(v)
                }
            } else {
                g = Graticule.geographic(v)
            }
            guard !Task.isCancelled else { return }
            graticule = g
            content.graticuleGeoJSON = g.linesGeoJSON
        }
    }
}

enum MapError: Error, CustomStringConvertible {
    case previewNotGeographic
    case noCapabilities
    case noDrawableCRS([String])
    case noWebMercatorTiles([String])
    var description: String {
        switch self {
        case .previewNotGeographic:
            return "The query preview was fetched in the native spatial reference; choose WGS 84 in the Query tab and preview again to map it."
        case .noCapabilities:
            return "The service's capabilities have not been fetched yet; refresh the service."
        case .noDrawableCRS(let crs):
            return "The layer is offered in neither Web Mercator nor WGS 84, so the map cannot draw it; it offers \(crs.joined(separator: ", "))."
        case .noWebMercatorTiles(let sets):
            return "None of the layer's tile matrix sets is Web Mercator, so the map cannot draw it; it links \(sets.joined(separator: ", "))."
        }
    }
}
