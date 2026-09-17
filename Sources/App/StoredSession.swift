import Foundation
import Observation
import ArcGISKit

/// A re-export whose target file already exists, awaiting consent (SPEC §5.7).
struct PendingReexport: Equatable {
    let format: ExportFormat
    let path: String
}

/// The Stored tab's state for one layer (M7): which downloaded file is open, its facts, the
/// SQL scratch box and its grid, the re-exports beside the file, and the export in progress.
/// Everything heavy runs on the file's own engine actor or a detached task; nothing here
/// touches the server.
@MainActor @Observable
final class StoredSession {
    let layer: LayerRecord
    private let database: AppDatabase
    /// Complete downloads of this layer, newest first.
    private(set) var runs: [DownloadRecord]
    private(set) var exports: [ExportRecord] = []
    var selectedRunID: Int64? {
        didSet { if oldValue != selectedRunID { file = nil; summary = nil; grid = nil; caption = ""; error = nil } }
    }
    var sql = StoredFile.defaultSQL
    private(set) var summary: StoredFile.Summary?
    private(set) var grid: QueryGrid?
    private(set) var caption = ""
    private(set) var isRunning = false
    private(set) var exporting: ExportFormat?
    private(set) var error: String?
    private(set) var exportError: String?
    var pendingReexport: PendingReexport?
    private var file: StoredFile?

    static let rowLimit = 1000

    init(layer: LayerRecord, database: AppDatabase, runs: [DownloadRecord]) {
        self.layer = layer
        self.database = database
        self.runs = runs
        selectedRunID = runs.first?.id
    }

    var selectedRun: DownloadRecord? { runs.first { $0.id == selectedRunID } ?? runs.first }
    var selectedPath: String? { selectedRun?.outputPath }
    var selectedExists: Bool { selectedPath.map { FileManager.default.fileExists(atPath: $0) } ?? false }

    /// The transfers list changed: keep the selection when its run is still there.
    func updateRuns(_ runs: [DownloadRecord]) {
        self.runs = runs
        if selectedRunID == nil || !runs.contains(where: { $0.id == selectedRunID }) {
            selectedRunID = runs.first?.id
        }
    }

    // MARK: - Loading

    /// Opens the selected file (once), reads its facts, runs the scratch SQL, lists exports.
    func load() async {
        await loadExports()
        guard let path = selectedPath else { return }
        guard FileManager.default.fileExists(atPath: path) else {
            error = ExportError.missingSource(path).description
            return
        }
        if file == nil {
            error = nil
            do {
                file = try await Task.detached(priority: .userInitiated) { try StoredFile(path: path) }.value
                summary = try await file?.summary()
            } catch {
                self.error = String(describing: error)
                return
            }
        }
        await run()
    }

    /// Runs the scratch box's SQL over the file.
    func run() async {
        guard let file, !isRunning else { return }
        isRunning = true
        error = nil
        defer { isRunning = false }
        do {
            let page = try await file.query(sql, limit: Self.rowLimit)
            grid = page.grid
            let n = page.grid.rows.count
            caption = page.truncated ? "Showing the first \(n.grouped) of \(page.total.grouped) rows."
                : (n == 0 ? "No rows." : "\(n.grouped) row\(n == 1 ? "" : "s").")
        } catch {
            self.error = String(describing: error)
        }
    }

    func loadExports() async {
        do { exports = try await database.exports(layerID: layer.id) } catch { self.error = String(describing: error) }
    }

    // MARK: - Re-export

    /// Writes the selected file beside itself in `format`, never touching the server. An
    /// existing target asks first; `overwrite` is the answer.
    func reexport(_ format: ExportFormat, overwrite: Bool = false) async {
        guard let run = selectedRun, let path = run.outputPath, exporting == nil else { return }
        let source = URL(fileURLWithPath: path)
        let target = Exporter.siblingPath(of: source, format: format)
        if !overwrite, FileManager.default.fileExists(atPath: target.path) {
            pendingReexport = PendingReexport(format: format, path: target.path)
            return
        }
        exporting = format
        exportError = nil
        defer { exporting = nil }
        do {
            let wkid = run.outWkid
            let result = try await Task.detached(priority: .userInitiated) {
                try Exporter.reexport(parquet: source, sourceWkid: wkid, to: target, format: format, overwrite: true)
            }.value
            try await database.recordExport(downloadID: run.id, format: format, outWkid: format.forcesWGS84 ? 4326 : wkid, result: result)
            await loadExports()
        } catch {
            exportError = String(describing: error)
        }
    }
}
