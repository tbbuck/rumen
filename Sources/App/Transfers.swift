import SwiftUI
import AppKit
import RumenKit

/// A run as the transfers UI shows it: the record plus names and live progress.
struct TransferRun: Identifiable, Equatable {
    let record: DownloadRecord
    let layerName: String
    let serviceName: String
    let serverName: String
    /// The run's server, for the settings link on a run the server turned away.
    let server: ServerRecord?
    let progress: DownloadProgress?
    let chunks: [ChunkStatus]
    let startedRunningAt: Date?

    var id: Int64 { record.id }
    var status: DownloadStatus { progress?.status ?? record.status }

    var dotColor: Color {
        switch status {
        case .running: Palette.accent
        case .complete: Palette.yes
        case .paused: Palette.warn
        case .failed: Palette.no
        default: Palette.muted2
        }
    }

    var statusChip: (String, Chip.Style)? {
        switch status {
        case .complete: ("Done", .yes)
        case .paused: ("Paused", .warn)
        case .failed: ("Failed", .no)
        case .cancelled: ("Cancelled", .muted)
        default: nil
        }
    }

    /// Live progress while running; the stored chunks otherwise, so a paused or failed run
    /// still shows how far it got.
    var fraction: Double {
        if let p = progress, p.chunksTotal > 0 { return Double(p.chunksDone) / Double(p.chunksTotal) }
        if status == .complete { return 1 }
        return chunksPlanned > 0 ? Double(chunksDone) / Double(chunksPlanned) : 0
    }
    var chunksDone: Int { chunks.filter { $0 == .done }.count }
    /// Split chunks are replaced by their halves, so they do not count.
    var chunksPlanned: Int { chunks.filter { $0 != .split }.count }

    /// "138 of 207 requests, 3 × 800 @ 2.4s, 4.2k features/s, 1:40 left" while running; a
    /// summary otherwise. The middle part is what the run is currently asking of the server —
    /// requests in flight, features per request, and how long the last one took — so a slow rate
    /// can be read against what produced it.
    var stats: String {
        switch status {
        case .running:
            guard let p = progress else { return "Starting…" }
            var parts = ["\(p.chunksDone.grouped) of \(p.chunksTotal.grouped) requests"]
            if let shape = Self.shape(p) { parts.append(shape) }
            if let started = startedRunningAt {
                let elapsed = Date().timeIntervalSince(started)
                if elapsed > 1, p.features > 0 {
                    let rate = Double(p.features) / elapsed
                    parts.append(rate >= 1000 ? "\((rate / 1000).formatted(.number.precision(.fractionLength(1))))k features/s"
                                              : "\(Int(rate)) features/s")
                    if p.chunksDone > 0 {
                        let remaining = Double(p.chunksTotal - p.chunksDone) * (elapsed / Double(p.chunksDone))
                        parts.append("\(Self.clock(remaining)) left")
                    }
                }
            }
            return parts.joined(separator: ", ")
        case .complete:
            let size = ByteCountFormatter.string(fromByteCount: record.bytes ?? 0, countStyle: .file)
            if record.format.isRaster { return "A picture, \(size), finished \(Age.text(record.finishedAt))." }
            let n = record.featureCount ?? 0
            return "\(n.grouped) features, \(size) fetched, finished \(Age.text(record.finishedAt))."
        case .paused, .failed:
            let kept = chunksPlanned > 0 ? "\(chunksDone.grouped) of \(chunksPlanned.grouped) requests kept. " : ""
            return kept + (record.error ?? status.rawValue)
        case .cancelled:
            return "Cancelled; \(chunksDone.grouped) of \(chunksPlanned.grouped) requests kept."
        case .planned:
            return "Planned, not started."
        }
    }

    /// "2/3 × 800 @ 2.4s": requests running out of the number this host currently allows,
    /// features per request, and how long the last one took.
    ///
    /// Both halves of the fraction are needed. The allowance alone cannot be read — three of
    /// what? — and the running count alone hides the reason a run is crawling, which is usually
    /// that the host has been throttled down to one slot rather than that the app is idle.
    ///
    /// Each part is left out when there is nothing to say: a WFS fetched in one request has no
    /// page size, and nothing has a latency until the first request comes back.
    static func shape(_ p: DownloadProgress) -> String? {
        var shape = ""
        if let allowed = p.concurrency {
            shape = "\(p.chunksInFlight)/\(allowed)"
            if let pageSize = p.pageSize { shape += " × \(pageSize.grouped)" }
        } else if let pageSize = p.pageSize {
            shape = "\(pageSize.grouped) per request"
        }
        guard let latency = p.latency else { return shape.isEmpty ? nil : shape }
        let time = latency < 10 ? "\(latency.formatted(.number.precision(.fractionLength(1))))s"
                                : "\(Int(latency.rounded()))s"
        return shape.isEmpty ? time : "\(shape) @ \(time)"
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "ONS: Census / states, WGS 84, GeoParquet" — or the output path once done. A where clause
    /// appears only when it is actually filtering: `1=1` is how "everything" is spelled to a
    /// server, and repeating it on every row says nothing.
    var targetLine: String {
        if status == .complete, let path = record.outputPath { return path }
        let sr = record.outWkid == 4326 ? "WGS 84" : "EPSG:\(record.outWkid)"
        let clause = record.whereClause.trimmingCharacters(in: .whitespacesAndNewlines)
        let filter = (clause.isEmpty || clause == "1=1") ? "" : "where \(clause), "
        return "\(serverName): \(serviceName) / \(layerName), \(filter)\(sr), \(record.format.label)"
    }
}

/// 40px bar along the bottom: the most relevant run, or nothing moving. Click opens the drawer.
struct TransfersStrip: View {
    @Environment(AppModel.self) private var model
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            Text("Transfers").font(.sheetUI(12.5, .semibold)).foregroundStyle(Palette.muted)
            if let run = model.headlineRun {
                StatusDot(color: run.dotColor)
                HStack(spacing: 6) {
                    Text("\(run.layerName), \(run.serviceName)").font(.sheetUI(12.5)).foregroundStyle(Palette.ink).lineLimit(1)
                    Text("on \(run.serverName)").font(.sheetUI(12.5)).foregroundStyle(Palette.muted2).lineLimit(1)
                }
                ProgressBar(fraction: run.fraction, color: run.status == .complete ? Palette.yes : (run.status == .paused ? Palette.warn : Palette.accent), height: 4)
                    .frame(width: 220)
                Text(run.stats).font(.sheetMono(11)).foregroundStyle(Palette.muted).lineLimit(1)
                Spacer()
                Button("Show all \(model.runs.count)") { model.showTransfers = true }.buttonStyle(LinkButtonStyle(size: 12.5))
            } else if model.preparing > 0 {
                ProgressView().controlSize(.small)
                Caption("Preparing a download…", size: 12.5)
                Spacer()
            } else {
                StatusDot(color: Palette.muted2)
                Caption("Nothing moving", size: 12.5, color: Palette.muted2)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .background(hovered ? Palette.line.opacity(0.5) : Palette.panel)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
        .contentShape(Rectangle())
        .hoverTracking($hovered, hand: true)
        // The whole row opens the drawer; the link inside still takes its own click.
        .onTapGesture { model.showTransfers = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.headlineRun.map { "Transfers: \($0.layerName), \($0.stats)" } ?? "Transfers: nothing moving")
        .accessibilityHint("Click the empty part to show the transfers")
        .help("Show the transfers (⌘⇧T)")
    }
}

/// The strip grown to 340px: header + scrolling run rows. The whole header row collapses it,
/// as the whole strip opens it.
struct TransfersDrawer: View {
    @Environment(AppModel.self) private var model
    @State private var headerHovered = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Transfers").font(.sheetUI(12.5, .semibold)).foregroundStyle(Palette.muted)
                Caption(summary, size: 12.5)
                Spacer()
                if model.runs.contains(where: { $0.status != .running }) {
                    AsyncButton("Clear finished", busy: "Clearing…") { await model.clearFinishedDownloads() }.buttonStyle(LinkButtonStyle(size: 12.5))
                        .help("Remove every run that is not running; files on disk are kept")
                }
                Button {
                    model.showTransfers = false
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                }
                .buttonStyle(LinkButtonStyle())
                .accessibilityLabel("Collapse the transfers")
                .help("Collapse")
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .frame(maxWidth: .infinity)
            .background(headerHovered ? Palette.line.opacity(0.5) : Palette.panel)
            .contentShape(Rectangle())
            .hoverTracking($headerHovered, hand: true)
            .onTapGesture { model.showTransfers = false }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Transfers")
            .accessibilityHint("Click the empty part to collapse")
            ScrollView {
                // A plain stack: a lazy one wraps each row in a nameless cell of its own, and the
                // list is a few dozen rows at most.
                VStack(spacing: 0) {
                    if model.preparing > 0 {
                        PreparingRow(count: model.preparing)
                        Rectangle().fill(Palette.line).frame(height: 1)
                    }
                    ForEach(model.runs) { run in
                        RunRow(run: run)
                        Rectangle().fill(Palette.line).frame(height: 1)
                    }
                    if model.runs.isEmpty, model.preparing == 0 {
                        Caption("No transfers yet. Start one from a layer's Download tab.").padding(16)
                    }
                }
            }
        }
        .frame(height: 340)
        .frame(maxWidth: .infinity)
        .background(Palette.panel)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line2).frame(height: 1) }
        .edgeShade(.top)
    }

    private var summary: String {
        let runs = model.runs
        let running = runs.filter { $0.status == .running }.count
        let inFlight = runs.compactMap(\.progress).reduce(0) { $0 + $1.chunksInFlight }
        var s = "\(runs.count) run\(runs.count == 1 ? "" : "s")"
        if running > 0 { s += ", \(running) running" }
        if inFlight > 0, let host = model.currentServer?.host { s += ", \(inFlight) request\(inFlight == 1 ? "" : "s") in flight to \(host)" }
        return s
    }
}

/// A download asked for but not yet planned. Planning asks the server what there is to fetch —
/// for an OID list of a large layer, a request of its own — and that is where the wait between
/// clicking Start and a run appearing comes from. The row holds the place meanwhile.
private struct PreparingRow: View {
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(count == 1 ? "Preparing a download" : "Preparing \(count) downloads")
                .font(.sheetUI(13.5, .bold)).foregroundStyle(Palette.ink)
            Caption("asking the server what there is to fetch")
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// One run: who · progress · actions.
private struct RunRow: View {
    @Environment(AppModel.self) private var model
    let run: TransferRun

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(run.layerName).font(.sheetUI(13.5, .bold)).foregroundStyle(Palette.ink).lineLimit(1)
                    Text("on \(run.serverName)").font(.sheetUI(12.5)).foregroundStyle(Palette.muted).lineLimit(1)
                    Chip(text: run.record.transport.rawValue.uppercased())
                    Chip(text: run.record.strategy.label.capitalizedFirst)
                    if let (text, style) = run.statusChip { Chip(text: text, style: style) }
                }
                Text(run.targetLine).font(.sheetMono(11)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Text(run.stats).font(.sheetUI(12.5)).foregroundStyle(run.status == .failed ? Palette.no : Palette.muted).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The grid widens (from the text column) before it grows tall; the row grows to fit it.
            let showsGrid = run.status == .running && !run.chunks.isEmpty
            let gridWidth = showsGrid ? max(ChunkGrid.baseWidth, ChunkGrid.layout(count: run.chunks.count).size.width) : ChunkGrid.baseWidth
            Group {
                if showsGrid {
                    ChunkGrid(statuses: run.chunks, inFlight: run.progress?.chunksInFlight ?? 0)
                } else {
                    ProgressBar(fraction: run.fraction, color: run.status == .complete ? Palette.yes : (run.status == .paused ? Palette.warn : Palette.accent))
                        .padding(.top, 6)
                }
            }
            .frame(width: gridWidth, alignment: .topLeading)
            RunActions(run: run).frame(width: 214, alignment: .leading)
            RemoveRunButton(run: run)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Run: \(run.layerName) on \(run.serverName), \(run.statusChip?.0 ?? run.status.rawValue)")
    }
}

/// 7px cells in 2px gaps: pending `line`, done `accent`, in flight `accent-soft` + ring,
/// failed `no`. 23 columns for up to eight rows; a bigger plan widens the grid first (to 48
/// columns, 430px) and only then adds rows, and the run row grows to fit. Cells never shrink.
struct ChunkGrid: View {
    let statuses: [ChunkStatus]
    let inFlight: Int

    static let cell: CGFloat = 7
    static let gap: CGFloat = 2
    static let minColumns = 23
    static let maxColumns = 48
    static let preferredRows = 8
    /// The default width: 23 columns.
    static var baseWidth: CGFloat { CGFloat(minColumns) * (cell + gap) - gap }

    /// Columns, rows, and the size that fits `count` cells at full size.
    static func layout(count: Int) -> (columns: Int, rows: Int, size: CGSize) {
        let n = max(1, count)
        let columns = min(maxColumns, max(minColumns, Int((Double(n) / Double(preferredRows)).rounded(.up))))
        let rows = max(1, (n + columns - 1) / columns)
        return (columns, rows, CGSize(width: CGFloat(columns) * (cell + gap) - gap, height: CGFloat(rows) * (cell + gap) - gap))
    }

    var body: some View {
        let layout = Self.layout(count: statuses.count)
        Canvas { context, _ in
            let columns = layout.columns
            let step = Self.cell + Self.gap
            var inFlightLeft = inFlight
            for (index, status) in statuses.enumerated() {
                let x = CGFloat(index % columns) * step
                let y = CGFloat(index / columns) * step
                let rect = CGRect(x: x, y: y, width: Self.cell, height: Self.cell)
                let path = Path(roundedRect: rect, cornerRadius: 1.5)
                switch status {
                case .done: context.fill(path, with: .color(Palette.accent))
                case .failed: context.fill(path, with: .color(Palette.no))
                case .split: context.fill(path, with: .color(Palette.line2))
                case .pending:
                    if inFlightLeft > 0 {
                        inFlightLeft -= 1
                        context.fill(path, with: .color(Palette.accentSoft))
                        context.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 1.5), with: .color(Palette.accent), lineWidth: 1)
                    } else {
                        context.fill(path, with: .color(Palette.line))
                    }
                }
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .accessibilityLabel("\(statuses.filter { $0 == .done }.count) of \(statuses.filter { $0 != .split }.count) requests done, \(inFlight) in flight")
    }
}

/// Every state has its next step.
private struct RunActions: View {
    @Environment(AppModel.self) private var model
    let run: TransferRun

    var body: some View {
        HStack(spacing: 14) {
            switch run.status {
            case .running:
                Button("Pause") { model.cancelDownload(run.id) }.buttonStyle(LinkButtonStyle())
                    .help("Stops after the requests in flight; the run can be resumed")
            case .complete:
                Button("Show in Finder") { model.reveal(run.record.outputPath) }.buttonStyle(LinkButtonStyle())
                if !run.record.format.isRaster {   // a picture has no rows to open and nothing to re-export
                    AsyncButton("Re-export", busy: "Opening…") { await model.showStored(run.record) }.buttonStyle(LinkButtonStyle())
                        .help("Open the stored file: its rows, a SQL scratch box, and export as GeoJSON or CSV without the server")
                    AsyncButton("Map", busy: "Opening…") { await model.showStoredMap(run.record) }.buttonStyle(LinkButtonStyle())
                }
            case .paused:
                // A run pauses when the server answers a request with 498 or 499 mid-run. Token
                // sign-in is not built (backlog), so the way through is to try again, or to set
                // the server's Cookie first when the server is behind a session wall.
                let starting = model.resuming.contains(run.id)
                Button(starting ? "Starting…" : "Resume") { Task { await model.resumeDownload(run.id) } }
                    .buttonStyle(PrimaryButtonStyle(small: true))
                    .disabled(starting)
                    .help("Picks up where it stopped; nothing already fetched is refetched")
                if let server = run.server {
                    Button("Settings…") { model.settingsServer = server }.buttonStyle(LinkButtonStyle())
                        .help("The server asked for a token. For a server behind a login, set its Cookie here, then resume.")
                }
                AsyncButton("Remove", busy: "Removing…") { await model.removeDownload(run.id) }.buttonStyle(LinkButtonStyle())
            case .failed, .cancelled, .planned:
                let starting = model.resuming.contains(run.id)
                Button(starting ? "Starting…" : (run.status == .failed ? "Retry" : "Resume")) {
                    Task { await model.resumeDownload(run.id) }
                }
                .buttonStyle(LinkButtonStyle())
                .disabled(starting)
                if let countdown = model.autoRetryCountdown(run.id), !starting {
                    Caption(countdown)
                        .help("Failed runs are picked up again on their own, waiting twice as long each time")
                    Button("Stop") { model.cancelAutoRetry(run.id) }.buttonStyle(LinkButtonStyle())
                        .help("Leaves the run where it is rather than trying again")
                }
                AsyncButton("Remove", busy: "Removing…") { await model.removeDownload(run.id) }.buttonStyle(LinkButtonStyle())
            }
        }
    }
}

/// The [x] on a run row: removes it from the list (files on disk are kept). Not while running.
private struct RemoveRunButton: View {
    @Environment(AppModel.self) private var model
    let run: TransferRun
    @State private var hovered = false

    var body: some View {
        AsyncButton { removing in
            Image(systemName: removing ? "hourglass" : "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovered ? Palette.ink : Palette.muted2)
                .frame(width: 22, height: 22)
                .background(hovered ? Palette.line : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        } action: {
            await model.removeDownload(run.id)
        }
        .buttonStyle(.plain)
        .hoverTracking($hovered, hand: run.status != .running)
        .accessibilityLabel("Remove the run for \(run.layerName)")
        .disabled(run.status == .running)
        .help(run.status == .running ? "Pause the run before removing it" : "Remove from the list; the file on disk is kept")
    }
}
