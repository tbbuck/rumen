import SwiftUI
import RumenKit

/// Read-only poking at a layer before a download (SPEC §5.5): where, fields, spatial
/// reference, order, geometry; Count · Extent · Preview · Distinct · Statistics; the grid;
/// per-layer history.
struct QueryTab: View {
    @Bindable var session: QuerySession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WhereEditor(text: $session.whereClause)
            HStack(spacing: 14) {
                OutFieldsPicker(session: session)
                Picker("", selection: $session.spatialReference) {
                    Text(nativeLabel).tag(QuerySession.SpatialReferenceChoice.native)
                    Text("WGS 84").tag(QuerySession.SpatialReferenceChoice.wgs84)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().tint(Palette.accent)
                OrderByPicker(session: session)
                Toggle("Geometry", isOn: $session.returnGeometry)
                    .toggleStyle(.checkbox).font(.sheetUI(12.5))
                    .disabled(session.layer.isTable)
                Spacer()
            }
            QueryActions(session: session)
            if let error = session.error {
                ErrorText(message: error)
            }
            ResultPane(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            QueryHistoryList(session: session)
        }
        .task(id: session.layer.id) { await session.loadHistory() }
    }

    private var nativeLabel: String {
        session.layer.effectiveWkid.map { "Native (\($0))" } ?? "Native"
    }
}

/// The where clause, mono, three lines.
private struct WhereEditor: View {
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Caption("Where")
            TextEditor(text: $text).accessibilityLabel("Where clause")
                .font(.sheetMono(12.5))
                .foregroundStyle(Palette.ink)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .frame(height: 64)
                .background(Palette.bg, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.line2, lineWidth: 1))
                .frame(maxWidth: 720)
        }
    }
}

/// "Fields: all" menu with a toggle per field.
private struct OutFieldsPicker: View {
    @Bindable var session: QuerySession

    var body: some View {
        NativeMenu(title: label, items: [.init("All fields", checked: session.outFields == nil) { session.outFields = nil }, .separator]
            + session.fields.map { field in .init(field.name, checked: isOn(field.name)) { toggle(field.name) } })
        .inline()
        .hoverLabel()
    }

    private var label: String {
        guard let out = session.outFields else { return "Fields: all" }
        return "Fields: \(out.count) of \(session.fields.count)"
    }

    private func isOn(_ name: String) -> Bool { session.outFields?.contains(name) ?? true }

    private func toggle(_ name: String) {
        var set = session.outFields ?? Set(session.fields.map(\.name))
        if set.contains(name) { set.remove(name) } else { set.insert(name) }
        session.outFields = set.count == session.fields.count ? nil : set
    }
}

/// "Order: none" menu with a field per item and a direction toggle.
private struct OrderByPicker: View {
    @Bindable var session: QuerySession

    var body: some View {
        NativeMenu(title: label, items: [.init("No order", checked: session.orderByField == nil) { session.orderByField = nil }, .separator]
            + session.fields.map { field in .init(field.name, checked: session.orderByField == field.name) { session.orderByField = field.name } }
            + [.separator, .init("Ascending", checked: session.orderAscending) { session.orderAscending = true },
               .init("Descending", checked: !session.orderAscending) { session.orderAscending = false }])
        .inline()
        .hoverLabel()
        .disabled(session.canOrderBy != nil)
        .help(session.canOrderBy ?? "Order the results by a field")
    }

    private var label: String {
        guard let field = session.orderByField else { return "Order: none" }
        return "Order: \(field) \(session.orderAscending ? "↑" : "↓")"
    }
}

/// Count · Extent · Preview · Distinct · Statistics, each disabled with a reason when the
/// layer lacks the capability; Next page when there is one.
private struct QueryActions: View {
    @Bindable var session: QuerySession

    var body: some View {
        HStack(spacing: 18) {
            AsyncButton("Preview", busy: "Running…") { await session.preview() }.buttonStyle(PrimaryButtonStyle(small: true))
            AsyncButton("Count", busy: "Counting…") { await session.count() }.buttonStyle(LinkButtonStyle())
            AsyncButton("Extent", busy: "Measuring…") { await session.extent() }.buttonStyle(LinkButtonStyle())
                .disabled(session.canExtent != nil).help(session.canExtent ?? "The bounding box of the matching features")
            NativeMenu(title: "Distinct", size: 13, color: session.canDistinct == nil ? NSPalette.accent : NSPalette.muted2,
                       items: session.fields.map { field in .init(field.name) { Task { await session.distinct(field: field.name) } } })
            .inline().hoverLabel()
            .disabled(session.canDistinct != nil).help(session.canDistinct ?? "Distinct values of one field")
            AsyncButton("Statistics", busy: "Summarising…") { await session.statistics() }.buttonStyle(LinkButtonStyle())
                .disabled(session.canStatistics != nil).help(session.canStatistics ?? "Min, max, mean, count of every numeric and date field")
            if session.isRunning {
                ProgressView().controlSize(.small)
            }
            Spacer()
            if session.canPageForward {
                AsyncButton("Next page", busy: "Loading…") { await session.nextPage() }.buttonStyle(LinkButtonStyle())
            }
        }
        .disabled(session.isRunning)
    }
}

/// The result: a count line, an extent, or the grid with its caption.
private struct ResultPane: View {
    let session: QuerySession

    var body: some View {
        switch session.result {
        case .none:
            VStack(alignment: .leading, spacing: 6) {
                Caption("Nothing run yet. Preview fetches the first \(session.pageSize.grouped) features; Count and Extent ask the server without fetching any.")
                if let reason = session.canPaginate { Caption(reason, size: 11.5, color: Palette.muted2) }
            }
            .frame(maxWidth: 720, alignment: .leading)
        case .count(let n):
            Text("\(n.grouped) feature\(n == 1 ? "" : "s") match.").font(.sheetUI(15)).foregroundStyle(Palette.ink)
        case .extent(let e):
            VStack(alignment: .leading, spacing: 6) {
                Text("Extent of the matching features").font(.sheetUI(13.5, .bold)).foregroundStyle(Palette.ink)
                if e.isEmpty {
                    Caption("Empty: no features match.")
                } else {
                    Text("\(fmt(e.xmin!)) \(fmt(e.ymin!)) to \(fmt(e.xmax!)) \(fmt(e.ymax!))")
                        .font(.sheetMono(12.5)).foregroundStyle(Palette.ink).textSelection(.enabled)
                    Caption(e.spatialReference?.effectiveWkid.map { "Spatial reference \($0)" } ?? "Native spatial reference")
                }
            }
        case .grid(let grid, let caption):
            VStack(alignment: .leading, spacing: 8) {
                Caption(caption)
                if grid.columns.isEmpty {
                    EmptyView()
                } else {
                    ResultsGrid(grid: grid)
                        .frame(minHeight: 200, maxHeight: .infinity)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line2, lineWidth: 1))
                }
            }
        }
    }

    private func fmt(_ v: Double) -> String {
        let geographic = abs(v) <= 180
        return v.formatted(.number.precision(.fractionLength(0...(geographic ? 4 : 1))).grouping(.never))
    }
}

/// Past queries against this layer; click restores the where clause and fields.
private struct QueryHistoryList: View {
    let session: QuerySession
    @State private var expanded = false

    var body: some View {
        if !session.history.isEmpty {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.muted2)
                    Text("History, \(session.history.count.grouped) quer\(session.history.count == 1 ? "y" : "ies")")
                        .font(.sheetUI(12.5, .semibold)).foregroundStyle(Palette.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverLabel()
            if expanded {
                VStack(spacing: 0) {
                    ForEach(session.history.prefix(12)) { record in
                        Button {
                            session.restore(record)
                        } label: {
                            HStack(spacing: 12) {
                                Text(record.whereClause).font(.sheetMono(11.5)).foregroundStyle(Palette.ink).lineLimit(1)
                                Text(record.outFields ?? "*").font(.sheetMono(11)).foregroundStyle(Palette.muted2).lineLimit(1)
                                Spacer()
                                if let count = record.count { Caption("\(count.grouped) features", size: 11) }
                                if let ms = record.durationMillis { Caption("\(ms) ms", size: 11, color: Palette.muted2) }
                                Caption(Age.text(record.ranAt), size: 11, color: Palette.muted2)
                            }
                            .frame(height: 24)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Rectangle().fill(Palette.line).frame(height: 1)
                    }
                }
            }
        }
    }
}
