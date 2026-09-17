import SwiftUI
import AppKit
import ArcGISKit

/// Configure, then run (SPEC §5.6–5.7): the plan in plain sentences, format, spatial
/// reference, domain labels, where, output path, the manual override only when automatic
/// selection has failed, Start, and this layer's run history. An OGC layer (M10) offers what
/// its protocol can take: a WFS type has formats and a spatial reference but no where clause
/// and no manual strategy; a WMS layer has a picture format and nothing else.
struct DownloadTab: View {
    @Environment(AppModel.self) private var model
    let layer: LayerRecord
    let service: ServiceRecord
    @State private var whereClause = "1=1"
    @State private var wgs84 = false
    @State private var format: ExportFormat = .geoParquet
    @State private var domainLabels = false
    @State private var manualStrategy: Assessment.Strategy = .offset
    private static let strategyNames: [Assessment.Strategy: String] = [.offset: "Offset paging", .oidRange: "OID range", .oidList: "OID list"]
    @State private var manualPageSize = 1000
    @State private var useManual = false
    /// A WMS layer with features to give (a GeoJSON GetMap, or a WFS twin) can still be saved
    /// as a picture instead.
    @State private var wantsPicture = false

    private var assessment: Assessment? { model.assessment }
    private var verdict: Verdict { Verdict(layer.extractable) }
    private var isOGC: Bool { service.type.isOGC }
    private var isPicture: Bool { service.type == .wms && (wantsPicture || verdict != .extractable) }

    /// The picture formats the WMS offers, of the two this app writes; PNG when it lists none.
    private var pictureFormats: [ExportFormat] {
        let offered = service.ogcDetail?.formats.map { $0.lowercased() } ?? []
        let usable = [ExportFormat.png, .geoTIFF].filter { f in offered.isEmpty || offered.contains { $0.hasPrefix(f.mediaType ?? "") } }
        return usable.isEmpty ? [.png] : usable
    }

    /// WGS 84 can be asked of a WFS only when the type is offered in it.
    private var wgs84Offered: Bool {
        guard isOGC else { return true }
        return layer.effectiveWkid == 4326 || layer.ogcDetail?.wgs84CRS != nil
    }

    var body: some View {
        DownloadPlanText(layer: layer, service: service, assessment: assessment, wgs84: (wgs84 || format.forcesWGS84) && wgs84Offered,
                         format: format, whereClause: whereClause)
            .onAppear {
                // Start from the preferences; the tab's own choices apply to this run only.
                if isPicture {
                    format = pictureFormats.first ?? .png
                } else {
                    format = model.preferences.defaultFormat
                    wgs84 = (model.preferences.defaultWGS84 || format.forcesWGS84) && wgs84Offered
                    domainLabels = model.preferences.domainLabels
                }
            }
        HStack(spacing: 18) {
            if service.type == .wms, verdict == .extractable {
                Picker("", selection: $wantsPicture) {
                    Text("Features").tag(false)
                    Text("Picture").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().tint(Palette.accent)
                .help("Features through GetMap as GeoJSON or the WFS twin, or one GetMap picture of the extent")
                .onChange(of: wantsPicture) { format = wantsPicture ? (pictureFormats.first ?? .png) : model.preferences.defaultFormat }
            }
            // One choice among a few: a pull-down whose face names the choice.
            NativeMenu(title: "Format: \(format.label)",
                       items: (isPicture ? pictureFormats : ExportFormat.vector).map { choice in .init(choice.label, checked: choice == format) { format = choice } })
            .inline()
            .onChange(of: format) { if format.forcesWGS84 { wgs84 = true } }
            .help(format.geometryNote.capitalizedFirst)
            if !isPicture {
                Picker("", selection: $wgs84) {
                    Text(verbatim: layer.effectiveWkid.map { "Native (\($0))" } ?? "Native").tag(false)
                    Text("WGS 84").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().tint(Palette.accent)
                .disabled(format.forcesWGS84 || !wgs84Offered)
                .help(format.forcesWGS84 ? "GeoJSON is always WGS 84 (RFC 7946)"
                      : (wgs84Offered ? "The spatial reference the features are written in" : "The server does not offer this type in WGS 84; it is fetched and written in its native reference"))
            }
            if !isOGC {
                Toggle("Domain label columns", isOn: $domainLabels).toggleStyle(.checkbox).font(.sheetUI(12.5))
                    .help("Adds a <field>_label column beside each coded-value field")
            }
            Spacer()
        }
        if !isOGC {
            VStack(alignment: .leading, spacing: 6) {
                Caption("Where")
                TextField("1=1", text: $whereClause).textFieldStyle(SheetFieldStyle(mono: true)).frame(maxWidth: 720)
            }
        }
        OutputPathPreview(path: model.outputPath(for: layer, service: service, format: format).path)
        if !isOGC, verdict != .extractable || useManual {
            DisclosureGroup(isExpanded: $useManual) {
                HStack(spacing: 14) {
                    NativeMenu(title: "Strategy: \(Self.strategyNames[manualStrategy] ?? "")",
                               items: [Assessment.Strategy.offset, .oidRange, .oidList].map { choice in
                                   .init(Self.strategyNames[choice] ?? "", checked: choice == manualStrategy) { manualStrategy = choice }
                               })
                    .inline()
                    TextField("Page size", value: $manualPageSize, format: .number).textFieldStyle(SheetFieldStyle(mono: true)).frame(width: 110)
                    Caption("Used instead of the automatic choice.", size: 11.5, color: Palette.muted2)
                }
                .padding(.top, 8)
            } label: {
                Text("Manual strategy").font(.sheetUI(12.5, .semibold)).foregroundStyle(Palette.muted)
            }
        }
        HStack(spacing: 18) {
            Button(isPicture ? "Save picture" : "Start download") { start() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!(verdict == .extractable || useManual || isPicture))
                .help(isPicture ? "One GetMap of the layer's extent, written as \(format.label)"
                      : (verdict == .extractable || useManual ? "Fetch every matching feature and write \(model.outputPath(for: layer, service: service, format: format).lastPathComponent)"
                         : "Not extractable; open Manual strategy to force an attempt"))
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
                            if !run.record.format.isRaster {
                                Button("Stored") { Task { await model.showStored(run.record) } }.buttonStyle(LinkButtonStyle(size: 12))
                                    .help("The file's rows, a SQL scratch box, and re-export")
                            }
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
        let trimmed = whereClause.trimmingCharacters(in: .whitespacesAndNewlines)
        request.whereClause = isOGC || trimmed.isEmpty ? "1=1" : whereClause
        request.outWkid = (wgs84 || format.forcesWGS84) && wgs84Offered ? 4326 : (layer.effectiveWkid ?? 4326)
        request.format = format
        request.domainLabels = isOGC ? false : domainLabels
        if useManual, !isOGC {
            request.manualStrategy = manualStrategy
            request.manualPageSize = max(1, manualPageSize)
        }
        Task { await model.startDownload(request) }
    }
}

/// What will happen, before it does, in the statement's voice.
private struct DownloadPlanText: View {
    let layer: LayerRecord
    let service: ServiceRecord
    let assessment: Assessment?
    let wgs84: Bool
    let format: ExportFormat
    let whereClause: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(plan).font(.sheetUI(15)).foregroundStyle(Palette.ink).lineSpacing(4).frame(maxWidth: 720, alignment: .leading)
        }
    }

    private var plan: String {
        if service.type == .wms, format.isRaster {
            let detail = service.ogcDetail
            let cap = min(detail?.maxWidth ?? 4096, detail?.maxHeight ?? 4096, 4096)
            let crs = layer.ogcDetail?.supportsWebMercator == true ? "Web Mercator" : "WGS 84"
            let world = format == .png ? " with a world file beside it" : ""
            return "One GetMap picture of the layer's extent in \(crs), at most \(cap.grouped) pixels on its long side, written as \(format.label)\(world)."
        }
        if service.type == .wmts {
            return layer.extractableReason ?? "A tile cache is not downloaded; preview it on the map."
        }
        guard let a = assessment, a.verdict == true, let transport = a.transport, let strategy = a.strategy else {
            return layer.extractableReason ?? "The layer has not been assessed yet."
        }
        let twin = service.type.isOGC ? " through the WFS twin" : " through the FeatureServer twin"
        var s = "\(Self.transportName(transport))\(a.viaTwin ? twin : ""), \(strategy.label)"
        if let size = a.pageSize { s += " at \(size.grouped) records per request" }
        s += "."
        if strategy == .single {
            s += " Everything arrives in one request."
        } else if let count = layer.featureCount {
            s += " " + a.countSentence(features: count)
        } else {
            s += " The count is probed first, then every page is fetched in parallel."
        }
        let sr = wgs84 ? "WGS 84" : (layer.effectiveWkid.map { "the native spatial reference (\($0))" } ?? "the native spatial reference")
        s += " Written as \(format.label) in \(sr)"
        let w = whereClause.trimmingCharacters(in: .whitespacesAndNewlines)
        if !service.type.isOGC, !w.isEmpty, w != "1=1" { s += ", where \(w)" }
        return s + "."
    }

    static func transportName(_ transport: Assessment.Transport) -> String {
        switch transport {
        case .pbf: "PBF"; case .json: "JSON"; case .geojson: "GeoJSON"; case .gml: "GML"; case .image: "A picture"
        }
    }
}

/// `<dir>/<server>/<service>/<layer>.<ext>` in mono with Change and Reveal.
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
