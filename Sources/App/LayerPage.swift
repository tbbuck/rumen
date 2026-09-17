import SwiftUI
import ArcGISKit

/// The layer as a document: header, seven tabs, and the active tab. Overview, Fields, and
/// Download scroll as a page; Query, Stored, Map, and Raw fill the height with their own
/// scrolling content.
struct LayerPage: View {
    @Environment(AppModel.self) private var model
    let layer: LayerRecord
    let service: ServiceRecord
    let fields: [FieldRecord]

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            LayerHeader(layer: layer, service: service)
            LayerTabs(selection: $model.layerTab)
            if model.layerTab == .query, let session = model.querySession {
                QueryTab(session: session)
                    .padding(.bottom, 18)
            } else if model.layerTab == .map, let session = model.mapSession {
                MapTab(session: session)
                    .padding(.bottom, 18)
                    .onAppear { model.syncMapSources() }
            } else if model.layerTab == .stored, let session = model.storedSession {
                StoredTab(session: session)
                    .padding(.bottom, 18)
            } else if model.layerTab == .raw {
                RawJSONView()
                    .padding(.bottom, 18)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch model.layerTab {
                        case .overview: OverviewTab(layer: layer, service: service, fields: fields)
                        case .fields: FieldsTab(fields: fields)
                        case .raw: Caption("Loading…")
                        case .query: Caption("Loading…")
                        case .download: DownloadTab(layer: layer, service: service)
                        case .stored: Caption("Loading…")
                        case .map: Caption("Loading…")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 24)
                }
            }
        }
        .padding(.top, 22).padding(.horizontal, 36)
    }
}

private struct Pending: View {
    let text: String
    var body: some View { Caption(text) }
}

/// Name (24/700) + "Layer 3 in LLPG (MapServer), Property folder. Cached 14 minutes ago, refresh."
private struct LayerHeader: View {
    @Environment(AppModel.self) private var model
    let layer: LayerRecord
    let service: ServiceRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(layer.name).font(.sheetDisplay(24)).foregroundStyle(Palette.ink).tracking(-0.24)
            HStack(spacing: 4) {
                Caption(subtitle)
                Button("refresh") { Task { await model.refreshCurrent() } }.buttonStyle(LinkButtonStyle(size: 12.5))
                Caption(".")
            }
        }
    }

    private var subtitle: String {
        let what = layer.isTable ? "Table" : "Layer"
        let folder = service.folderPath.isEmpty ? "" : ", \(service.folderPath) folder"
        return "\(what) \(layer.layerID) in \(service.shortName) (\(service.type.name))\(folder). Cached \(Age.text(layer.fetchedAt)),"
    }
}

/// Overview · Fields · Query · Download · Stored · Map · Raw as underlined text tabs.
private struct LayerTabs: View {
    @Binding var selection: LayerTab

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                ForEach(LayerTab.allCases) { tab in
                    TabButton(tab: tab, isOn: selection == tab) { selection = tab }
                }
                Spacer()
            }
            Rectangle().fill(Palette.line).frame(height: 1)
        }
    }
}

// MARK: - Overview

private struct OverviewTab: View {
    let layer: LayerRecord
    let service: ServiceRecord
    let fields: [FieldRecord]

    var body: some View {
        ExtractionStatement(layer: layer)
        FactGrid(rows: facts)
        SectionHeading("Fields")
        FieldsTable(fields: fields)
    }

    private var facts: [(String, String, Bool)] {
        let sr = layer.effectiveWkid.map { "\(srName($0)) (\($0))" } ?? "unknown spatial reference"
        let geometry = layer.isTable ? "None, a table" : "\(geometryName(layer.geometryType)), \(sr)"
        let native = layer.nativeExtent.map { e -> String in
            let geographic = abs(e.xmin) <= 180 && abs(e.xmax) <= 180 && abs(e.ymin) <= 90 && abs(e.ymax) <= 90
            let p = geographic ? 3 : 0
            return "\(fmt(e.xmin, p)) \(fmt(e.ymin, p)) to \(fmt(e.xmax, p)) \(fmt(e.ymax, p))"
        } ?? "—"
        let wgs = layer.extentWGS84.map { "\(fmt($0.minX, 3)) \(fmt($0.minY, 3)) to \(fmt($0.maxX, 3)) \(fmt($0.maxY, 3))" } ?? "—"
        let zm: String = {
            switch (layer.hasZ ?? false, layer.hasM ?? false) {
            case (true, true): return "Z and M"
            case (true, false): return "Z only"
            case (false, true): return "M only"
            default: return "Neither"
            }
        }()
        let count = layer.featureCount.map { "\($0.grouped), counted \(Age.text(layer.featureCountAt))" } ?? "Not counted yet"
        var paging = [String]()
        if layer.supportsPagination == true { paging.append("Offset paging") }
        if layer.supportsOrderBy == true { paging.append("order by") }
        if layer.supportsStatistics == true { paging.append("statistics") }
        return [
            ("Geometry", geometry, false),
            ("Object ID field", layer.objectIdField ?? "—", true),
            ("Extent, native", native, true),
            ("Global ID field", layer.globalIdField ?? "—", true),
            ("Extent, WGS 84", wgs, true),
            ("Z and M values", zm, false),
            ("Feature count", count, false),
            ("Attachments", layer.hasAttachments == true ? "Yes" : "None", false),
            ("Max record count", layer.maxRecordCount?.grouped ?? "—", false),
            ("Query formats", layer.supportedQueryFormats ?? "—", false),
            ("Capabilities", layer.capabilities.map { Capabilities.parse($0).sorted().joined(separator: ", ") } ?? "—", false),
            ("Paging", paging.isEmpty ? "None advertised" : paging.joined(separator: ", ").capitalizedFirst, false),
            ("FeatureServer twin", layer.siblingLayerID != nil ? "Yes, used as the download source" : (service.type == .mapServer ? "None found" : "Not applicable"), false),
            ("Layer type", layer.type ?? "—", false),
        ]
    }

    private func fmt(_ v: Double, _ places: Int = 0) -> String {
        v.formatted(.number.precision(.fractionLength(0...places)).grouping(.never))
    }
}

/// One sentence, the verdict word first, then how, then the count (or the offer to count).
/// Below it: one primary action and two links (UI-SPEC: PrimaryActions).
private struct ExtractionStatement: View {
    @Environment(AppModel.self) private var model
    let layer: LayerRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("\(Text(verdict.word).font(.sheetUI(15, .bold)).foregroundStyle(verdict.color)) \(detail)")
                    .font(.sheetUI(15))
                    .foregroundStyle(Palette.ink)
                    .lineSpacing(4)
                if model.isAssessing {
                    ProgressView().controlSize(.mini)
                } else if verdict != .notExtractable, layer.featureCount == nil {
                    if model.probing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button("count now") { Task { await model.probeCurrentLayer() } }.buttonStyle(LinkButtonStyle(size: 15))
                        Text(".").font(.sheetUI(15)).foregroundStyle(Palette.ink)
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            if let error = model.probeError {
                ErrorText(message: error)
            }
            HStack(spacing: 18) {
                if verdict == .extractable {
                    Button("Download as GeoParquet") { Task { await model.downloadCurrentLayerWithDefaults() } }
                        .buttonStyle(PrimaryButtonStyle())
                        .help("Every feature, in the native spatial reference, to \(model.downloadDirectory.lastPathComponent)")
                    Button("Change format or spatial reference") { model.layerTab = .download }.buttonStyle(LinkButtonStyle())
                    Button("Preview a sample on the map") { model.layerTab = .map }.buttonStyle(LinkButtonStyle())
                } else if verdict == .notExtractable, let twin = layer.siblingLayerID {
                    Button("Use the FeatureServer twin") { Task { await model.select(.layer(twin)) } }.buttonStyle(LinkButtonStyle())
                }
            }
        }
    }

    private var verdict: Verdict { Verdict(layer.extractable) }

    /// The stored reason (the rules' "how" sentence or the server's refusal), plus the count
    /// sentence when the count is known and the assessment gives a page size.
    private var detail: String {
        var text = layer.extractableReason ?? ""
        if text.isEmpty {
            text = verdict == .unknown ? "The layer definition has not been fetched yet." : ""
        }
        if verdict == .extractable, let count = layer.featureCount {
            let sentence = model.assessment?.countSentence(features: count)
                ?? "\(count.grouped) features, counted \(Age.text(layer.featureCountAt))."
            text += " " + sentence
        } else if verdict != .notExtractable {
            text += " Count not probed yet, "
        }
        return text
    }
}

// MARK: - Fields

private struct FieldsTab: View {
    let fields: [FieldRecord]
    @State private var filter = ""

    var body: some View {
        TextField("Filter fields", text: $filter)
            .textFieldStyle(SheetFieldStyle())
            .frame(width: 260)
        FieldsTable(fields: filtered)
    }

    private var filtered: [FieldRecord] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return fields }
        return fields.filter { $0.name.localizedCaseInsensitiveContains(q) || ($0.alias ?? "").localizedCaseInsensitiveContains(q) }
    }
}

/// Name · Alias · Esri type · DuckDB type · Domain, as rows with hairline rules.
struct FieldsTable: View {
    let fields: [FieldRecord]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                header("Name", 160); header("Alias", 150); header("Esri type", 130); header("DuckDB type", 100)
                Text("Domain").font(.sheetUI(11, .semibold)).foregroundStyle(Palette.muted).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 26)
            .overlay(alignment: .top) { Rectangle().fill(Palette.line2).frame(height: 1) }
            if fields.isEmpty {
                Caption("No fields cached for this layer.").frame(height: 27)
            }
            ForEach(fields) { field in
                HStack(spacing: 14) {
                    cell(field.name, 160, mono: true)
                    cell(field.alias ?? "", 150, mono: false)
                    cell(field.shortEsriType, 130, mono: true)
                    cell(field.duckType == "SKIP" ? "skipped" : field.duckType, 100, mono: true)
                    Text(domain(field)).font(.sheetUI(12.5)).foregroundStyle(Palette.muted)
                        .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                        .help(domain(field))
                }
                .frame(height: 27)
                .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
            }
        }
        .frame(maxWidth: 880)
    }

    private func header(_ text: String, _ width: CGFloat) -> some View {
        Text(text).font(.sheetUI(11, .semibold)).foregroundStyle(Palette.muted).frame(width: width, alignment: .leading)
    }

    private func cell(_ text: String, _ width: CGFloat, mono: Bool) -> some View {
        Text(text).font(mono ? .sheetMono(12) : .sheetUI(12.5)).foregroundStyle(Palette.ink)
            .lineLimit(1).truncationMode(.tail).frame(width: width, alignment: .leading)
            .textSelection(.enabled)
    }

    private func domain(_ field: FieldRecord) -> String {
        if field.esriType == .geometry { return "Written as WKB on export" }
        return field.codedValuesSummary ?? ""
    }
}

// MARK: - Raw

/// The layer JSON the server sent, pretty-printed, with Copy.
private struct RawJSONView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Caption("The layer definition exactly as the server sent it, pretty-printed.")
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.currentRawJSON ?? "", forType: .string)
                }
                .buttonStyle(LinkButtonStyle(size: 12.5))
            }
            if let raw = model.currentRawJSON {
                RawTextView(text: raw)
                    .frame(minHeight: 320, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line, lineWidth: 1))
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: model.currentLayer?.id) { await model.loadRawJSON() }
    }
}

// MARK: - Naming helpers

func geometryName(_ esri: String?) -> String {
    switch esri {
    case "esriGeometryPoint": return "Point"
    case "esriGeometryMultipoint": return "Multipoint"
    case "esriGeometryPolyline": return "Polyline"
    case "esriGeometryPolygon": return "Polygon"
    case "esriGeometryEnvelope": return "Envelope"
    case "esriGeometryMultiPatch": return "Multipatch"
    case nil: return "None"
    default: return esri!
    }
}

/// Well-known spatial reference names; anything else is shown by id alone.
func srName(_ wkid: Int) -> String {
    switch wkid {
    case 4326: return "WGS 84"
    case 3857, 102100: return "Web Mercator"
    case 27700: return "British National Grid"
    case 4269: return "NAD 1983"
    case 4258: return "ETRS89"
    case 2157: return "Irish Transverse Mercator"
    case 29902: return "Irish Grid"
    default: return "EPSG"
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// One text tab: muted, ink on hover, ink with a 2px accent underline when active.
private struct TabButton: View {
    let tab: LayerTab
    let isOn: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(tab.rawValue)
                .font(.sheetUI(13, .medium))
                .foregroundStyle(isOn || hovered ? Palette.ink : Palette.muted)
                .padding(.bottom, 8)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(isOn ? Palette.accent : (hovered ? Palette.line2 : .clear)).frame(height: 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverTracking($hovered, hand: !isOn)
    }
}
