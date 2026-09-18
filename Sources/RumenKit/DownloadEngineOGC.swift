import Foundation

// The engine's OGC side (M10). A WFS download is GetFeature pages staged through GDAL into
// the same per-run DuckDB the ArcGIS path uses, so resume, the chunk grid and every export
// format come for free. A WMS "download" is one GetMap picture of the layer's extent, written
// as it arrives; there is no staging and nothing to re-export.
extension DownloadEngine {

    // MARK: - Planning

    /// The plan for an OGC layer. The download is recorded against the layer the user chose
    /// (`target`); the features may come from another (`source`): the WFS twin of a WMS layer.
    func planOGC(_ request: DownloadRequest, layer target: LayerRecord, service targetService: ServiceRecord,
                 assessment: Assessment) async throws -> DownloadRecord {
        let source = assessment.sourceLayerID == target.id ? target : try await db.layer(id: assessment.sourceLayerID)
        let service = source.id == target.id ? targetService : try await db.service(id: source.serviceID)
        guard let detail = service.ogcDetail, source.ogcName != nil else {
            throw DownloadError.notExtractable("the service's capabilities have not been fetched yet")
        }
        // A picture: the WMS layer's only download when it has no features to give, and the
        // other one when it has.
        if targetService.type == .wms, request.format.isRaster {
            let plan = try await imagePlan(layer: target, service: targetService, format: request.format)
            let record = try await db.createDownload(layerID: target.id, transport: .image, strategy: .single, whereClause: "1=1",
                                                     outWkid: plan.wkid, format: request.format, domainLabels: false)
            requests[record.id] = request
            return record
        }
        guard assessment.verdict == true, let transport = assessment.transport else {
            throw DownloadError.notExtractable(assessment.reason)
        }
        guard !request.format.isRaster else { throw DownloadError.notExtractable("features cannot be written as a picture") }
        let record: DownloadRecord
        let chunks: [DownloadChunk]
        switch service.type {
        case .wfs:
            let strategy: Assessment.Strategy = detail.paging && request.manualStrategy != .single ? .offset : .single
            // WGS 84 is asked of the server only when the type is offered in it; otherwise the
            // native reference is fetched and written, and the record says which.
            let native = source.effectiveWkid ?? 4326
            let outWkid = request.outWkid == 4326 && (native == 4326 || source.ogcDetail?.wgs84CRS != nil) ? 4326 : native
            record = try await db.createDownload(layerID: target.id, transport: transport, strategy: strategy, whereClause: "1=1",
                                                 outWkid: outWkid, format: request.format, domainLabels: request.domainLabels)
            if strategy == .offset {
                // As on the ArcGIS side: the extent of the work is settled here, the chunks are
                // handed out during the run at whatever page size the server has earned.
                plannedWork[record.id] = .offset(count: try await crawler.probeCount(layerID: source.id))
                chunks = []
            } else {
                chunks = [DownloadChunk(downloadID: record.id, seq: 0, kind: .offset, offset: nil, limit: nil)]
            }
        case .wms:
            // GetMap answered in GeoJSON: one request over the extent, in the frame's CRS.
            let frame = try await frame(layer: source, service: service)
            record = try await db.createDownload(layerID: target.id, transport: .geojson, strategy: .single, whereClause: "1=1",
                                                 outWkid: frame.wkid, format: request.format, domainLabels: false)
            chunks = [DownloadChunk(downloadID: record.id, seq: 0, kind: .offset, offset: nil, limit: nil)]
        default:
            throw DownloadError.notExtractable(assessment.reason)
        }
        try await db.insertChunks(chunks)
        let staging = stagingDirectory.appendingPathComponent("download-\(record.id).duckdb").path
        try await db.setDownloadStaging(id: record.id, path: staging)
        requests[record.id] = request
        return try await db.download(id: record.id)
    }

    /// The CRS, box and pixel size of a WMS GetMap: Web Mercator when the layer offers it (no
    /// axis-order trouble, and it matches the map), else WGS 84; the longest side capped by the
    /// server's limits and 4,096 pixels.
    struct ImagePlan: Sendable {
        let crs: String
        let wkid: Int
        let minX: Double, minY: Double, maxX: Double, maxY: Double
        let width: Int, height: Int
    }

    /// The frame plus a check that the server offers the picture format asked for.
    func imagePlan(layer: LayerRecord, service: ServiceRecord, format: ExportFormat) async throws -> ImagePlan {
        guard let detail = service.ogcDetail else { throw DownloadError.notExtractable("the service's capabilities have not been fetched yet") }
        guard format.offeredMediaType(in: detail.formats) != nil else {
            throw DownloadError.notExtractable("the server does not offer \(format.label) for GetMap; it offers \(detail.formats.joined(separator: ", "))")
        }
        return try await frame(layer: layer, service: service)
    }

    /// Web Mercator when the layer offers it, else WGS 84, else the layer's own first CRS
    /// with the extent's corners carried over by the spatial engine (a British server that
    /// offers only EPSG:27700 still draws its picture).
    func frame(layer: LayerRecord, service: ServiceRecord) async throws -> ImagePlan {
        guard let detail = service.ogcDetail, let ogc = layer.ogcDetail else {
            throw DownloadError.notExtractable("the service's capabilities have not been fetched yet")
        }
        guard let box = layer.extentWGS84, !box.isDegenerate else {
            throw DownloadError.notExtractable("the layer advertises no extent to draw")
        }
        let crs: String
        let wkid: Int
        var minX = box.minX, minY = box.minY, maxX = box.maxX, maxY = box.maxY
        if let mercator = ogc.webMercatorCRS {
            crs = mercator
            wkid = 3857
            (minX, minY) = Self.webMercator(lon: box.minX, lat: box.minY)
            (maxX, maxY) = Self.webMercator(lon: box.maxX, lat: box.maxY)
        } else if let wgs = ogc.wgs84CRS ?? (ogc.crs.isEmpty ? "EPSG:4326" : nil) {
            crs = wgs
            wkid = 4326
        } else if let native = ogc.crs.first, let code = OGCURL.epsgCode(native) {
            crs = native
            wkid = code
            let corners = try await db.transform([(box.minX, box.minY), (box.maxX, box.minY), (box.maxX, box.maxY), (box.minX, box.maxY)], from: 4326, to: code)
            guard corners.count == 4, corners.allSatisfy({ $0.0.isFinite && $0.1.isFinite }) else {
                throw DownloadError.notExtractable("the layer's extent could not be carried into \(native)")
            }
            minX = corners.map(\.0).min()!; maxX = corners.map(\.0).max()!
            minY = corners.map(\.1).min()!; maxY = corners.map(\.1).max()!
        } else {
            throw DownloadError.notExtractable("the layer offers no coordinate reference this app can frame; it offers \(ogc.crs.joined(separator: ", "))")
        }
        let cap = min(detail.maxWidth ?? 4096, detail.maxHeight ?? 4096, 4096)
        let aspect = (maxX - minX) / max(1e-9, maxY - minY)
        let width = aspect >= 1 ? cap : max(1, Int((Double(cap) * aspect).rounded()))
        let height = aspect >= 1 ? max(1, Int((Double(cap) / aspect).rounded())) : cap
        return ImagePlan(crs: crs, wkid: wkid, minX: minX, minY: minY, maxX: maxX, maxY: maxY, width: width, height: height)
    }

    /// Spherical Web Mercator, enough for a picture's frame; latitudes are clamped to the projection's edge.
    public static func webMercator(lon: Double, lat: Double) -> (Double, Double) {
        let r = 6_378_137.0
        let clamped = min(85.05112878, max(-85.05112878, lat))
        let x = lon * .pi / 180 * r
        let y = log(tan(.pi / 4 + clamped * .pi / 360)) * r
        return (x, y)
    }

    // MARK: - WFS run

    private struct WFSPage: Sendable {
        let seq: Int
        let path: String
        let bytes: Int
        let error: ArcGISClientError?
        /// What the request cost, against the budget it had, for the page size to climb on.
        var elapsed: TimeInterval = 0
        var budget: TimeInterval = ArcGISClient.defaultTimeout
    }

    /// Features from an OGC service into the staging database and out to the chosen format:
    /// WFS GetFeature pages, or one WMS GetMap answered in GeoJSON. `layer` is the source (a
    /// WMS layer's WFS twin when it has one); the record belongs to the layer the user chose.
    func runOGCFeatures(_ id: Int64, record initial: DownloadRecord, layer: LayerRecord, service: ServiceRecord, server: ServerRecord,
                        progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> DownloadRecord {
        var record = initial
        guard let detail = service.ogcDetail, let typeName = layer.ogcName else {
            throw DownloadError.notExtractable("the service's capabilities have not been fetched yet")
        }
        let connection = server.connection(token: await tokenProvider(server))
        var fields = try await db.fields(layerID: layer.id)
        let outputDirectory = requests[id]?.outputDirectory ?? resumeContext[id]?.0 ?? stagingDirectory
        let overwrite = requests[id]?.overwrite ?? resumeContext[id]?.1 ?? false
        // A WFS advertises `CountDefault` the way an ArcGIS layer advertises maxRecordCount, and
        // it is just as much a claim rather than a promise — so it is the ceiling and the run
        // climbs to it. A size the user set by hand is pinned.
        var pager: AdaptiveLimit
        if let manual = requests[id]?.manualPageSize {
            pager = AdaptiveLimit(floor: manual, ceiling: manual)
        } else {
            pager = .pageSize(ceiling: detail.countDefault ?? 1000)
        }
        var chunks = try await db.chunks(downloadID: id)

        var feed = ChunkFeed(work: .offset(count: 0))
        if record.strategy == .offset {
            let planned: ChunkFeed.Work
            if let cached = plannedWork[id] {
                planned = cached
            } else {
                planned = .offset(count: try await crawler.probeCount(layerID: layer.id))
            }
            feed = ChunkFeed(work: planned, after: chunks)
        }
        let stagingPath = record.stagingPath ?? stagingDirectory.appendingPathComponent("download-\(id).duckdb").path
        let wantsGeoJSON = record.transport == .geojson
        let fileExtension = wantsGeoJSON ? "json" : "gml"
        let pageParams: @Sendable (DownloadChunk) -> [String: String]
        switch service.type {
        case .wfs:
            let format = wantsGeoJSON ? detail.geoJSONFormat : detail.gmlFormat
            let srsName = record.outWkid == 4326 && (layer.effectiveWkid ?? 4326) != 4326 ? layer.ogcDetail?.wgs84CRS : nil
            let version = detail.version
            pageParams = { chunk in
                OGCRequests.getFeature(version: version, typeName: typeName, format: format,
                                       startIndex: chunk.offset.map(Int.init), count: chunk.limit, srsName: srsName)
            }
        case .wms:
            let frame = try await frame(layer: layer, service: service)
            let vector = detail.geoJSONFormat ?? "application/json"
            let bbox = OGCRequests.getMapBBox(version: detail.version, crs: frame.crs, minX: frame.minX, minY: frame.minY, maxX: frame.maxX, maxY: frame.maxY)
            let params = OGCRequests.getMap(version: detail.version, layer: typeName, style: layer.ogcDetail?.styles.first ?? "", crs: frame.crs,
                                            bbox: bbox, width: frame.width, height: frame.height, format: vector, transparent: false)
            pageParams = { _ in params }
        default:
            throw DownloadError.notExtractable("not a service this app takes features from")
        }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: stagingPath).deletingLastPathComponent(), withIntermediateDirectories: true)
        var staging: StagingDatabase? = fields.isEmpty ? nil
            : try StagingDatabase(path: stagingPath, fields: fields, oidField: nil, hasZ: false, hasM: false)
        try await db.setDownloadStatus(id: id, status: .running)

        var done = chunks.filter { $0.status == .done }.count
        var failed = 0
        var features = chunks.filter { $0.status == .done }.reduce(Int64(0)) { $0 + ($1.count ?? 0) }
        var bytes = record.bytes ?? 0
        func report(_ status: DownloadStatus, inFlight: Int, message: String? = nil) {
            let issued = chunks.filter { $0.status != .split }.count
            progress(DownloadProgress(downloadID: id, status: status, chunksDone: done,
                                      chunksTotal: issued + feed.remainingRequests(at: pager.value),
                                      chunksInFlight: inFlight, chunksFailed: failed, features: features, bytes: bytes, message: message))
        }
        report(.running, inFlight: 0)

        var pending = chunks.filter { $0.status != .done && $0.status != .split }
        var outcome: (status: DownloadStatus, error: String?)? = nil
        var nextSeq = (chunks.map(\.seq).max() ?? -1) + 1

        do {
            try await withThrowingTaskGroup(of: WFSPage.self) { group in
                var inFlight = 0
                var attempts = Dictionary(uniqueKeysWithValues: chunks.map { ($0.seq, $0.attempts) })
                func enqueue(_ chunk: DownloadChunk) {
                    let params = pageParams(chunk)
                    let path = "\(stagingPath)-\(chunk.seq).\(fileExtension)"
                    let client = self.client
                    let root = server.rootURL
                    let seq = chunk.seq
                    let budget = ArcGISClient.timeout(forFeatures: chunk.limit)
                    group.addTask {
                        try Task.checkCancellation()
                        let started = Date()
                        do {
                            let data = try await client.fetch(root: root, params: params, server: connection, maxAttempts: Self.attemptsPerChunk)
                            try data.write(to: URL(fileURLWithPath: path))
                            return WFSPage(seq: seq, path: path, bytes: data.count, error: nil,
                                           elapsed: -started.timeIntervalSinceNow, budget: budget)
                        } catch let error as ArcGISClientError {
                            return WFSPage(seq: seq, path: path, bytes: 0, error: error)
                        } catch {
                            return WFSPage(seq: seq, path: path, bytes: 0, error: .transport(String(describing: error), url: root))
                        }
                    }
                    inFlight += 1
                }

                func refill() async throws {
                    while inFlight < concurrency {
                        if !pending.isEmpty {
                            enqueue(pending.removeFirst())
                            continue
                        }
                        guard let chunk = feed.next(downloadID: id, seq: nextSeq, size: pager.value) else { return }
                        nextSeq += 1
                        try await db.insertChunks([chunk])
                        chunks.append(chunk)
                        attempts[chunk.seq] = 0
                        enqueue(chunk)
                    }
                }
                try await refill()

                while inFlight > 0 {
                    guard let page = try await group.next() else { break }
                    inFlight -= 1
                    attempts[page.seq, default: 0] += 1
                    if let error = page.error {
                        if case .cancelled = error { throw CancellationError() }
                        if case .tokenRequired = error {
                            outcome = (.paused, error.description)
                            try await db.updateChunk(downloadID: id, seq: page.seq, status: .pending, count: nil, attempts: attempts[page.seq] ?? 1, error: error.description)
                            group.cancelAll()
                            throw error
                        }
                        // Only a refusal about size is answered by asking for less; see the
                        // ArcGIS engine for why halving over anything else is just more load.
                        if error.isPushback, let index = chunks.firstIndex(where: { $0.seq == page.seq }),
                           let halves = DownloadPlanner.split(chunks[index], pageSize: pager.value, firstSeq: nextSeq) {
                            nextSeq += 2
                            pager.pushedBack()
                            try await db.updateChunk(downloadID: id, seq: page.seq, status: .split, count: nil, attempts: attempts[page.seq] ?? 1,
                                                     error: "split into \(halves[0].seq + 1) and \(halves[1].seq + 1): \(error.description)")
                            try await db.insertChunks(halves)
                            chunks[index].status = .split
                            chunks.append(contentsOf: halves)
                            pending.append(contentsOf: halves)
                            report(.running, inFlight: inFlight,
                                   message: "request \(page.seq + 1) refused, split in two; asking for \(pager.value.formatted()) at a time")
                            try await refill()
                            continue
                        }
                        outcome = (.failed, DownloadError.chunkFailed(seq: page.seq, message: error.description).description)
                        try await db.updateChunk(downloadID: id, seq: page.seq, status: .failed, count: nil, attempts: attempts[page.seq] ?? 1, error: error.description)
                        group.cancelAll()
                        throw error
                    }
                    // The schema the server would not describe is taken from the first page.
                    if staging == nil {
                        let derived = try StagingDatabase.describeFields(file: page.path)
                        try await db.setOGCFields(layerID: layer.id, fields: derived)
                        fields = try await db.fields(layerID: layer.id)
                        staging = try StagingDatabase(path: stagingPath, fields: fields, oidField: nil, hasZ: false, hasM: false)
                    }
                    guard let staging else { continue }
                    try staging.clearChunk(page.seq)
                    let appended = try staging.ingest(file: page.path, chunk: page.seq)
                    try? FileManager.default.removeItem(atPath: page.path)
                    try await db.updateChunk(downloadID: id, seq: page.seq, status: .done, count: Int64(appended), attempts: attempts[page.seq] ?? 1, error: nil)
                    if let index = chunks.firstIndex(where: { $0.seq == page.seq }) { chunks[index].status = .done }
                    done += 1
                    features += Int64(appended)
                    bytes += Int64(page.bytes)
                    pager.succeeded(AdaptiveLimit.Sample(work: Double(appended), elapsed: page.elapsed, budget: page.budget))
                    report(.running, inFlight: inFlight)
                    try await refill()
                }
            }
        } catch is CancellationError {
            let db = self.db
            record = try await persist {
                try await db.setDownloadStatus(id: id, status: .cancelled, error: nil)
                return try await db.download(id: id)
            }
            report(.cancelled, inFlight: 0)
            return record
        } catch {
            let status = outcome?.status ?? .failed
            let message = outcome?.error ?? String(describing: error)
            failed += 1
            let db = self.db
            record = try await persist {
                try await db.setDownloadStatus(id: id, status: status, error: message)
                return try await db.download(id: id)
            }
            report(status, inFlight: 0, message: message)
            return record
        }

        guard let staging else {
            throw DownloadError.notExtractable("no page arrived to take the schema from")
        }
        do {
            // The file is named for the layer the user chose, under its own service.
            let target = try await db.layer(id: record.layerID)
            let targetService = try await db.service(id: target.serviceID)
            let outputURL = Exporter.outputPath(directory: outputDirectory, server: server, service: targetService, layer: target, format: record.format)
            let result = try Exporter.export(staging, to: outputURL, format: record.format, outWkid: record.outWkid,
                                             domainLabels: record.domainLabels, overwrite: overwrite)
            let db = self.db
            let totalBytes = bytes
            record = try await persist {
                try await db.setDownloadOutput(id: id, path: result.path, sha256: result.sha256, featureCount: result.featureCount,
                                               invalidGeometries: result.invalidGeometries, bytes: totalBytes)
                return try await db.download(id: id)
            }
            try? FileManager.default.removeItem(atPath: stagingPath)
            try? FileManager.default.removeItem(atPath: stagingPath + ".wal")
            features = result.featureCount
            report(.complete, inFlight: 0)
            return record
        } catch {
            let message = String(describing: error)
            let db = self.db
            record = try await persist {
                try await db.setDownloadStatus(id: id, status: .failed, error: message)
                return try await db.download(id: id)
            }
            report(.failed, inFlight: 0, message: message)
            return record
        }
    }

    // MARK: - WMS picture

    func runImage(_ id: Int64, record initial: DownloadRecord, layer: LayerRecord, service: ServiceRecord, server: ServerRecord,
                  progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> DownloadRecord {
        var record = initial
        guard let detail = service.ogcDetail, let ogc = layer.ogcDetail, let name = layer.ogcName,
              let media = record.format.mediaType else {
            throw DownloadError.notExtractable("the service's capabilities have not been fetched yet")
        }
        let plan = try await imagePlan(layer: layer, service: service, format: record.format)
        let connection = server.connection(token: await tokenProvider(server))
        let outputDirectory = requests[id]?.outputDirectory ?? resumeContext[id]?.0 ?? stagingDirectory
        let overwrite = requests[id]?.overwrite ?? resumeContext[id]?.1 ?? false
        var bytes: Int64 = 0
        func report(_ status: DownloadStatus, message: String? = nil) {
            progress(DownloadProgress(downloadID: id, status: status, chunksDone: status == .complete ? 1 : 0, chunksTotal: 1,
                                      chunksInFlight: status == .running ? 1 : 0, chunksFailed: status == .failed ? 1 : 0,
                                      features: 0, bytes: bytes, message: message))
        }
        try await db.setDownloadStatus(id: id, status: .running)
        report(.running)
        do {
            let bbox = OGCRequests.getMapBBox(version: detail.version, crs: plan.crs, minX: plan.minX, minY: plan.minY, maxX: plan.maxX, maxY: plan.maxY)
            let params = OGCRequests.getMap(version: detail.version, layer: name, style: ogc.styles.first ?? "", crs: plan.crs, bbox: bbox,
                                            width: plan.width, height: plan.height, format: media, transparent: record.format == .png)
            let data = try await client.fetch(root: server.rootURL, params: params, server: connection) { transfer in
                progress(DownloadProgress(downloadID: id, status: .running, chunksDone: 0, chunksTotal: 1, chunksInFlight: 1, chunksFailed: 0,
                                          features: 0, bytes: transfer.received, message: nil))
            }
            guard !ArcGISClient.looksLikeXML(data) else {
                throw ArcGISClientError.decoding("the server answered a GetMap with XML instead of an image", url: server.rootURL)
            }
            bytes = Int64(data.count)
            let output = Exporter.outputPath(directory: outputDirectory, server: server, service: service, layer: layer, format: record.format)
            try Exporter.prepare(output, overwrite: overwrite)
            try data.write(to: output)
            if record.format == .png {
                try Self.worldFile(for: plan).write(to: output.deletingPathExtension().appendingPathExtension("pgw"), atomically: true, encoding: .utf8)
            }
            let (hash, size) = try Exporter.hashFile(at: output)
            let db = self.db
            record = try await persist {
                try await db.setDownloadOutput(id: id, path: output.path, sha256: hash, featureCount: 0, invalidGeometries: 0, bytes: size)
                return try await db.download(id: id)
            }
            report(.complete)
            return record
        } catch is CancellationError {
            let db = self.db
            record = try await persist {
                try await db.setDownloadStatus(id: id, status: .cancelled, error: nil)
                return try await db.download(id: id)
            }
            report(.cancelled)
            return record
        } catch {
            let message = String(describing: error)
            let db = self.db
            record = try await persist {
                try await db.setDownloadStatus(id: id, status: .failed, error: message)
                return try await db.download(id: id)
            }
            report(.failed, message: message)
            return record
        }
    }

    /// An ESRI world file: pixel size, no rotation, and the centre of the top-left pixel.
    static func worldFile(for plan: ImagePlan) -> String {
        let px = (plan.maxX - plan.minX) / Double(plan.width)
        let py = (plan.maxY - plan.minY) / Double(plan.height)
        func f(_ v: Double) -> String { String(format: "%.10f", v) }
        return [f(px), "0.0", "0.0", f(-py), f(plan.minX + px / 2), f(plan.maxY - py / 2)].joined(separator: "\n") + "\n"
    }
}
