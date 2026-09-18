import Foundation

/// One feature from a `query` response.
public struct Feature: Sendable, Equatable {
    public let attributes: [String: JSONValue]
    public let geometry: EsriGeometry?

    public init(attributes: [String: JSONValue], geometry: EsriGeometry? = nil) {
        self.attributes = attributes
        self.geometry = geometry
    }
}

/// A `query?f=json` response with features (a page, distinct values, or statistics).
public struct FeatureSet: Decodable, Sendable, Equatable {
    public let objectIdFieldName: String?
    public let globalIdFieldName: String?
    public let geometryType: String?
    public let spatialReference: SpatialReference?
    public let fields: [FieldInfo]
    public let features: [Feature]
    /// True when the server stopped at its transfer limit and more features remain.
    public let exceededTransferLimit: Bool

    private enum CodingKeys: String, CodingKey {
        case objectIdFieldName, globalIdFieldName, geometryType, spatialReference, fields, features, exceededTransferLimit
    }

    private struct RawFeature: Decodable {
        let attributes: [String: JSONValue]?
        let geometry: JSONValue?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        objectIdFieldName = try c.decodeIfPresent(String.self, forKey: .objectIdFieldName)
        globalIdFieldName = try c.decodeIfPresent(String.self, forKey: .globalIdFieldName)
        geometryType = try c.decodeIfPresent(String.self, forKey: .geometryType)
        spatialReference = try c.decodeIfPresent(SpatialReference.self, forKey: .spatialReference)
        fields = try c.decodeIfPresent([FieldInfo].self, forKey: .fields) ?? []
        let raw = try c.decodeIfPresent([RawFeature].self, forKey: .features) ?? []
        features = raw.map { Feature(attributes: $0.attributes ?? [:], geometry: EsriGeometry(json: $0.geometry)) }
        exceededTransferLimit = try c.decodeIfPresent(Bool.self, forKey: .exceededTransferLimit) ?? false
    }

    public init(fields: [FieldInfo], features: [Feature], geometryType: String? = nil,
                spatialReference: SpatialReference? = nil, exceededTransferLimit: Bool = false) {
        self.objectIdFieldName = nil
        self.globalIdFieldName = nil
        self.geometryType = geometryType
        self.spatialReference = spatialReference
        self.fields = fields
        self.features = features
        self.exceededTransferLimit = exceededTransferLimit
    }

    public var hasGeometry: Bool { features.contains { $0.geometry != nil } }
}

/// `query?returnExtentOnly=true`.
public struct ExtentResponse: Decodable, Sendable, Equatable {
    public let extent: Extent
    public let count: Int?
}
