import Foundation

/// An ArcGIS Online / Portal item named by a viewer URL: the portal it lives in, and its id.
///
/// The services behind a council's public map are often reachable *only* this way. Cherwell's
/// viewer draws five map services, each behind its own `usrsvcs` proxy with its own GUID, and
/// no directory anywhere enumerates them: the web map item is the only thing that lists them.
/// A pasted viewer URL is therefore not a dead end but a table of contents.
public struct PortalItemRef: Sendable, Equatable {
    /// The portal root: `https://org.maps.arcgis.com`, or `https://host/portal` on Enterprise.
    public let portal: URL
    /// The item's 32-character hexadecimal id.
    public let itemID: String

    public init(portal: URL, itemID: String) {
        self.portal = portal
        self.itemID = itemID
    }

    /// `…/sharing/rest/content/items/<id>`.
    public var itemURL: URL {
        portal.appendingPathComponent("sharing/rest/content/items").appendingPathComponent(itemID)
    }

    /// `…/sharing/rest/content/items/<id>/data` — the item's own document: an app's
    /// configuration, a web map's operational layers.
    public var dataURL: URL { itemURL.appendingPathComponent("data") }
}

public enum PortalURL {
    /// The query keys an item id hides behind, across viewers: Web AppBuilder and the item
    /// page use `id`, instant apps and Experience Builder `appid`, the map viewers `webmap`.
    private static let idKeys = ["id", "appid", "webmap", "itemid", "item"]

    /// The path segments that mark the end of the portal root and the start of an app's own
    /// path, so `https://host/portal/apps/…` yields `https://host/portal`.
    private static let appRoots = ["apps", "home"]

    /// Reads a viewer URL as an item reference, or nil when it is not one.
    public static func parse(_ text: String) -> PortalItemRef? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let host = components.host,
              let scheme = components.scheme, scheme == "http" || scheme == "https" else { return nil }

        let segments = components.path.split(separator: "/").map(String.init)
        guard let appIndex = segments.firstIndex(where: { appRoots.contains($0.lowercased()) }) else { return nil }

        // An id in the query, or — as dashboards and Experience Builder do — as the last path
        // segment: /apps/dashboards/<id>.
        let queryID = components.queryItems?.first { item in
            idKeys.contains(item.name.lowercased()) && isItemID(item.value)
        }?.value
        let pathID = segments.dropFirst(appIndex).last { isItemID($0) }
        guard let itemID = queryID ?? pathID else { return nil }

        var portal = URLComponents()
        portal.scheme = scheme
        portal.host = host
        portal.port = components.port
        let prefix = segments.prefix(appIndex)
        portal.path = prefix.isEmpty ? "" : "/" + prefix.joined(separator: "/")
        guard let url = portal.url else { return nil }
        return PortalItemRef(portal: url, itemID: itemID)
    }

    /// Item ids are 32 hexadecimal characters. Checked so that `?id=map` or a stray `webmap=1`
    /// is not mistaken for one.
    static func isItemID(_ value: String?) -> Bool {
        guard let value, value.count == 32 else { return false }
        return value.allSatisfy(\.isHexDigit)
    }
}

/// A service an item pointed at, with the title the item gave it.
public struct PortalService: Sendable, Equatable {
    public let title: String
    public let url: URL

    public init(title: String, url: URL) {
        self.title = title
        self.url = url
    }
}

/// `…/sharing/rest/content/items/<id>?f=json`.
struct PortalItemInfo: Decodable, Sendable {
    let title: String?
    let type: String?
    /// Set on a service item; the app and web map types carry their content in `/data`.
    let url: String?
}

/// `…/sharing/rest/content/items/<id>/data?f=json`, across the shapes that matter: a web map's
/// layers, and the several ways an app names the map it draws.
struct PortalItemData: Decodable, Sendable {
    struct Layer: Decodable, Sendable {
        let title: String?
        let url: String?
        let itemId: String?
    }
    struct MapReference: Decodable, Sendable {
        let itemId: String?
    }
    struct Values: Decodable, Sendable {
        let webmap: String?
        let map: String?
    }

    let operationalLayers: [Layer]?
    let tables: [Layer]?
    /// Web AppBuilder: `{"map": {"itemId": "…"}}`.
    let map: MapReference?
    /// Instant apps and configurable templates: `{"values": {"webmap": "…"}}`.
    let values: Values?

    /// The web map this app draws, however it names it.
    var referencedMapID: String? {
        if let id = map?.itemId, PortalURL.isItemID(id) { return id }
        if let id = values?.webmap, PortalURL.isItemID(id) { return id }
        if let id = values?.map, PortalURL.isItemID(id) { return id }
        return nil
    }

    /// Every service URL this item names directly, layers and tables alike.
    var serviceURLs: [PortalService] {
        ((operationalLayers ?? []) + (tables ?? [])).compactMap { layer in
            guard let text = layer.url, let url = URL(string: text) else { return nil }
            return PortalService(title: layer.title ?? url.lastPathComponent, url: url)
        }
    }
}

public enum PortalItemError: Error, CustomStringConvertible, Equatable {
    /// The item resolved, but named no service this app can open.
    case noServices(itemID: String, type: String?)

    public var description: String {
        switch self {
        case .noServices(let id, let type):
            let kind = type.map { " (\($0))" } ?? ""
            return "portal item \(id)\(kind) names no map or feature service"
        }
    }
}
