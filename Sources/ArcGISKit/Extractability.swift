import Foundation

/// The answer to "can I get this out?" (SPEC §5.3) and how (SPEC §5.6), computed from cached
/// metadata alone. The count probe (network) confirms or overturns it.
public struct Assessment: Sendable, Equatable {
    public enum Transport: String, Sendable { case pbf, json }
    public enum Strategy: String, Sendable {
        case offset, oidRange = "oid_range", oidList = "oid_list"

        public var label: String {
            switch self { case .offset: "offset paging"; case .oidRange: "OID range chunking"; case .oidList: "OID list chunking" }
        }
    }

    /// true = extractable, false = not, nil = cannot say yet (layer not crawled).
    public let verdict: Bool?
    /// The sentence after the verdict word, e.g. "This is a raster layer; nothing to query."
    public let reason: String
    public let transport: Transport?
    public let strategy: Strategy?
    public let pageSize: Int?
    /// The layer to download from: a FeatureServer twin when it is the better source.
    public let sourceLayerID: Int64
    public var viaTwin: Bool { sourceLayerID != layerID }
    public let layerID: Int64

    public init(verdict: Bool?, reason: String, transport: Transport? = nil, strategy: Strategy? = nil,
                pageSize: Int? = nil, layerID: Int64, sourceLayerID: Int64? = nil) {
        self.verdict = verdict
        self.reason = reason
        self.transport = transport
        self.strategy = strategy
        self.pageSize = pageSize
        self.layerID = layerID
        self.sourceLayerID = sourceLayerID ?? layerID
    }

    /// Requests a full download would take at this page size, if the count is known.
    public func requestCount(features: Int64) -> Int? {
        guard let pageSize, pageSize > 0 else { return nil }
        return Int((features + Int64(pageSize) - 1) / Int64(pageSize))
    }

    /// The statement's second sentence for an extractable layer once the count is known:
    /// "184,212 features in 93 requests."
    public func countSentence(features: Int64) -> String {
        let n = features.formatted(.number.grouping(.automatic))
        if let requests = requestCount(features: features) {
            return "\(n) feature\(features == 1 ? "" : "s") in \(requests.formatted(.number.grouping(.automatic))) request\(requests == 1 ? "" : "s")."
        }
        return "\(n) features."
    }
}

public enum Extractability {
    /// Layer types that can never answer `query` with features.
    static let nonFeatureTypes: Set<String> = [
        "Group Layer", "Raster Layer", "Raster Catalog Layer", "Mosaic Layer", "Image Service Layer",
        "Annotation Layer", "Dimension Layer", "Network Analysis Layer", "Utility Network Layer",
        "Catalog Layer", "Subtype Group Layer", "Annotation SubLayer", "Dimension SubLayer",
    ]

    /// Assesses `layer` (with its service, and its FeatureServer twin layer when known).
    /// The twin is preferred when it offers PBF or paging that the MapServer layer lacks.
    public static func assess(layer: LayerRecord, service: ServiceRecord, twin: LayerRecord? = nil,
                              twinService: ServiceRecord? = nil) -> Assessment {
        let own = assessSingle(layer: layer, service: service)
        guard let twin, let twinService, service.type == .mapServer, twinService.type == .featureServer else { return own }
        let viaTwin = assessSingle(layer: twin, service: twinService)
        guard viaTwin.verdict == true else { return own }
        let twinBetter = own.verdict != true
            || (viaTwin.transport == .pbf && own.transport != .pbf)
            || (viaTwin.strategy == .offset && own.strategy != .offset)
        guard twinBetter else { return own }
        return Assessment(verdict: true,
                          reason: Self.how(transport: viaTwin.transport!, strategy: viaTwin.strategy!,
                                           pageSize: viaTwin.pageSize, viaTwin: true),
                          transport: viaTwin.transport, strategy: viaTwin.strategy, pageSize: viaTwin.pageSize,
                          layerID: layer.id, sourceLayerID: twin.id)
    }

    static func assessSingle(layer: LayerRecord, service: ServiceRecord) -> Assessment {
        let id = layer.id
        guard layer.isCrawled else {
            return Assessment(verdict: nil, reason: "The layer definition has not been fetched yet.", layerID: id)
        }
        if let type = layer.type, nonFeatureTypes.contains(type) {
            let article = type.first.map { "aeiou".contains($0.lowercased()) } == true ? "an" : "a"
            let hint = type == "Group Layer" ? "; pick one of its sub-layers" : "; nothing to query"
            return Assessment(verdict: false, reason: "This is \(article) \(type.lowercased())\(hint).", layerID: id)
        }
        // Query capability: the layer's own, else the service's.
        let capabilities = layer.capabilities != nil ? layer.capabilitySet : service.capabilitySet
        guard capabilities.contains("Query") else {
            let where_ = layer.capabilities != nil ? "The layer" : "The service"
            let tiles = service.isTileCache == true ? " It serves pre-rendered tiles." : ""
            return Assessment(verdict: false, reason: "\(where_) does not advertise the Query capability.\(tiles)", layerID: id)
        }
        // Transport.
        let formats = layer.supportedQueryFormats != nil ? layer.queryFormats
            : Set(Capabilities.parse(service.supportedQueryFormats).map { $0.uppercased() })
        let transport: Assessment.Transport
        if formats.contains("PBF") { transport = .pbf }
        else if formats.contains("JSON") || formats.isEmpty { transport = .json }
        else {
            return Assessment(verdict: false, reason: "The layer advertises only \(formats.sorted().joined(separator: ", ")) for queries; JSON or PBF is needed.", layerID: id)
        }
        // Strategy ladder.
        let pageSize = layer.maxRecordCount ?? service.maxRecordCount ?? 1000
        let strategy: Assessment.Strategy
        if layer.supportsPagination == true { strategy = .offset }
        else if layer.supportsStatistics == true { strategy = .oidRange }
        else { strategy = .oidList }
        if strategy != .offset && layer.objectIdField == nil {
            return Assessment(verdict: false, reason: "The layer has no paging support and no object ID field to chunk on.", layerID: id)
        }
        return Assessment(verdict: true, reason: how(transport: transport, strategy: strategy, pageSize: pageSize, viaTwin: false),
                          transport: transport, strategy: strategy, pageSize: pageSize, layerID: id)
    }

    /// "PBF through the FeatureServer twin, offset paging at 2,000 records per request."
    static func how(transport: Assessment.Transport, strategy: Assessment.Strategy, pageSize: Int?, viaTwin: Bool) -> String {
        let via = viaTwin ? " through the FeatureServer twin" : ""
        let size = pageSize.map { " at \($0.formatted(.number.grouping(.automatic))) records per request" } ?? ""
        return "\(transport == .pbf ? "PBF" : "JSON")\(via), \(strategy.label)\(size)."
    }
}
