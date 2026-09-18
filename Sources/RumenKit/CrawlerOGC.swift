import Foundation

// The crawler's OGC side (M10). An OGC endpoint has no directory to walk: it is probed for
// WMS, WFS and WMTS capabilities, each answer becoming a service with its layers, and a WFS's
// feature types are described in one further request. Everything is cached exactly as ArcGIS
// metadata is, so the tree, the pages and the transfers need no second code path.
extension Crawler {

    /// Opens a pasted OGC URL: registers the endpoint (probing it for a new server) and lands
    /// on the service or layer the URL's parameters named. A new endpoint that answers none of
    /// the three services is forgotten again, and the attempts are reported verbatim.
    func openOGC(_ text: String, friendlyName: String?, headerOverrides: (origin: String?, referer: String?)?,
                 cookie: String?, progress: (@Sendable (CrawlEvent) -> Void)?) async throws -> Opened {
        let location = try OGCURL.parse(text)
        let existing = try await db.server(rootURL: location.rootURL)
        var server = try await db.addServer(rootURL: location.rootURL,
                                            friendlyName: friendlyName ?? location.rootURL.host ?? "server", kind: .ogc)
        let isNew = existing == nil
        if isNew {
            if let headerOverrides {
                try await db.setHeaderOverrides(serverID: server.id, origin: headerOverrides.origin, referer: headerOverrides.referer)
            }
            if let cookie, !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await db.setCookie(serverID: server.id, cookie: cookie)
            }
            server = try await db.server(id: server.id)
        }
        var problems = [CrawlProblem]()
        let cached = try await db.services(serverID: server.id)
        if isNew || cached.isEmpty {
            do {
                problems = try await probeOGC(serverID: server.id, location: location, progress: progress)
            } catch {
                if isNew { try? await db.forgetServer(id: server.id) }
                throw error
            }
        }
        let services = try await db.services(serverID: server.id)
        var service: ServiceRecord?
        var layer: LayerRecord?
        if let hint = location.serviceHint { service = services.first { $0.type == hint } }
        if let name = location.layerName {
            if let service { layer = try await db.layer(serviceID: service.id, ogcName: name) }
            else {
                for candidate in services {
                    if let found = try await db.layer(serviceID: candidate.id, ogcName: name) { service = candidate; layer = found; break }
                }
            }
        }
        var opened = Opened(server: try await db.server(id: server.id), location: ArcGISLocation(rootURL: location.rootURL),
                            service: service, layer: layer, isNewServer: isNew)
        opened.problems = problems
        return opened
    }

    /// Asks the endpoint for WMS, WFS and WMTS capabilities in turn (the hinted one first),
    /// recording each service that answers with its layers, and describing a WFS's feature
    /// types. A service type the endpoint does not offer is simply absent; only a WFS whose
    /// schema could not be read comes back as a problem, so the page can say so and offer a
    /// retry. Throws when none of the three answered, naming what each said.
    @discardableResult
    public func probeOGC(serverID: Int64, location: OGCLocation? = nil,
                         progress: (@Sendable (CrawlEvent) -> Void)? = nil) async throws -> [CrawlProblem] {
        let server = try await db.server(id: serverID)
        let connection = await connection(server)
        var order: [ServiceType] = [.wfs, .wms, .wmts]
        if let hint = location?.serviceHint { order = [hint] + order.filter { $0 != hint } }
        var found = [ServiceType]()
        var attempts = [String]()
        var problems = [CrawlProblem]()
        for type in order {
            try Task.checkCancellation()
            do {
                let document = try await fetchCapabilities(type: type, server: server, connection: connection, location: location)
                let service = try await db.upsertOGCService(serverID: serverID, rootURL: server.rootURL, document: document)
                let layers = try await db.upsertOGCLayers(serviceID: service.id, document: document)
                progress?(.service(name: service.name, layers: layers.count))
                found.append(type)
                if type == .wfs {
                    do {
                        try await describeFeatureTypes(service: service, layers: layers, server: server, connection: connection, progress: progress)
                    } catch {
                        if error is CancellationError { throw error }
                        problems.append(CrawlProblem(folderPath: "WFS DescribeFeatureType", message: String(describing: error)))
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ArcGISClientError where error == .cancelled {
                throw CancellationError()
            } catch {
                let message = String(describing: error)
                attempts.append("\(type.name): \(message)")
                progress?(.failed(what: type.name, error: message))
            }
        }
        guard !found.isEmpty else {
            throw OGCError.noServices(url: server.rootURL, attempts: attempts)
        }
        // A type that answered before and no longer does is dropped; the cache is not kept for
        // a service that has gone. (A whole outage throws above and keeps everything.)
        for service in try await db.services(serverID: serverID) where service.type.isOGC && !found.contains(service.type) {
            try await db.deleteService(id: service.id)
        }
        try await db.setServerVersion(id: serverID, version: nil)
        return problems
    }

    /// Re-reads one OGC service's capabilities (and a WFS's schemas): the service page's
    /// refresh and the tree's expand.
    public func crawlOGCService(serviceID: Int64, progress: (@Sendable (CrawlEvent) -> Void)? = nil) async throws {
        let service = try await db.service(id: serviceID)
        let server = try await db.server(id: service.serverID)
        let connection = await connection(server)
        let document = try await fetchCapabilities(type: service.type, server: server, connection: connection, location: nil)
        let updated = try await db.upsertOGCService(serverID: server.id, rootURL: server.rootURL, document: document)
        let layers = try await db.upsertOGCLayers(serviceID: updated.id, document: document)
        progress?(.service(name: updated.name, layers: layers.count))
        if service.type == .wfs {
            try await describeFeatureTypes(service: updated, layers: layers, server: server, connection: connection, progress: progress)
        }
    }

    func fetchCapabilities(type: ServiceType, server: ServerRecord, connection: ServerConnection,
                           location: OGCLocation?) async throws -> OGCCapabilitiesDocument {
        let (root, params) = OGCRequests.capabilities(root: server.rootURL, type: type, location: location)
        let data = try await client.fetch(root: root, params: params, server: connection, maxAttempts: 2)
        return try OGCCapabilities.parse(data, expecting: type, url: OGCURL.url(root: root, params: params))
    }

    /// One DescribeFeatureType for every type at once; when the server refuses the all-types
    /// form, one per type. Fields land in the `field` table and the geometry type on the layer.
    func describeFeatureTypes(service: ServiceRecord, layers: [LayerRecord], server: ServerRecord,
                              connection: ServerConnection, progress: (@Sendable (CrawlEvent) -> Void)?) async throws {
        guard let detail = service.ogcDetail, !layers.isEmpty else { return }
        func local(_ name: String?) -> String { name.map { $0.split(separator: ":").last.map(String.init) ?? $0 } ?? "" }
        func apply(_ types: [OGCFeatureType], to layers: [LayerRecord]) async throws -> Int {
            var applied = 0
            for layer in layers {
                guard let match = types.first(where: { $0.name == local(layer.ogcName) }) else { continue }
                try await db.setOGCFields(layerID: layer.id, fields: match.fields)
                progress?(.layer(name: layer.name))
                applied += 1
            }
            return applied
        }
        do {
            let params = OGCRequests.describeFeatureType(version: detail.version)
            let data = try await client.fetch(root: server.rootURL, params: params, server: connection, maxAttempts: 2)
            let types = try OGCCapabilities.parseFeatureTypes(data, url: OGCURL.url(root: server.rootURL, params: params))
            if try await apply(types, to: layers) > 0 || types.isEmpty { return }
        } catch {
            if error is CancellationError { throw error }
            if let client = error as? ArcGISClientError, client == .cancelled { throw error }
            // Fall through to one request per type.
        }
        var failures = [String]()
        for layer in layers {
            guard let name = layer.ogcName else { continue }
            try Task.checkCancellation()
            do {
                let params = OGCRequests.describeFeatureType(version: detail.version, typeName: name)
                let data = try await client.fetch(root: server.rootURL, params: params, server: connection, maxAttempts: 2)
                let types = try OGCCapabilities.parseFeatureTypes(data, url: OGCURL.url(root: server.rootURL, params: params))
                if try await apply(types, to: [layer]) == 0, let only = types.first {
                    try await db.setOGCFields(layerID: layer.id, fields: only.fields)   // one type asked, one described
                }
            } catch {
                if error is CancellationError { throw error }
                failures.append("\(name): \(error)")
            }
        }
        if !failures.isEmpty {
            throw OGCError.exception("DescribeFeatureType failed for " + failures.joined(separator: "; "), url: server.rootURL)
        }
    }

    /// The WFS feature type with a WMS layer's name at the same endpoint: the features behind
    /// the picture, as a FeatureServer twin is to a MapServer layer. Names are matched by their
    /// local part, so the WMS `towns` finds the WFS `ms:towns`.
    public func ogcTwin(of layer: LayerRecord, in service: ServiceRecord) async throws -> (LayerRecord, ServiceRecord)? {
        guard service.type == .wms, let name = layer.ogcName else { return nil }
        guard let wfs = try await db.services(serverID: service.serverID).first(where: { $0.type == .wfs }) else { return nil }
        guard let twin = try await db.layer(serviceID: wfs.id, ogcName: name) else { return nil }
        return (twin, wfs)
    }

    /// `resultType=hits`: the feature count of a WFS type without the features (WFS 1.1 and 2.0).
    func probeOGCCount(layer: LayerRecord, service: ServiceRecord, server: ServerRecord) async throws -> Int64 {
        guard service.type == .wfs, let detail = service.ogcDetail, let name = layer.ogcName else {
            throw OGCError.notAFeatureType(layer.name)
        }
        guard !detail.version.hasPrefix("1.0") else {
            throw OGCError.exception("WFS 1.0.0 cannot count features; a download finds out as it goes", url: server.rootURL)
        }
        let params = OGCRequests.getFeature(version: detail.version, typeName: name, format: nil, startIndex: nil, count: nil, hits: true)
        let data = try await client.fetch(root: server.rootURL, params: params, server: await connection(server))
        guard let count = try OGCCapabilities.parseHits(data, url: OGCURL.url(root: server.rootURL, params: params)) else {
            throw OGCError.exception("the server answered resultType=hits without a count", url: server.rootURL)
        }
        try await db.setFeatureCount(layerID: layer.id, count: count)
        return count
    }
}
