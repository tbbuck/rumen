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
        content.fit = layer.extentWGS84.flatMap { $0.isWorldSized ? nil : $0 }
    }

    var layerURL: URL { service.url.appendingPathComponent(String(layer.layerID)) }
    var sampleSize: Int { min(layer.maxRecordCount ?? 1000, 800) }
    var hasQueryPreview: Bool { querySet?.hasGeometry == true }

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
        defer { isLoading = false }
        do {
            switch source {
            case .sample:
                var options = QueryOptions(outFields: nil, returnGeometry: true, outWkid: 4326, count: sampleSize)
                options.geometryPrecision = 6
                let set = try await client.features(connection, layerURL: layerURL, options: options).value
                let page = FeaturePage(json: set)
                let features = Self.features(page)
                content.featuresGeoJSON = GeoJSON.featureCollection(features)
                let extent = layer.extentWGS84.flatMap { $0.isWorldSized ? nil : $0 }
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

    func clearSelection() { selectedFeature = nil }

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
    var description: String {
        "The query preview was fetched in the native spatial reference; choose WGS 84 in the Query tab and preview again to map it."
    }
}
