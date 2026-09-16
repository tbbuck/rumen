import Foundation

/// Identity of a node in the server tree and the path bar (UI-SPEC: the URL is the spine).
public enum NodeID: Hashable, Sendable {
    case server(Int64)
    case folder(serverID: Int64, path: String)
    case service(Int64)
    case layer(Int64)

    public var serverID: Int64? {
        switch self {
        case .server(let id): return id
        case .folder(let id, _): return id
        default: return nil
        }
    }
}

/// One row of the server tree, built from cached records (never from the network).
public struct TreeNode: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case server
        case folder
        case service(ServiceType)
        case layer
        case table
    }

    public let id: NodeID
    public let name: String
    public let kind: Kind
    /// Folder nesting depth for indentation: 0 for direct children of the server.
    public let folderDepth: Int
    public let layerID: Int?
    public let extent: BoundingBox?
    public let extractable: Bool?
    public let fetchedAt: Date?
    /// True when the node can have children (folders; Map/Feature services), even if none
    /// are cached yet — an uncrawled service is expandable and crawls on expand.
    public let isExpandable: Bool
    public let children: [TreeNode]

    public init(id: NodeID, name: String, kind: Kind, folderDepth: Int = 0, layerID: Int? = nil,
                extent: BoundingBox? = nil, extractable: Bool? = nil, fetchedAt: Date? = nil,
                isExpandable: Bool = false, children: [TreeNode] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.folderDepth = folderDepth
        self.layerID = layerID
        self.extent = extent
        self.extractable = extractable
        self.fetchedAt = fetchedAt
        self.isExpandable = isExpandable
        self.children = children
    }

    /// Depth-first search.
    public func find(_ id: NodeID) -> TreeNode? {
        if self.id == id { return self }
        for child in children { if let hit = child.find(id) { return hit } }
        return nil
    }
}

/// Builds the tree for one server from its cached services and layers.
public enum TreeBuilder {
    public static func build(server: ServerRecord, services: [ServiceRecord],
                             layersByService: [Int64: [LayerRecord]]) -> TreeNode {
        let children = folderChildren(serverID: server.id, path: "", depth: 0,
                                      services: services, layersByService: layersByService)
        return TreeNode(id: .server(server.id), name: server.friendlyName, kind: .server,
                        extent: BoundingBox.union(of: children.compactMap(\.extent)),
                        fetchedAt: server.lastVisitedAt, isExpandable: true, children: children)
    }

    /// The nodes directly under a folder (`""` for the root): sub-folders first, then
    /// services, both alphabetically.
    private static func folderChildren(serverID: Int64, path: String, depth: Int,
                                       services: [ServiceRecord],
                                       layersByService: [Int64: [LayerRecord]]) -> [TreeNode] {
        let prefix = path.isEmpty ? "" : path + "/"
        // Immediate sub-folder names: the next path segment of every deeper service.
        var subfolders = [String]()
        for service in services where service.folderPath != path && service.folderPath.hasPrefix(prefix) {
            let rest = service.folderPath.dropFirst(prefix.count)
            let next = String(rest.split(separator: "/", maxSplits: 1)[0])
            if !subfolders.contains(next) { subfolders.append(next) }
        }
        let folderNodes = subfolders.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.map { name -> TreeNode in
            let childPath = prefix + name
            let kids = folderChildren(serverID: serverID, path: childPath, depth: depth + 1,
                                      services: services, layersByService: layersByService)
            return TreeNode(id: .folder(serverID: serverID, path: childPath), name: name, kind: .folder,
                            folderDepth: depth, extent: BoundingBox.union(of: kids.compactMap(\.extent)),
                            isExpandable: true, children: kids)
        }
        let serviceNodes = services.filter { $0.folderPath == path }
            .sorted {
                let byName = $0.shortName.localizedCaseInsensitiveCompare($1.shortName)
                return byName == .orderedSame ? $0.type.name < $1.type.name : byName == .orderedAscending
            }
            .map { service -> TreeNode in
                let layers = (layersByService[service.id] ?? []).map { layerNode($0, depth: depth) }
                return TreeNode(id: .service(service.id), name: service.shortName, kind: .service(service.type),
                                folderDepth: depth,
                                extent: service.extentWGS84 ?? BoundingBox.union(of: layers.compactMap(\.extent)),
                                fetchedAt: service.fetchedAt, isExpandable: service.type.hasLayers, children: layers)
            }
        return folderNodes + serviceNodes
    }

    private static func layerNode(_ layer: LayerRecord, depth: Int) -> TreeNode {
        TreeNode(id: .layer(layer.id), name: layer.name, kind: layer.isTable ? .table : .layer,
                 folderDepth: depth, layerID: layer.layerID, extent: layer.extentWGS84,
                 extractable: layer.extractable, fetchedAt: layer.fetchedAt)
    }
}

/// One segment of the path bar.
public struct PathSegment: Identifiable, Sendable, Equatable {
    public let id: NodeID
    public let label: String

    public init(id: NodeID, label: String) {
        self.id = id
        self.label = label
    }
}

/// The path bar's content for a selection: host segment, folder chain, service, type, layer.
public struct PathBarContent: Sendable, Equatable {
    public let segments: [PathSegment]
    /// The mono tail, e.g. `arcgis/rest/services`.
    public let tail: String
    /// The full URL of the current node, for edit mode and copying.
    public let url: URL

    public static func build(server: ServerRecord, service: ServiceRecord? = nil, layer: LayerRecord? = nil,
                             folderPath: String? = nil) -> PathBarContent {
        var segments = [PathSegment(id: .server(server.id), label: server.friendlyName)]
        let folder = service?.folderPath.isEmpty == false ? service!.folderPath : (folderPath ?? "")
        var accumulated = ""
        for part in folder.split(separator: "/").map(String.init) {
            accumulated = accumulated.isEmpty ? part : accumulated + "/" + part
            segments.append(PathSegment(id: .folder(serverID: server.id, path: accumulated), label: part))
        }
        var url = server.rootURL
        if !folder.isEmpty { url = url.appendingPathComponent(folder) }
        if let service {
            segments.append(PathSegment(id: .service(service.id), label: service.shortName))
            segments.append(PathSegment(id: .service(service.id), label: service.type.name))
            url = service.url
            if let layer {
                segments.append(PathSegment(id: .layer(layer.id), label: "\(layer.layerID) \(layer.name)"))
                url = service.url.appendingPathComponent(String(layer.layerID))
            }
        }
        // Tail: the root path without its leading slash (e.g. "arcgis/rest/services").
        let tail = String(server.rootURL.path.drop(while: { $0 == "/" }))
        return PathBarContent(segments: segments, tail: tail, url: url)
    }
}
