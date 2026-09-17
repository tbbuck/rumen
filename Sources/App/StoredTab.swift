import SwiftUI
import AppKit
import ArcGISKit

/// The layer's data on disk (M7): the stored GeoParquet's facts, a grid over its rows, a
/// DuckDB SQL scratch box, and re-export to GeoJSON or CSV without touching the server.
struct StoredTab: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: StoredSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if session.runs.isEmpty {
                NothingStored()
            } else {
                StoredFileHeader(session: session)
                ExportsSection(session: session)
                ScratchBox(session: session)
                if let error = session.error { ErrorText(message: error) }
                if let grid = session.grid {
                    VStack(alignment: .leading, spacing: 8) {
                        Caption(session.caption)
                        if !grid.columns.isEmpty {
                            ResultsGrid(grid: grid)
                                .frame(minHeight: 200, maxHeight: .infinity)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line2, lineWidth: 1))
                        }
                    }
                } else if session.isRunning {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Caption("Opening the file…") }
                }
                Spacer(minLength: 0)
            }
        }
        .task(id: session.layer.id) { await session.load() }
        .onChange(of: session.selectedRunID) { Task { await session.load() } }
        .alert("Replace the existing file?", isPresented: Binding(get: { session.pendingReexport != nil },
                                                                  set: { if !$0 { session.pendingReexport = nil } })) {
            Button("Replace", role: .destructive) {
                if let pending = session.pendingReexport { Task { await session.reexport(pending.format, overwrite: true) } }
                session.pendingReexport = nil
            }
            Button("Keep it", role: .cancel) { session.pendingReexport = nil }
        } message: {
            if let pending = session.pendingReexport {
                let age = (try? FileManager.default.attributesOfItem(atPath: pending.path)[.modificationDate] as? Date).map { Age.text($0) } ?? "unknown age"
                Text("\(pending.path)\nwritten \(age). Replacing it cannot be undone.")
            }
        }
    }
}

private struct NothingStored: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nothing stored for this layer yet.").font(.sheetUI(15)).foregroundStyle(Palette.ink)
            Caption("Download it and the file appears here: a grid over its rows, a DuckDB scratch box, and re-export to other formats.")
                .frame(maxWidth: 720, alignment: .leading)
            Button("Go to Download") { model.layerTab = .download }.buttonStyle(LinkButtonStyle())
        }
    }
}

/// Which file, where it is, and what it holds.
private struct StoredFileHeader: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: StoredSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if let run = session.selectedRun {
                    Chip(text: run.format.label)
                    Text(run.outputPath ?? "").font(.sheetMono(12)).foregroundStyle(Palette.ink)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Button("Show in Finder") { model.reveal(run.outputPath) }.buttonStyle(LinkButtonStyle(size: 12.5))
                    Button("Map") { Task { await model.showStoredMap(run) } }.buttonStyle(LinkButtonStyle(size: 12.5))
                }
                Spacer()
                if session.runs.count > 1 {
                    Menu {
                        ForEach(session.runs) { run in
                            Button(label(run)) { session.selectedRunID = run.id }
                        }
                    } label: {
                        Text("File: \(session.selectedRun.map(label) ?? "")").font(.sheetUI(12.5)).hoverLabel()
                    }
                    .menuStyle(.button).buttonStyle(.borderless).fixedSize()
                }
            }
            Caption(facts).frame(maxWidth: 880, alignment: .leading).lineLimit(2)
        }
    }

    private func label(_ run: DownloadRecord) -> String {
        "\(URL(fileURLWithPath: run.outputPath ?? "").lastPathComponent), \(Age.text(run.finishedAt))"
    }

    private var facts: String {
        guard let run = session.selectedRun else { return "" }
        var parts = [String]()
        if let summary = session.summary {
            parts.append("\(summary.rows.grouped) row\(summary.rows == 1 ? "" : "s") in \(summary.columns.count) columns")
            parts.append(ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file))
        } else if !session.selectedExists {
            parts.append("the file is missing from disk")
        }
        parts.append(run.outWkid == 4326 ? "WGS 84" : "\(srName(run.outWkid)) (\(run.outWkid))")
        parts.append("written \(Age.text(run.finishedAt))")
        if let invalid = run.invalidGeometryCount, invalid > 0 { parts.append("\(invalid.grouped) invalid geometries as received") }
        return parts.joined(separator: ", ") + ". " + run.format.geometryNote.capitalizedFirst + "."
    }
}

/// Files written beside the stored one, and the two ways to add another.
private struct ExportsSection: View {
    @Environment(AppModel.self) private var model
    let session: StoredSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 18) {
                SectionHeading("Exports")
                ForEach(ExportFormat.reexportable, id: \.self) { format in
                    Button("Export as \(format.label)") { Task { await session.reexport(format) } }
                        .buttonStyle(LinkButtonStyle(size: 12.5))
                        .disabled(session.exporting != nil || !session.selectedExists)
                        .help("Write \(format.label) beside the stored file, \(format.geometryNote); the server is not contacted")
                }
                if let format = session.exporting {
                    ProgressView().controlSize(.small)
                    Caption("Writing \(format.label)…", size: 12)
                }
            }
            if let error = session.exportError { ErrorText(message: error) }
            let mine = session.exports.filter { $0.downloadID == session.selectedRunID }
            if mine.isEmpty {
                Caption("None yet. A re-export reads the stored file back through DuckDB.", size: 12, color: Palette.muted2)
            } else {
                VStack(spacing: 0) {
                    ForEach(mine) { export in
                        HStack(spacing: 10) {
                            Chip(text: export.format.label)
                            Text(export.outputPath).font(.sheetMono(11.5)).foregroundStyle(Palette.ink)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Caption(summary(export), size: 11.5, color: Palette.muted2).lineLimit(1)
                            Spacer()
                            Button("Show in Finder") { model.reveal(export.outputPath) }.buttonStyle(LinkButtonStyle(size: 12))
                        }
                        .frame(height: 27)
                        Rectangle().fill(Palette.line).frame(height: 1)
                    }
                }
                .frame(maxWidth: 880)
            }
        }
    }

    private func summary(_ export: ExportRecord) -> String {
        var parts = [String]()
        if let n = export.featureCount { parts.append("\(n.grouped) features") }
        if let bytes = export.bytes { parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
        parts.append(export.outWkid == 4326 ? "WGS 84" : "EPSG:\(export.outWkid)")
        parts.append(Age.text(export.createdAt))
        return parts.joined(separator: ", ")
    }
}

/// DuckDB SQL over the file, which is available as `data`.
private struct ScratchBox: View {
    @Bindable var session: StoredSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                SectionHeading("Query the file")
                Caption("DuckDB SQL; the file is the table data.", size: 12)
                Spacer()
            }
            HStack(alignment: .top, spacing: 12) {
                TextEditor(text: $session.sql)
                    .font(.sheetMono(12.5))
                    .foregroundStyle(Palette.ink)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .frame(height: 64)
                    .background(Palette.bg, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.line2, lineWidth: 1))
                    .frame(maxWidth: 720)
                Button("Run") { Task { await session.run() } }
                    .buttonStyle(PrimaryButtonStyle(small: true))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(session.isRunning || !session.selectedExists)
                    .help("Run the SQL over the stored file (⌘↩)")
                if session.isRunning { ProgressView().controlSize(.small) }
            }
        }
    }
}
