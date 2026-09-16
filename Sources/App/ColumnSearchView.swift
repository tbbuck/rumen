import SwiftUI
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
            if model.searchUncrawled > 0 {
                DeepCrawlPrompt(count: model.searchUncrawled, allServers: model.searchAllServers)
            }
            if let error = model.searchError {
                ErrorText(message: error)
            }
            ScrollView([.vertical, .horizontal]) {
                VStack(spacing: 0) {
                    HStack(spacing: 14) {
                        header("Field", 170); header("Layer", 170); header("Service", 150); header("Server", 110); header("Type", 80)
                        Text("Verdict").font(.sheetUI(11, .semibold)).foregroundStyle(Palette.muted).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 26)
                    .overlay(alignment: .top) { Rectangle().fill(Palette.line2).frame(height: 1) }
                    ForEach(model.searchHits) { hit in
                        SearchHitRow(hit: hit)
                    }
                    if model.searchHits.isEmpty, model.searchError == nil {
                        Caption("No columns match.").frame(height: 27)
                    }
                }
                .frame(minWidth: 760, maxWidth: 1100, alignment: .leading)
            }
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

    private func header(_ text: String, _ width: CGFloat) -> some View {
        Text(text).font(.sheetUI(11, .semibold)).foregroundStyle(Palette.muted).frame(width: width, alignment: .leading)
    }
}

private struct SearchHitRow: View {
    @Environment(AppModel.self) private var model
    let hit: FieldSearchHit
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Text(hit.fieldName).font(.sheetMono(12)).foregroundStyle(Palette.ink).lineLimit(1)
                if hit.matchedAlias, let alias = hit.alias { Caption("alias \(alias)", size: 11, color: Palette.muted2).lineLimit(1) }
            }
            .frame(width: 170, alignment: .leading)
            Text("\(hit.layerNumber) \(hit.layerName)").font(.sheetUI(12.5)).foregroundStyle(Palette.ink).lineLimit(1).frame(width: 170, alignment: .leading)
            HStack(spacing: 6) {
                Text(hit.serviceName.split(separator: "/").last.map(String.init) ?? hit.serviceName).font(.sheetUI(12.5)).foregroundStyle(Palette.ink).lineLimit(1)
                KindLabel(type: hit.serviceType)
            }
            .frame(width: 150, alignment: .leading)
            Text(hit.serverName).font(.sheetUI(12.5)).foregroundStyle(Palette.muted).lineLimit(1).frame(width: 110, alignment: .leading)
            Text(hit.duckType).font(.sheetMono(12)).foregroundStyle(Palette.ink).lineLimit(1).frame(width: 80, alignment: .leading)
            let verdict = Verdict(hit.extractable)
            Text(verdict.word.dropLast()).font(.sheetUI(12.5, .semibold)).foregroundStyle(verdict.color).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 27)
        .background(hovered ? Palette.line.opacity(0.55) : .clear)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
        .contentShape(Rectangle())
        .hoverTracking($hovered, hand: true)
        .onTapGesture(count: 2) { Task { await model.navigate(toHit: hit) } }
        .help("Double-click to open \(hit.layerName)")
    }
}

/// "12 services on this server have not been crawled, crawl them now."
private struct DeepCrawlPrompt: View {
    @Environment(AppModel.self) private var model
    let count: Int
    let allServers: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(Palette.warn)
            Text("\(count.grouped) service\(count == 1 ? "" : "s") \(allServers ? "across your servers have" : "on this server \(count == 1 ? "has" : "have")") not been crawled, so their columns cannot appear here,")
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
