import SwiftUI
import AppKit
import ArcGISKit

/// Configure, then run (SPEC §5.6–5.7): the plan in plain sentences, format, spatial
/// reference, domain labels, where, output path, the manual override only when automatic
/// selection has failed, Start, and this layer's run history.
struct DownloadTab: View {
    @Environment(AppModel.self) private var model
    let layer: LayerRecord
    let service: ServiceRecord
    @State private var whereClause = "1=1"
    @State private var wgs84 = false
    @State private var domainLabels = false
    @State private var manualStrategy: Assessment.Strategy = .offset
    @State private var manualPageSize = 1000
    @State private var useManual = false

    private var assessment: Assessment? { model.assessment }
    private var verdict: Verdict { Verdict(layer.extractable) }

    var body: some View {
        DownloadPlanText(layer: layer, assessment: assessment, wgs84: wgs84, whereClause: whereClause)
        HStack(spacing: 18) {
            Menu {
                ForEach(ExportFormat.allCases, id: \.self) { format in Button(format.label) {} }
                Button("GeoPackage, GeoJSON, FlatGeobuf, CSV arrive with M7") {}.disabled(true)
            } label: {
                Text("Format: GeoParquet").font(.sheetUI(12.5)).hoverLabel()
            }
            .menuStyle(.borderlessButton).fixedSize()
            Picker("", selection: $wgs84) {
                Text(verbatim: layer.effectiveWkid.map { "Native (\($0))" } ?? "Native").tag(false)
                Text("WGS 84").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().tint(Palette.accent)
            Toggle("Domain label columns", isOn: $domainLabels).toggleStyle(.checkbox).font(.sheetUI(12.5))
                .help("Adds a <field>_label column beside each coded-value field")
            Spacer()
        }
        VStack(alignment: .leading, spacing: 6) {
            Caption("Where")
            TextField("1=1", text: $whereClause).textFieldStyle(SheetFieldStyle(mono: true)).frame(maxWidth: 720)
        }
        OutputPathPreview(path: model.outputPath(for: layer, service: service).path)
        if verdict != .extractable || useManual {
            DisclosureGroup(isExpanded: $useManual) {
                HStack(spacing: 14) {
                    Picker("Strategy", selection: $manualStrategy) {
                        Text("Offset paging").tag(Assessment.Strategy.offset)
                        Text("OID range").tag(Assessment.Strategy.oidRange)
                        Text("OID list").tag(Assessment.Strategy.oidList)
                    }
                    .font(.sheetUI(12.5)).fixedSize()
                    TextField("Page size", value: $manualPageSize, format: .number).textFieldStyle(SheetFieldStyle(mono: true)).frame(width: 110)
                    Caption("Used instead of the automatic choice.", size: 11.5, color: Palette.muted2)
                }
                .padding(.top, 8)
            } label: {
                Text("Manual strategy").font(.sheetUI(12.5, .semibold)).foregroundStyle(Palette.muted)
            }
        }
        HStack(spacing: 18) {
            Button("Start download") { start() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(verdict != .extractable && !useManual)
                .help(verdict == .extractable || useManual ? "Fetch every matching feature and write \(model.outputPath(for: layer, service: service).lastPathComponent)"
                      : "Not extractable; open Manual strategy to force an attempt")
            if model.transfersError != nil {
                ErrorText(message: model.transfersError ?? "")
            }
        }
        let history = model.runs.filter { $0.record.layerID == layer.id }
        if !history.isEmpty {
            SectionHeading("Runs for this layer")
            VStack(spacing: 0) {
                ForEach(history) { run in
                    HStack(spacing: 10) {
                        StatusDot(color: run.dotColor)
                        Text(Age.text(run.record.startedAt)).font(.sheetUI(12.5)).foregroundStyle(Palette.ink).frame(width: 130, alignment: .leading)
                        if let (text, style) = run.statusChip { Chip(text: text, style: style) }
                        Text(run.stats).font(.sheetUI(12)).foregroundStyle(Palette.muted).lineLimit(1)
                        Spacer()
                        if run.status == .complete {
                            Button("Show in Finder") { model.reveal(run.record.outputPath) }.buttonStyle(LinkButtonStyle(size: 12))
                        }
                    }
                    .frame(height: 27)
                    Rectangle().fill(Palette.line).frame(height: 1)
                }
            }
            .frame(maxWidth: 880)
        }
    }

    private func start() {
        var request = DownloadRequest(layerID: layer.id, outputDirectory: model.downloadDirectory)
        request.whereClause = whereClause.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "1=1" : whereClause
        request.outWkid = wgs84 ? 4326 : (layer.effectiveWkid ?? 4326)
        request.domainLabels = domainLabels
        if useManual {
            request.manualStrategy = manualStrategy
            request.manualPageSize = max(1, manualPageSize)
        }
        Task { await model.startDownload(request) }
    }
}

/// What will happen, before it does, in the statement's voice.
private struct DownloadPlanText: View {
    let layer: LayerRecord
    let assessment: Assessment?
    let wgs84: Bool
    let whereClause: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(plan).font(.sheetUI(15)).foregroundStyle(Palette.ink).lineSpacing(4).frame(maxWidth: 720, alignment: .leading)
        }
    }

    private var plan: String {
        guard let a = assessment, a.verdict == true, let transport = a.transport, let strategy = a.strategy else {
            return layer.extractableReason ?? "The layer has not been assessed yet."
        }
        var s = "\(transport == .pbf ? "PBF" : "JSON")\(a.viaTwin ? " through the FeatureServer twin" : ""), \(strategy.label)"
        if let size = a.pageSize { s += " at \(size.grouped) records per request" }
        s += "."
        if let count = layer.featureCount {
            s += " " + a.countSentence(features: count)
        } else {
            s += " The count is probed first, then every page is fetched in parallel."
        }
        let sr = wgs84 ? "WGS 84" : (layer.effectiveWkid.map { "the native spatial reference (\($0))" } ?? "the native spatial reference")
        s += " Written as GeoParquet in \(sr)"
        let w = whereClause.trimmingCharacters(in: .whitespacesAndNewlines)
        if !w.isEmpty, w != "1=1" { s += ", where \(w)" }
        return s + "."
    }
}

/// `<dir>/<server>/<service>/<layer>.parquet` in mono with Change and Reveal.
private struct OutputPathPreview: View {
    @Environment(AppModel.self) private var model
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Caption("Output")
            HStack(spacing: 14) {
                Text(path).font(.sheetMono(12)).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Button("Change") { model.chooseDownloadDirectory() }.buttonStyle(LinkButtonStyle(size: 12.5))
                Button("Reveal") { model.reveal(model.downloadDirectory.path) }.buttonStyle(LinkButtonStyle(size: 12.5))
            }
            .frame(maxWidth: 880, alignment: .leading)
        }
    }
}
