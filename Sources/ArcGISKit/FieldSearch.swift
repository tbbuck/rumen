import Foundation
import SQLiteKit

/// Options for column search (SPEC §5.8).
public struct FieldSearchOptions: Sendable, Equatable {
    public var text: String
    public var caseSensitive = false
    public var partial = true
    public var regex = false
    public var includeAlias = false
    /// nil = every known server.
    public var serverID: Int64? = nil
    public var limit = 500

    public init(text: String, caseSensitive: Bool = false, partial: Bool = true, regex: Bool = false,
                includeAlias: Bool = false, serverID: Int64? = nil, limit: Int = 500) {
        self.text = text
        self.caseSensitive = caseSensitive
        self.partial = partial
        self.regex = regex
        self.includeAlias = includeAlias
        self.serverID = serverID
        self.limit = limit
    }
}

/// One matching field with enough context to show and to navigate to.
public struct FieldSearchHit: Sendable, Equatable, Identifiable {
    public let fieldName: String
    public let alias: String?
    public let esriType: EsriFieldType
    public let duckType: String
    public let layerID: Int64
    public let layerName: String
    public let layerNumber: Int
    public let extractable: Bool?
    public let serviceID: Int64
    public let serviceName: String
    public let serviceType: ServiceType
    public let serverID: Int64
    public let serverName: String

    public var id: String { "\(layerID)/\(fieldName)" }
    /// True when the match came from the alias rather than the name.
    public var matchedAlias: Bool

    public init(fieldName: String, alias: String?, esriType: EsriFieldType, duckType: String, layerID: Int64,
                layerName: String, layerNumber: Int, extractable: Bool?, serviceID: Int64, serviceName: String,
                serviceType: ServiceType, serverID: Int64, serverName: String, matchedAlias: Bool = false) {
        self.fieldName = fieldName
        self.alias = alias
        self.esriType = esriType
        self.duckType = duckType
        self.layerID = layerID
        self.layerName = layerName
        self.layerNumber = layerNumber
        self.extractable = extractable
        self.serviceID = serviceID
        self.serviceName = serviceName
        self.serviceType = serviceType
        self.serverID = serverID
        self.serverName = serverName
        self.matchedAlias = matchedAlias
    }
}

public enum FieldSearchError: Error, CustomStringConvertible, Equatable {
    case badRegex(String)
    public var description: String {
        switch self { case .badRegex(let m): return "invalid regular expression: \(m)" }
    }
}

extension AppDatabase {
    private static let hitColumns = """
        f.name, f.alias, f.esri_type, f.duck_type, l.id, l.name, l.layer_id, l.extractable,
        s.id, s.name, s.type, sv.id, sv.friendly_name
        """

    /// Searches cached field metadata. Case-insensitive partial matching by default; exact,
    /// case-sensitive, regex, and alias matching on request; scoped to one server or all.
    public func searchFields(_ options: FieldSearchOptions) throws -> [FieldSearchHit] {
        let text = options.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let scope = options.serverID.map { " AND sv.id = \($0)" } ?? ""
        let base = """
            FROM field f
            JOIN layer l ON l.id = f.layer_id
            JOIN service s ON s.id = l.service_id
            JOIN server sv ON sv.id = s.server_id
            """
        let order = " ORDER BY sv.friendly_name COLLATE NOCASE, s.name COLLATE NOCASE, l.layer_id, f.position"

        if options.regex {
            let expression: NSRegularExpression
            do {
                expression = try NSRegularExpression(pattern: text, options: options.caseSensitive ? [] : [.caseInsensitive])
            } catch {
                throw FieldSearchError.badRegex(error.localizedDescription)
            }
            let rows = try query("SELECT \(Self.hitColumns) \(base) WHERE 1=1\(scope)\(order);").rows
            var hits = [FieldSearchHit]()
            for row in rows {
                guard var hit = Self.hit(row) else { continue }
                if expression.firstMatch(in: hit.fieldName, range: NSRange(hit.fieldName.startIndex..., in: hit.fieldName)) != nil {
                    hits.append(hit)
                } else if options.includeAlias, let alias = hit.alias,
                          expression.firstMatch(in: alias, range: NSRange(alias.startIndex..., in: alias)) != nil {
                    hit.matchedAlias = true
                    hits.append(hit)
                }
                if hits.count >= options.limit { break }
            }
            return hits
        }

        let (condition, param) = Self.condition(text, caseSensitive: options.caseSensitive, partial: options.partial)
        let nameMatch = condition.replacingOccurrences(of: "{col}", with: "f.name")
        let aliasMatch = condition.replacingOccurrences(of: "{col}", with: "f.alias")
        let whereClause = options.includeAlias ? "(\(nameMatch) OR \(aliasMatch))" : nameMatch
        let params: [SQLBind] = options.includeAlias ? [.string(param), .string(param)] : [.string(param)]
        let rows = try query("SELECT \(Self.hitColumns), \(nameMatch) AS by_name \(base) WHERE \(whereClause)\(scope)\(order) LIMIT \(options.limit);",
                             options.includeAlias ? params + [.string(param)] : params + [.string(param)]).rows
        return rows.compactMap { row in
            guard var hit = Self.hit(row) else { return nil }
            hit.matchedAlias = row.count > 13 && row[13].boolValue == false
            return hit
        }
    }

    /// The SQL condition for `{col}` and the parameter it binds. LIKE is case-insensitive for
    /// ASCII in SQLite; `instr` and `=` are case-sensitive.
    static func condition(_ text: String, caseSensitive: Bool, partial: Bool) -> (String, String) {
        switch (caseSensitive, partial) {
        case (false, true):
            let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            return ("{col} LIKE ? ESCAPE '\\'", "%\(escaped)%")
        case (false, false): return ("{col} = ? COLLATE NOCASE", text)
        case (true, true): return ("instr({col}, ?) > 0", text)
        case (true, false): return ("{col} = ?", text)
        }
    }

    private static func hit(_ r: [SQLValue]) -> FieldSearchHit? {
        guard r.count >= 13, let name = r[0].stringValue, let esri = r[2].stringValue, let duck = r[3].stringValue,
              let layerID = r[4].int64, let layerName = r[5].stringValue, let number = r[6].intValue,
              let serviceID = r[8].int64, let serviceName = r[9].stringValue, let type = r[10].stringValue,
              let serverID = r[11].int64, let serverName = r[12].stringValue else { return nil }
        return FieldSearchHit(fieldName: name, alias: r[1].stringValue, esriType: EsriFieldType(rawValue: esri), duckType: duck,
                              layerID: layerID, layerName: layerName, layerNumber: number, extractable: r[7].boolValue,
                              serviceID: serviceID, serviceName: serviceName, serviceType: ServiceType(type),
                              serverID: serverID, serverName: serverName)
    }

    /// Map/Feature services in scope whose layers have never been fetched — what search cannot see.
    public func uncrawledServiceCount(serverID: Int64? = nil) throws -> Int {
        let scope = serverID.map { " AND server_id = \($0)" } ?? ""
        return try query("SELECT count(*) FROM service WHERE type IN ('MapServer', 'FeatureServer') AND fetched_at IS NULL\(scope);")
            .rows.first?.first?.intValue ?? 0
    }
}
