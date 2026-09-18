import Foundation

/// A column of the results grid.
public struct GridColumn: Sendable, Equatable {
    public let name: String
    /// Short type label for the header's second line: `String 25`, `Integer`, `Date`, `Geometry`.
    public let typeLabel: String
    public let isNumeric: Bool

    public init(name: String, typeLabel: String, isNumeric: Bool) {
        self.name = name
        self.typeLabel = typeLabel
        self.isNumeric = isNumeric
    }
}

/// Results rendered for display: every cell already a string, so the grid does no work per
/// scroll. Dates are ISO 8601 UTC, NULLs read `NULL`, geometry is a WKT point or a summary.
public struct QueryGrid: Sendable, Equatable {
    public static let geometryColumn = "geometry"
    public let columns: [GridColumn]
    public let rows: [[String]]

    public init(columns: [GridColumn], rows: [[String]]) {
        self.columns = columns
        self.rows = rows
    }

    public var rowCount: Int { rows.count }

    /// A feature page: one column per response field, plus a trailing geometry column when
    /// any feature carries geometry.
    public static func features(_ set: FeatureSet) -> QueryGrid {
        var columns = set.fields.map { GridColumn(name: $0.name, typeLabel: Self.typeLabel($0), isNumeric: Self.isNumeric($0.type)) }
        let geometry = set.hasGeometry
        if geometry { columns.append(GridColumn(name: geometryColumn, typeLabel: "Geometry", isNumeric: false)) }
        let rows = set.features.map { feature -> [String] in
            var row = set.fields.map { Self.cell(feature.attributes[$0.name], type: $0.type) }
            if geometry { row.append(feature.geometry?.summary ?? "NULL") }
            return row
        }
        return QueryGrid(columns: columns, rows: rows)
    }

    /// Overview statistics as one row per field: Field · Count · Min · Max · Mean.
    public static func statistics(_ set: FeatureSet, definitions: [StatisticDefinition],
                                  fieldTypes: [String: EsriFieldType]) -> QueryGrid {
        let columns = [GridColumn(name: "field", typeLabel: "Field", isNumeric: false),
                       GridColumn(name: "count", typeLabel: "Count", isNumeric: true),
                       GridColumn(name: "min", typeLabel: "Min", isNumeric: true),
                       GridColumn(name: "max", typeLabel: "Max", isNumeric: true),
                       GridColumn(name: "avg", typeLabel: "Mean", isNumeric: true)]
        let attributes = set.features.first?.attributes ?? [:]
        var order = [String]()
        for definition in definitions where !order.contains(definition.onStatisticField) {
            order.append(definition.onStatisticField)
        }
        let rows = order.map { field -> [String] in
            let type = fieldTypes[field] ?? .double
            func value(_ kind: StatisticDefinition.Kind) -> String {
                guard let definition = definitions.first(where: { $0.onStatisticField == field && $0.statisticType == kind }) else { return "" }
                let raw = attributes[definition.outStatisticFieldName]
                // Averages of dates are meaningless; counts are always integers.
                let cellType: EsriFieldType = kind == .count ? .integer : (kind == .avg ? .double : type)
                return raw == nil ? "" : cell(raw, type: cellType)
            }
            return [field, value(.count), value(.min), value(.max), value(.avg)]
        }
        return QueryGrid(columns: columns, rows: rows)
    }

    // MARK: - Cells

    /// Renders one attribute value for its field type.
    public static func cell(_ value: JSONValue?, type: EsriFieldType) -> String {
        guard let value, !value.isNull else { return "NULL" }
        switch value {
        case .number(let d):
            if type == .date || type == .timestampOffset {
                return isoDate(millis: d)
            }
            if d == d.rounded(), abs(d) < 1e15 {
                return String(Int64(d))
            }
            return d.formatted(.number.precision(.fractionLength(0...10)).grouping(.never))
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .array, .object:
            guard let data = try? JSONEncoder().encode(value) else { return "…" }
            return String(decoding: data, as: UTF8.self)
        case .null: return "NULL"
        }
    }

    /// Esri dates are epoch milliseconds, UTC.
    public static func isoDate(millis: Double) -> String {
        let date = Date(timeIntervalSince1970: millis / 1000)
        let whole = date.formatted(.iso8601)
        let fraction = Int(millis.truncatingRemainder(dividingBy: 1000))
        if fraction == 0 { return whole }
        return String(whole.dropLast()) + String(format: ".%03dZ", abs(fraction))
    }

    static func typeLabel(_ field: FieldInfo) -> String {
        let base = field.type.rawValue.hasPrefix("esriFieldType") ? String(field.type.rawValue.dropFirst("esriFieldType".count)) : field.type.rawValue
        if field.type == .string, let length = field.length { return "\(base) \(length)" }
        return base
    }

    static func isNumeric(_ type: EsriFieldType) -> Bool {
        [.oid, .integer, .smallInteger, .bigInteger, .double, .single].contains(type)
    }
}
