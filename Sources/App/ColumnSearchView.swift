import SwiftUI
import AppKit
import ArcGISKit

/// Replaces the layer page while the search field has text (SPEC §5.8): options, results,
/// and a banner naming what the results cannot see. Double-click navigates and clears.
struct ColumnSearchResults: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Columns matching \u{201C}\(model.columnSearch)\u{201D}").font(.sheetDisplay(24)).foregroundStyle(Palette.ink).tracking(-0.24)
                Caption(summary)
            }
            HStack(spacing: 18) {
                Toggle("Match case", isOn: $model.search.caseSensitive).toggleStyle(.checkbox).font(.sheetUI(12.5))
                Toggle("Partial", isOn: $model.search.partial).toggleStyle(.checkbox).font(.sheetUI(12.5)).disabled(model.search.regex)
                Toggle("Regex", isOn: $model.search.regex).toggleStyle(.checkbox).font(.sheetUI(12.5))
                Toggle("Aliases too", isOn: $model.search.includeAlias).toggleStyle(.checkbox).font(.sheetUI(12.5))
                Picker("", selection: $model.searchAllServers) {
                    Text(model.currentServer?.friendlyName ?? "This server").tag(false)
                    Text("All servers").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().tint(Palette.accent)
                Spacer()
                Button("Clear") { model.columnSearch = "" }.buttonStyle(LinkButtonStyle(size: 12.5))
            }
            if model.searchUncrawled > 0 || model.searchFailedFolders > 0 {
                DeepCrawlPrompt(services: model.searchUncrawled, folders: model.searchFailedFolders, allServers: model.searchAllServers)
            }
            if let error = model.searchError {
                ErrorText(message: error)
            }
            // The table fills what is left of the page: columns are sized from their content, the
            // three text columns share any spare width, and the rows scroll.
            GeometryReader { proxy in
                let widths = SearchColumns.plan(hits: model.searchHits, available: proxy.size.width)
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        HStack(spacing: SearchColumns.gap) {
                            ForEach(Array(SearchColumns.titles.enumerated()), id: \.offset) { index, title in
                                Text(title).font(.sheetUI(11, .semibold)).foregroundStyle(Palette.muted)
                                    .frame(width: widths[index], alignment: .leading)
                            }
                        }
                        .padding(.horizontal, SearchColumns.inset)
                        .frame(height: 26)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .top) { Rectangle().fill(Palette.line2).frame(height: 1) }
                        ForEach(model.searchHits) { hit in
                            SearchHitRow(hit: hit, widths: widths)
                        }
                        if model.searchHits.isEmpty, model.searchError == nil {
                            Caption("No columns match.").frame(height: 27).padding(.horizontal, SearchColumns.inset)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.top, 22).padding(.horizontal, 36).padding(.bottom, 18)
        .onChange(of: model.search) { Task { await model.runColumnSearch() } }
        .onChange(of: model.searchAllServers) { Task { await model.runColumnSearch() } }
        .task(id: model.columnSearch) { await model.runColumnSearch() }
    }

    private var summary: String {
        let n = model.searchHits.count
        let scope = model.searchAllServers ? "every known server" : (model.currentServer?.friendlyName ?? "this server")
        return "\(n.grouped) column\(n == 1 ? "" : "s") in cached metadata on \(scope)\(n >= model.search.limit ? ", first \(model.search.limit.grouped) shown" : "")."
    }
}

/// Column widths for the results table, from the content: each column's natural width is its
/// widest cell (up to 300 rows measured) or its header, never below a floor; the three text
/// columns (field, layer, service) then share whatever width is spare in proportion, or give
/// it back the same way when the page is narrow. Narrow columns stop being mostly air, wide
/// ones get the room.
enum SearchColumns {
    static let titles = ["Field", "Layer", "Service", "Server", "Type", "Verdict"]
    static let gap: CGFloat = 14
    static let inset: CGFloat = 6
    private static let floors: [CGFloat] = [90, 120, 120, 80, 70, 90]
    private static let flexible: Set<Int> = [0, 1, 2]
    private static let cellPadding: CGFloat = 12

    static func plan(hits: [FieldSearchHit], available: CGFloat) -> [CGFloat] {
        let mono = SheetFonts.mono(size: 12, weight: 400) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        let ui = SheetFonts.ui(size: 12.5) ?? .systemFont(ofSize: 12.5)
        let kind = SheetFonts.ui(size: 9.5) ?? .systemFont(ofSize: 9.5)
        let alias = SheetFonts.ui(size: 11) ?? .systemFont(ofSize: 11)
        let header = SheetFonts.ui(size: 11, weight: 600) ?? .systemFont(ofSize: 11, weight: .semibold)
        var natural = titles.map { width(of: $0, font: header) }
        for hit in hits.prefix(300) {
            var field = width(of: hit.fieldName, font: mono)
            if hit.matchedAlias, let a = hit.alias { field += 6 + width(of: "alias \(a)", font: alias) }
            natural[0] = max(natural[0], field)
            natural[1] = max(natural[1], width(of: "\(hit.layerNumber) \(hit.layerName)", font: ui))
            natural[2] = max(natural[2], width(of: hit.serviceShortName, font: ui) + 6 + width(of: hit.serviceType.name, font: kind))
            natural[3] = max(natural[3], width(of: hit.serverName, font: ui))
            natural[4] = max(natural[4], width(of: hit.duckType, font: mono))
            natural[5] = max(natural[5], width(of: String(Verdict(hit.extractable).word.dropLast()), font: ui))
        }
        var widths = zip(natural, floors).map { max($0 + cellPadding, $1) }
        let usable = available - 2 * inset - gap * CGFloat(titles.count - 1)
        let total = widths.reduce(0, +)
        let flexibleTotal = flexible.reduce(CGFloat(0)) { $0 + widths[$1] }
        guard flexibleTotal > 0, usable.isFinite, usable > 0 else { return widths }
        let spare = usable - total
        for index in flexible {
            let share = spare * widths[index] / flexibleTotal
            widths[index] = max(floors[index], (widths[index] + share).rounded(.down))
        }
        return widths
    }

    nonisolated(unsafe) private static var cache: [String: CGFloat] = [:]

    private static func width(of text: String, font: NSFont) -> CGFloat {
        let key = "\(font.pointSize)|\(font.fontName)|\(text)"
        if let cached = cache[key] { return cached }
        let measured = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        if cache.count > 20_000 { cache.removeAll() }
        cache[key] = measured
        return measured
    }
}

private extension FieldSearchHit {
    var serviceShortName: String { serviceName.split(separator: "/").last.map(String.init) ?? serviceName }
}

private struct SearchHitRow: View {
    @Environment(AppModel.self) private var model
    let hit: FieldSearchHit
    let widths: [CGFloat]
    @State private var hovered = false

    var body: some View {
        HStack(spacing: SearchColumns.gap) {
            HStack(spacing: 6) {
                Text(hit.fieldName).font(.sheetMono(12)).foregroundStyle(Palette.ink).lineLimit(1)
                if hit.matchedAlias, let alias = hit.alias { Caption("alias \(alias)", size: 11, color: Palette.muted2).lineLimit(1) }
            }
            .frame(width: widths[0], alignment: .leading)
            Text("\(hit.layerNumber) \(hit.layerName)").font(.sheetUI(12.5)).foregroundStyle(Palette.ink).lineLimit(1)
                .truncationMode(.middle).frame(width: widths[1], alignment: .leading).help(hit.layerName)
            HStack(spacing: 6) {
                Text(hit.serviceShortName).font(.sheetUI(12.5)).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.middle)
                KindLabel(type: hit.serviceType)
            }
            .frame(width: widths[2], alignment: .leading).help(hit.serviceName)
            Text(hit.serverName).font(.sheetUI(12.5)).foregroundStyle(Palette.muted).lineLimit(1).frame(width: widths[3], alignment: .leading)
            Text(hit.duckType).font(.sheetMono(12)).foregroundStyle(Palette.ink).lineLimit(1).frame(width: widths[4], alignment: .leading)
            let verdict = Verdict(hit.extractable)
            Text(verdict.word.dropLast()).font(.sheetUI(12.5, .semibold)).foregroundStyle(verdict.color).frame(width: widths[5], alignment: .leading)
        }
        .padding(.horizontal, SearchColumns.inset)
        .frame(height: 27)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovered ? Palette.line.opacity(0.55) : .clear)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
        .contentShape(Rectangle())
        .hoverTracking($hovered, hand: true)
        .onTapGesture(count: 2) { Task { await model.navigate(toHit: hit) } }
        .help("Double-click to open \(hit.layerName)")
    }
}

/// "12 services on this server have not been crawled and 2 folders could not be listed, so
/// their columns cannot appear here, crawl them now."
private struct DeepCrawlPrompt: View {
    @Environment(AppModel.self) private var model
    let services: Int
    let folders: Int
    let allServers: Bool

    private var sentence: String {
        var parts = [String]()
        if services > 0 { parts.append("\(services.grouped) service\(services == 1 ? " has" : "s have") not been crawled") }
        if folders > 0 { parts.append("\(folders.grouped) folder\(folders == 1 ? "" : "s") could not be listed") }
        return parts.joined(separator: " and ") + (allServers ? " across your servers" : " on this server") + ", so their columns cannot appear here,"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(Palette.warn)
            Text(sentence)
                .font(.sheetUI(12.5)).foregroundStyle(Palette.ink)
            if !allServers {
                Button("crawl them now") { Task { await model.deepCrawlCurrentServer(); await model.runColumnSearch() } }
                    .buttonStyle(LinkButtonStyle(size: 12.5))
                    .disabled(model.deepCrawlStatus != nil)
                Text(".").font(.sheetUI(12.5)).foregroundStyle(Palette.ink)
            }
            if let status = model.deepCrawlStatus { Caption(status, size: 11.5, color: Palette.accent).lineLimit(1) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Palette.warnSoft, in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 1100, alignment: .leading)
    }
}
