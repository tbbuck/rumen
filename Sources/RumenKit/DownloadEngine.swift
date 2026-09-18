import Foundation

public enum DownloadError: Error, CustomStringConvertible, Equatable {
    case notExtractable(String)
    case unknownStrategy
    case tooManyObjectIDs(Int)
    case shortPageWithMore(seq: Int, got: Int, expected: Int)
    case truncatedChunk(seq: Int)
    case chunkFailed(seq: Int, message: String)
    case alreadyRunning(Int64)
    case notResumable(Int64)

    public var description: String {
        switch self {
        case .notExtractable(let r): return "not extractable: \(r)"
        case .unknownStrategy: return "no download strategy could be chosen; set one manually"
        case .tooManyObjectIDs(let n): return "the layer has \(n.formatted()) object ids, above the \(DownloadPlanner.objectIDListCap.formatted()) cap; supply a partitioning where clause"
        case .shortPageWithMore(let seq, let got, let expected): return "request \(seq + 1) returned \(got) of \(expected) features yet said more remain"
        case .truncatedChunk(let seq): return "request \(seq + 1) was truncated by the server; the chunking assumption failed"
        case .chunkFailed(let seq, let message): return "request \(seq + 1) failed: \(message)"
        case .alreadyRunning(let id): return "download \(id) is already running"
        case .notResumable(let id): return "download \(id) is not in a resumable state"
        }
    }
}

/// A snapshot of a run for the transfers UI.
public struct DownloadProgress: Sendable, Equatable {
    public let downloadID: Int64
    public let status: DownloadStatus
    public let chunksDone: Int
    public let chunksTotal: Int
    public let chunksInFlight: Int
    public let chunksFailed: Int
    public let features: Int64
    public let bytes: Int64
    public let message: String?
}

/// Plans and runs downloads (SPEC §5.6): probes, picks chunks, fetches them in parallel with
/// bounded concurrency, stages rows in a per-run DuckDB, records every chunk so a run can
/// resume, and exports at the end.
public actor DownloadEngine {
    let client: ArcGISClient
    let db: AppDatabase
    let crawler: Crawler
    let stagingDirectory: URL
    var concurrency: Int
    let tokenProvider: @Sendable (ServerRecord) async -> String?
    private var tasks: [Int64: Task<DownloadRecord, Error>] = [:]

    public init(client: ArcGISClient, database: AppDatabase, crawler: Crawler, stagingDirectory: URL,
                concurrency: Int = 4, tokenProvider: @escaping @Sendable (ServerRecord) async -> String? = { _ in nil }) {
        self.client = client
        self.db = database
        self.crawler = crawler
        self.stagingDirectory = stagingDirectory
        self.concurrency = max(1, concurrency)
        self.tokenProvider = tokenProvider
    }

    public var runningIDs: [Int64] { Array(tasks.keys) }

    /// Chunks fetched in parallel per run, for runs started from now on (M9 preferences); the
    /// client's per-host cap still bounds the aggregate.
    public func setConcurrency(_ value: Int) { concurrency = max(1, value) }

    // MARK: - Public API

    /// Plans a download (probing the server as the strategy requires) and starts it. Returns
    /// the planned record; `wait` or the progress callback follow the run.
    public func start(_ request: DownloadRequest, progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }) async throws -> DownloadRecord {
        let record = try await plan(request)
        launch(record.id, progress: progress)
        return try await db.download(id: record.id)
    }

    /// Picks an unfinished run back up: fetches its pending and failed chunks, then exports.
    public func resume(downloadID: Int64, overwrite: Bool = false, outputDirectory: URL,
                       progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }) async throws -> DownloadRecord {
        let record = try await db.download(id: downloadID)
        guard tasks[downloadID] == nil else { throw DownloadError.alreadyRunning(downloadID) }
        guard record.status.isResumable else { throw DownloadError.notResumable(downloadID) }
        resumeContext[downloadID] = (outputDirectory, overwrite)
        launch(downloadID, progress: progress)
        return record
    }

    public func cancel(downloadID: Int64) {
        tasks[downloadID]?.cancel()
    }

    /// Awaits the run's end and returns its final record.
    public func wait(downloadID: Int64) async throws -> DownloadRecord {
        guard let task = tasks[downloadID] else { return try await db.download(id: downloadID) }
        return try await task.value
    }

    // MARK: - Planning

    var requests: [Int64: DownloadRequest] = [:]
    var resumeContext: [Int64: (URL, Bool)] = [:]
    /// What each planned run has to fetch, so the run does not ask the server again.
    var plannedWork: [Int64: ChunkFeed.Work] = [:]

    private func plan(_ request: DownloadRequest) async throws -> DownloadRecord {
        let assessment = try await crawler.assess(layerID: request.layerID)
        let target = try await db.layer(id: request.layerID)
        let targetService = try await db.service(id: target.serviceID)
        if targetService.type.isOGC {
            return try await planOGC(request, layer: target, service: targetService, assessment: assessment)
        }
        guard assessment.verdict == true else { throw DownloadError.notExtractable(assessment.reason) }
        let strategy = request.manualStrategy ?? assessment.strategy
        guard let strategy, let transport = assessment.transport else { throw DownloadError.unknownStrategy }
        let pageSize = request.manualPageSize ?? assessment.pageSize ?? 1000

        let source = try await db.layer(id: assessment.sourceLayerID)
        let service = try await db.service(id: source.serviceID)
        let server = try await db.server(id: service.serverID)
        let connection = server.connection(token: await tokenProvider(server))
        let url = service.url.appendingPathComponent(String(source.layerID))
        let oidField = source.objectIdField ?? "OBJECTID"

        let record = try await db.createDownload(layerID: request.layerID, transport: transport, strategy: strategy,
                                                 whereClause: request.whereClause, outWkid: request.outWkid,
                                                 format: request.format, domainLabels: request.domainLabels)
        // The chunks themselves are not laid out here any more: the run hands them out against a
        // page size that moves (see `ChunkFeed`). All that is settled up front is the extent of
        // the work, and the probe that settles it is the one the verdict already needed.
        if strategy == .single {
            try await db.insertChunks([DownloadChunk(downloadID: record.id, seq: 0, kind: .offset, offset: 0, limit: nil)])
        } else {
            plannedWork[record.id] = try await work(strategy: strategy, downloadID: record.id, layerID: request.layerID,
                                                    connection: connection, url: url, oidField: oidField,
                                                    whereClause: request.whereClause)
        }
        _ = pageSize
        let staging = stagingDirectory.appendingPathComponent("download-\(record.id).duckdb").path
        try await db.setDownloadStaging(id: record.id, path: staging)
        requests[record.id] = request
        return try await db.download(id: record.id)
    }

    /// The whole of what a download has to fetch. Computed when the run is planned and kept for
    /// the run that follows; a resume in a later process asks the server again, which is the
    /// same question the plan asked and no more expensive.
    private func work(strategy: Assessment.Strategy, downloadID: Int64, layerID: Int64, connection: ServerConnection,
                      url: URL, oidField: String, whereClause: String) async throws -> ChunkFeed.Work {
        switch strategy {
        case .offset, .single:
            let count = try await client.count(connection, layerURL: url, where: whereClause)
            try await db.setFeatureCount(layerID: layerID, count: Int64(count))
            return .offset(count: Int64(count))
        case .oidRange:
            let stats = try await client.features(connection, layerURL: url, options: QueryOptions(
                whereClause: whereClause,
                statistics: [StatisticDefinition(.min, field: oidField, outName: "min_oid"),
                             StatisticDefinition(.max, field: oidField, outName: "max_oid")])).value
            let attributes = stats.features.first?.attributes ?? [:]
            let lo = AttributeValue(attributes["min_oid"]).int64 ?? 0
            let hi = AttributeValue(attributes["max_oid"]).int64 ?? -1
            return .oidRange(min: lo, max: hi)
        case .oidList:
            let ids = try await client.objectIDs(connection, layerURL: url, where: whereClause)
            guard ids.count <= DownloadPlanner.objectIDListCap else {
                try await db.setDownloadStatus(id: downloadID, status: .failed,
                                               error: DownloadError.tooManyObjectIDs(ids.count).description)
                throw DownloadError.tooManyObjectIDs(ids.count)
            }
            return .oidList(ids.sorted())
        }
    }

    // MARK: - Running

    private func launch(_ id: Int64, progress: @escaping @Sendable (DownloadProgress) -> Void) {
        let task = Task<DownloadRecord, Error> { [self] in
            defer { Task { self.finished(id) } }
            return try await self.run(id, progress: progress)
        }
        tasks[id] = task
    }

    /// Runs a persistence step outside the (possibly cancelled) run task.
    func persist<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await Task { try await body() }.value
    }

    private func finished(_ id: Int64) {
        tasks[id] = nil
        requests[id] = nil
        resumeContext[id] = nil
        plannedWork[id] = nil
    }

    private struct FetchedChunk: Sendable {
        let seq: Int
        let page: FeaturePage
        let bytes: Int
        let usedJSON: Bool
    }

    private enum ChunkOutcome: Sendable {
        case fetched(FetchedChunk)
        case failed(seq: Int, error: ArcGISClientError)
    }

    /// Engine requests retry less than the interactive client: a refused chunk is split instead.
    static let attemptsPerChunk = 2

    private func run(_ id: Int64, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> DownloadRecord {
        var record = try await db.download(id: id)
        let target = try await db.layer(id: record.layerID)
        // Features may come from a twin (a FeatureServer's, a WFS's); a picture is always the layer's own.
        let sourceID = record.transport == .image ? target.id : (target.siblingLayerID ?? target.id)
        let source = try await db.layer(id: sourceID)
        let service = try await db.service(id: source.serviceID)
        let server = try await db.server(id: service.serverID)
        if service.type == .wms, record.transport == .image {
            return try await runImage(id, record: record, layer: source, service: service, server: server, progress: progress)
        }
        if service.type.isOGC {   // WFS pages, or a WMS GetMap answered in GeoJSON
            return try await runOGCFeatures(id, record: record, layer: source, service: service, server: server, progress: progress)
        }
        let connection = server.connection(token: await tokenProvider(server))
        let url = service.url.appendingPathComponent(String(source.layerID))
        let fields = try await db.fields(layerID: source.id)
        let oidField = source.objectIdField ?? "OBJECTID"
        let outputDirectory = requests[id]?.outputDirectory ?? resumeContext[id]?.0 ?? stagingDirectory
        let overwrite = requests[id]?.overwrite ?? resumeContext[id]?.1 ?? false

        var chunks = try await db.chunks(downloadID: id)

        // How many features to ask for at a time. The server's `maxRecordCount` is the ceiling,
        // not the opening bid: it is what the server claims on a good day, and believing it on a
        // struggling one costs a timeout per chunk before anything adapts. A size the user set
        // by hand is pinned, floor and ceiling alike, because they meant it.
        var pager: AdaptiveLimit
        if let manual = requests[id]?.manualPageSize {
            pager = AdaptiveLimit(floor: manual, ceiling: manual)
        } else {
            pager = .pageSize(ceiling: source.maxRecordCount ?? 1000)
        }
        let pageSize = pager.value

        // Chunks are handed out as they are needed so the size above can change between them.
        // `.single` had its one chunk recorded when the run was planned and needs no feed.
        var feed = ChunkFeed(work: .offset(count: 0))
        if record.strategy != .single {
            let planned: ChunkFeed.Work
            if let cached = plannedWork[id] {
                planned = cached
            } else {
                planned = try await work(strategy: record.strategy, downloadID: id, layerID: source.id,
                                         connection: connection, url: url, oidField: oidField,
                                         whereClause: record.whereClause)
            }
            feed = ChunkFeed(work: planned, after: chunks)
        }
        let stagingPath = record.stagingPath ?? stagingDirectory.appendingPathComponent("download-\(id).duckdb").path
        let staging = try StagingDatabase(path: stagingPath, fields: fields, oidField: source.objectIdField,
                                          hasZ: source.hasZ ?? false, hasM: source.hasM ?? false)
        try await db.setDownloadStatus(id: id, status: .running)

        var done = chunks.filter { $0.status == .done }.count
        var failed = 0
        var features = chunks.filter { $0.status == .done }.reduce(Int64(0)) { $0 + ($1.count ?? 0) }
        var bytes = record.bytes ?? 0
        let whereClause = record.whereClause
        let outWkid = record.outWkid
        let startedAsJSON = record.transport == .json
        // The request count is not known while the page size is still moving, so the total is
        // what has been handed out plus an estimate of what is left at the size in force. It
        // firms up within a few requests, as the size settles.
        func report(_ status: DownloadStatus, inFlight: Int, message: String? = nil) {
            let issued = chunks.filter { $0.status != .split }.count
            progress(DownloadProgress(downloadID: id, status: status, chunksDone: done,
                                      chunksTotal: issued + feed.remainingRequests(at: pager.value),
                                      chunksInFlight: inFlight, chunksFailed: failed, features: features, bytes: bytes, message: message))
        }
        report(.running, inFlight: 0)

        var pending = chunks.filter { $0.status != .done && $0.status != .split }
        var outcome: (status: DownloadStatus, error: String?)? = nil
        /// Tracked rather than recomputed: an OID-list run can carry tens of thousands of chunks,
        /// and scanning them all for the highest sequence on every one is quadratic.
        var nextSeq = (chunks.map(\.seq).max() ?? -1) + 1

        do {
            let switchedToJSON: Bool = try await withThrowingTaskGroup(of: ChunkOutcome.self) { group in
                var useJSON = startedAsJSON
                var inFlight = 0
                var attempts = Dictionary(uniqueKeysWithValues: chunks.map { ($0.seq, $0.attempts) })
                func enqueue(_ chunk: DownloadChunk) {
                    let options = DownloadPlanner.options(for: chunk, whereClause: whereClause, outWkid: outWkid,
                                                          oidField: oidField, pageSize: pageSize, canOrderBy: source.supportsOrderBy ?? false)
                    let json = useJSON
                    let hasZ = source.hasZ, hasM = source.hasM
                    let client = self.client
                    let attempts = Self.attemptsPerChunk
                    group.addTask {
                        try Task.checkCancellation()
                        do {
                            if !json {
                                do {
                                    let data = try await client.featuresPBF(connection, layerURL: url, options: options, maxAttempts: attempts)
                                    return .fetched(FetchedChunk(seq: chunk.seq, page: try PBFDecoder.decode(data), bytes: data.count, usedJSON: false))
                                } catch is PBFError {
                                    // Fall through to JSON for this chunk; the run switches transport below.
                                } catch ArcGISClientError.server(let code, _, _, _) where code != 498 && code != 499 {
                                    // The server refused the PBF request itself; JSON may still work.
                                }
                            }
                            let (set, raw) = try await client.features(connection, layerURL: url, options: options, maxAttempts: attempts)
                            return .fetched(FetchedChunk(seq: chunk.seq, page: FeaturePage(json: set, hasZ: hasZ, hasM: hasM), bytes: raw.count, usedJSON: true))
                        } catch let error as ArcGISClientError {
                            return .failed(seq: chunk.seq, error: error)
                        }
                    }
                    inFlight += 1
                }

                /// Fills the in-flight slots from the chunks already waiting, then from the feed
                /// at whatever page size the server has earned by now. A chunk is recorded before
                /// it is issued, so a crash leaves it pending rather than losing its range.
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
                    guard let next = try await group.next() else { break }
                    inFlight -= 1
                    let fetched: FetchedChunk
                    switch next {
                    case .failed(let seq, let error):
                        if case .cancelled = error { throw CancellationError() }
                        attempts[seq, default: 0] += 1
                        if case .tokenRequired = error {
                            outcome = (.paused, error.description)
                            try await db.updateChunk(downloadID: id, seq: seq, status: .pending, count: nil, attempts: attempts[seq] ?? 1, error: error.description)
                            group.cancelAll()
                            throw error
                        }
                        // Splitting is the answer to "that was too much to ask for", and only to
                        // that. A 404, a bad where clause or a broken service says nothing about
                        // size, and halving chunks down to the floor over it only multiplies the
                        // requests a struggling server has to refuse.
                        if error.isPushback, let index = chunks.firstIndex(where: { $0.seq == seq }),
                           let halves = DownloadPlanner.split(chunks[index], pageSize: pager.value, firstSeq: nextSeq) {
                            nextSeq += 2
                            // Every chunk still to come shrinks too. Without this each one pays
                            // the same timeout to learn the same lesson.
                            pager.pushedBack()
                            try await db.updateChunk(downloadID: id, seq: seq, status: .split, count: nil, attempts: attempts[seq] ?? 1,
                                                     error: "split into \(halves[0].seq + 1) and \(halves[1].seq + 1): \(error.description)")
                            try await db.insertChunks(halves)
                            chunks[index].status = .split
                            chunks.append(contentsOf: halves)
                            pending.append(contentsOf: halves)
                            report(.running, inFlight: inFlight,
                                   message: "request \(seq + 1) refused, split in two; asking for \(pager.value.formatted()) at a time")
                            try await refill()
                            continue
                        }
                        outcome = (.failed, DownloadError.chunkFailed(seq: seq, message: error.description).description)
                        try await db.updateChunk(downloadID: id, seq: seq, status: .failed, count: nil, attempts: attempts[seq] ?? 1, error: error.description)
                        group.cancelAll()
                        throw error
                    case .fetched(let f):
                        fetched = f
                    }
                    if fetched.usedJSON, !useJSON { useJSON = true }   // PBF failed once: JSON for the rest of the run
                    let seq = fetched.seq
                    attempts[seq, default: 0] += 1
                    guard let index = chunks.firstIndex(where: { $0.seq == seq }) else { continue }
                    let chunk = chunks[index]
                    let page = fetched.page
                    // Validate the chunk against its plan.
                    switch chunk.kind {
                    case .offset:
                        let expected = chunk.limit ?? pageSize
                        if page.exceededTransferLimit, page.features.count < expected {
                            outcome = (.failed, DownloadError.shortPageWithMore(seq: seq, got: page.features.count, expected: expected).description)
                            try await db.updateChunk(downloadID: id, seq: seq, status: .failed, count: Int64(page.features.count),
                                                     attempts: attempts[seq] ?? 1, error: outcome?.error)
                            group.cancelAll()
                            throw DownloadError.shortPageWithMore(seq: seq, got: page.features.count, expected: expected)
                        }
                        if page.exceededTransferLimit, feed.isExhausted, seq == nextSeq - 1 {
                            // The count was stale or the server lied: extend the plan by one page
                            // beyond what the feed thought was the end.
                            let extra = DownloadChunk(downloadID: id, seq: nextSeq, kind: .offset,
                                                      offset: (chunk.offset ?? 0) + Int64(expected), limit: expected)
                            nextSeq += 1
                            try await db.insertChunks([extra])
                            chunks.append(extra)
                            pending.append(extra)
                        }
                    case .oidRange, .oidList:
                        if page.exceededTransferLimit {
                            outcome = (.failed, DownloadError.truncatedChunk(seq: seq).description)
                            try await db.updateChunk(downloadID: id, seq: seq, status: .failed, count: nil,
                                                     attempts: attempts[seq] ?? 1, error: outcome?.error)
                            group.cancelAll()
                            throw DownloadError.truncatedChunk(seq: seq)
                        }
                    }
                    try staging.clearChunk(seq)
                    let appended = try staging.append(page, chunk: seq)
                    try await db.updateChunk(downloadID: id, seq: seq, status: .done, count: Int64(appended),
                                             attempts: attempts[seq] ?? 1, error: nil)
                    chunks[index].status = .done
                    chunks[index].count = Int64(appended)
                    done += 1
                    features += Int64(appended)
                    bytes += Int64(fetched.bytes)
                    // The server coped with that one, so the next may be bigger.
                    pager.succeeded()
                    report(.running, inFlight: inFlight)
                    try await refill()
                }
                return useJSON && !startedAsJSON
            }
            if switchedToJSON {
                try await db.setLayerTransport(layerID: source.id, transport: Assessment.Transport.json.rawValue)
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

        // Everything fetched: export.
        do {
            let outputURL = Exporter.outputPath(directory: outputDirectory, server: server, service: service, layer: target,
                                                format: record.format)
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
}
