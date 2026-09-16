import Foundation
import SwiftProtobuf

public enum PBFError: Error, CustomStringConvertible, Equatable {
    case notAFeatureResult(String)
    case malformed(String)

    public var description: String {
        switch self {
        case .notAFeatureResult(let what): return "the PBF response is not a feature result (\(what))"
        case .malformed(let what): return "malformed PBF feature collection: \(what)"
        }
    }
}

/// Decodes Esri's `FeatureCollection` protobuf (`f=pbf`) into a `FeaturePage`, dequantising
/// geometry with the response transform (SPEC §5.6).
public enum PBFDecoder {
    typealias PB = EsriPBuffer_FeatureCollectionPBuffer

    public static func decode(_ data: Data) throws -> FeaturePage {
        let collection: PB
        do { collection = try PB(serializedBytes: data) } catch { throw PBFError.malformed(String(describing: error)) }
        guard case .featureResult(let result)? = collection.queryResult.results else {
            let kind: String
            switch collection.queryResult.results {
            case .countResult?: kind = "count result"
            case .idsResult?: kind = "ids result"
            case .extentCountResult?: kind = "extent result"
            default: kind = "empty"
            }
            throw PBFError.notAFeatureResult(kind)
        }
        let fields = result.fields.map(field)
        let geometryType = geometryTypeName(result.geometryType)
        let transform = result.hasTransform ? result.transform : nil
        let hasZ = result.hasZ_p   // the generator renames proto fields called has*
        let hasM = result.hasM_p
        let stride = 2 + (hasZ ? 1 : 0) + (hasM ? 1 : 0)
        let features = try result.features.map { feature -> DecodedFeature in
            guard feature.attributes.count == fields.count else {
                throw PBFError.malformed("feature has \(feature.attributes.count) values for \(fields.count) fields")
            }
            let attributes = feature.attributes.map(value)
            var geometry: EsriGeometry?
            if case .geometry(let g)? = feature.compressedGeometry {
                geometry = try decodeGeometry(g, type: result.geometryType, transform: transform, stride: stride)
            }
            return DecodedFeature(attributes: attributes, geometry: geometry)
        }
        let wkid = result.hasSpatialReference
            ? Int(result.spatialReference.lastestWkid != 0 ? result.spatialReference.lastestWkid : result.spatialReference.wkid)
            : nil
        return FeaturePage(fields: fields, features: features, geometryType: geometryType, wkid: wkid == 0 ? nil : wkid,
                           hasZ: hasZ, hasM: hasM, exceededTransferLimit: result.exceededTransferLimit)
    }

    // MARK: - Fields and values

    static func field(_ f: PB.Field) -> FieldInfo {
        let json = "{\"name\":\(quote(f.name)),\"type\":\(quote(esriFieldTypeName(f.fieldType))),\"alias\":\(quote(f.alias))}"
        // FieldInfo is Decodable-only; round-trip through JSON keeps one definition of it.
        return (try? JSONDecoder().decode(FieldInfo.self, from: Data(json.utf8)))
            ?? (try! JSONDecoder().decode(FieldInfo.self, from: Data("{\"name\":\"?\",\"type\":\"esriFieldTypeString\"}".utf8)))
    }

    private static func quote(_ s: String) -> String {
        let data = (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func esriFieldTypeName(_ t: PB.FieldType) -> String {
        switch t {
        case .esriFieldTypeSmallInteger: return "esriFieldTypeSmallInteger"
        case .esriFieldTypeInteger: return "esriFieldTypeInteger"
        case .esriFieldTypeSingle: return "esriFieldTypeSingle"
        case .esriFieldTypeDouble: return "esriFieldTypeDouble"
        case .esriFieldTypeString: return "esriFieldTypeString"
        case .esriFieldTypeDate: return "esriFieldTypeDate"
        case .esriFieldTypeOid: return "esriFieldTypeOID"
        case .esriFieldTypeGeometry: return "esriFieldTypeGeometry"
        case .esriFieldTypeBlob: return "esriFieldTypeBlob"
        case .esriFieldTypeRaster: return "esriFieldTypeRaster"
        case .esriFieldTypeGuid: return "esriFieldTypeGUID"
        case .esriFieldTypeGlobalID: return "esriFieldTypeGlobalID"
        case .esriFieldTypeXml: return "esriFieldTypeXML"
        case .esriFieldTypeBigInteger: return "esriFieldTypeBigInteger"
        case .esriFieldTypeDateOnly: return "esriFieldTypeDateOnly"
        case .esriFieldTypeTimeOnly: return "esriFieldTypeTimeOnly"
        case .esriFieldTypeTimestampOffset: return "esriFieldTypeTimestampOffset"
        case .UNRECOGNIZED(let i): return "esriFieldTypeUnknown\(i)"
        }
    }

    static func geometryTypeName(_ t: PB.GeometryType) -> String? {
        switch t {
        case .esriGeometryTypePoint: return "esriGeometryPoint"
        case .esriGeometryTypeMultipoint: return "esriGeometryMultipoint"
        case .esriGeometryTypePolyline: return "esriGeometryPolyline"
        case .esriGeometryTypePolygon: return "esriGeometryPolygon"
        case .esriGeometryTypeMultipatch: return "esriGeometryMultiPatch"
        case .esriGeometryTypeEnvelope: return "esriGeometryEnvelope"
        case .esriGeometryTypeNone, .UNRECOGNIZED: return nil
        }
    }

    static func value(_ v: PB.Value) -> AttributeValue {
        switch v.valueType {
        case .stringValue(let s)?: return .string(s)
        case .floatValue(let f)?: return .double(Double(f))
        case .doubleValue(let d)?: return .double(d)
        case .sintValue(let i)?: return .int(Int64(i))
        case .uintValue(let u)?: return .int(Int64(u))
        case .int64Value(let i)?: return .int(i)
        case .uint64Value(let u)?: return u > UInt64(Int64.max) ? .double(Double(u)) : .int(Int64(u))
        case .sint64Value(let i)?: return .int(i)
        case .boolValue(let b)?: return .bool(b)
        case .nullValue?, nil: return .null
        }
    }

    // MARK: - Geometry

    /// Coordinates are delta-encoded integers; the running total restarts at each part. With
    /// an upper-left quantisation origin, y grows downwards, so world y = translate − y·scale.
    static func decodeGeometry(_ g: PB.Geometry, type: PB.GeometryType, transform: PB.Transform?, stride: Int) throws -> EsriGeometry? {
        let coords = g.coords
        guard !coords.isEmpty else { return nil }
        let xScale = transform?.hasScale == true ? transform!.scale.xScale : 1
        let yScale = transform?.hasScale == true ? transform!.scale.yScale : 1
        let zScale = transform?.hasScale == true ? transform!.scale.zScale : 1
        let mScale = transform?.hasScale == true ? transform!.scale.mScale : 1
        let xT = transform?.hasTranslate == true ? transform!.translate.xTranslate : 0
        let yT = transform?.hasTranslate == true ? transform!.translate.yTranslate : 0
        let zT = transform?.hasTranslate == true ? transform!.translate.zTranslate : 0
        let mT = transform?.hasTranslate == true ? transform!.translate.mTranslate : 0
        let flipY = (transform?.quantizeOriginPostion ?? .upperLeft) == .upperLeft

        func world(_ q: [Int64]) -> [Double] {
            var out = [Double]()
            out.append(Double(q[0]) * xScale + xT)
            out.append(flipY ? yT - Double(q[1]) * yScale : Double(q[1]) * yScale + yT)
            if stride >= 3 { out.append(Double(q[2]) * (stride == 3 && transform?.hasScale == true && zScale == 0 ? mScale : zScale) + (stride == 3 && zScale == 0 ? mT : zT)) }
            if stride >= 4 { out.append(Double(q[3]) * mScale + mT) }
            return out
        }

        /// Decodes `count` vertices starting at `offset`, deltas accumulating within the part.
        func part(_ offset: Int, _ count: Int) throws -> [[Double]] {
            let end = offset + count * stride
            guard end <= coords.count else { throw PBFError.malformed("coordinate run past end of coords") }
            var running = [Int64](repeating: 0, count: stride)
            var vertices = [[Double]]()
            vertices.reserveCapacity(count)
            var i = offset
            while i < end {
                for d in 0..<stride { running[d] += coords[i + d] }
                vertices.append(world(running))
                i += stride
            }
            return vertices
        }

        switch type {
        case .esriGeometryTypePoint:
            return .point(world(Array(coords.prefix(stride))))
        case .esriGeometryTypeMultipoint:
            let count = g.lengths.first.map(Int.init) ?? coords.count / stride
            return .multipoint(try part(0, count))
        case .esriGeometryTypePolyline, .esriGeometryTypePolygon:
            var parts = [[[Double]]]()
            var offset = 0
            for length in g.lengths {
                parts.append(try part(offset, Int(length)))
                offset += Int(length) * stride
            }
            if parts.isEmpty { return nil }
            return type == .esriGeometryTypePolyline ? .polyline(paths: parts) : .polygon(rings: parts)
        case .esriGeometryTypeEnvelope:
            let count = coords.count / stride
            let pts = try part(0, count)
            guard pts.count >= 2 else { return nil }
            return .envelope(xmin: pts[0][0], ymin: min(pts[0][1], pts[1][1]), xmax: pts[1][0], ymax: max(pts[0][1], pts[1][1]))
        case .esriGeometryTypeMultipatch, .esriGeometryTypeNone, .UNRECOGNIZED:
            return nil
        }
    }
}
