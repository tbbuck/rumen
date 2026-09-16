import SwiftUI
import ArcGISKit

/// See the layer (SPEC §5.9): a caption that never pretends a sample is the layer, a source
/// picker, and the map drawn as a survey sheet with coordinates in its margins.
struct MapTab: View {
    @Bindable var session: MapSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Chip(text: chipText)
                Text(session.caption.isEmpty ? "Loading…" : session.caption).font(.sheetUI(12.5)).foregroundStyle(Palette.muted).lineLimit(2)
                if session.isLoading { ProgressView().controlSize(.small) }
                Spacer()
                SourceMenu(session: session)
                if session.source == .sample {
                    Button("Draw a fresh sample") { Task { await session.load() } }.buttonStyle(LinkButtonStyle(size: 12.5))
                }
            }
            if case .stored = session.source {
                HStack(spacing: 10) {
                    TextField("DuckDB where clause over the file, e.g. POP2000 > 100000", text: $session.storedWhere)
                        .textFieldStyle(SheetFieldStyle(mono: true))
                        .onSubmit { Task { await session.load() } }
                        .frame(maxWidth: 560)
                    Button("Apply") { Task { await session.load() } }.buttonStyle(PrimaryButtonStyle(small: true))
                }
            }
            if let error = session.error { ErrorText(message: error) }
            SheetMap(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: session.layer.id) { await session.load() }
        .onChange(of: session.source) { Task { await session.load() } }
    }

    private var chipText: String {
        switch session.source { case .sample: "Sample"; case .stored: "Stored"; case .query: "Query preview" }
    }
}

private struct SourceMenu: View {
    @Bindable var session: MapSession

    var body: some View {
        if session.storedRuns.isEmpty, !session.hasQueryPreview { EmptyView() } else {
            Menu {
                Button("Server sample") { session.source = .sample }
                if session.hasQueryPreview { Button("Query preview") { session.source = .query } }
                ForEach(session.storedRuns) { run in
                    Button("Stored file, \(Age.text(run.finishedAt))") { session.source = .stored(run.id) }
                }
            } label: {
                Text(label).font(.sheetUI(12.5))
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }

    private var label: String {
        switch session.source {
        case .sample: "Source: server sample"
        case .query: "Source: query preview"
        case .stored(let id): "Source: stored file\(session.storedRuns.first { $0.id == id }.map { ", \(Age.text($0.finishedAt))" } ?? "")"
        }
    }
}

/// The map as a survey sheet: a 1px frame, tick labels in the margins (eastings top and
/// bottom, northings rotated on the left), the graticule drawn by the map page in the same
/// spatial reference.
private struct SheetMap: View {
    let session: MapSession
    private let margins = EdgeInsets(top: 22, leading: 34, bottom: 26, trailing: 14)

    var body: some View {
        GeometryReader { proxy in
            let mapRect = CGRect(x: margins.leading, y: margins.top,
                                 width: max(0, proxy.size.width - margins.leading - margins.trailing),
                                 height: max(0, proxy.size.height - margins.top - margins.bottom))
            ZStack(alignment: .topLeading) {
                Palette.bg
                GeoMapView(content: session.content) { viewport in
                    session.viewportChanged(viewport)
                }
                .frame(width: mapRect.width, height: mapRect.height)
                .offset(x: mapRect.minX, y: mapRect.minY)
                .clipped()
                Rectangle().stroke(Palette.line2, lineWidth: 1)
                    .frame(width: mapRect.width, height: mapRect.height)
                    .offset(x: mapRect.minX, y: mapRect.minY)
                    .allowsHitTesting(false)
                if let g = session.graticule {
                    ForEach(Array(g.xTicks.enumerated()), id: \.offset) { _, tick in
                        let x = mapRect.minX + tick.position
                        if x >= mapRect.minX, x <= mapRect.maxX {
                            TickLabel(text: tick.label).position(x: x, y: margins.top / 2)
                            TickLabel(text: tick.label).position(x: x, y: mapRect.maxY + margins.bottom / 2)
                        }
                    }
                    ForEach(Array(g.yTicks.enumerated()), id: \.offset) { _, tick in
                        let y = mapRect.minY + tick.position
                        if y >= mapRect.minY, y <= mapRect.maxY {
                            TickLabel(text: tick.label).rotationEffect(.degrees(-90)).position(x: margins.leading / 2, y: y)
                        }
                    }
                }
            }
        }
        .frame(minHeight: 320)
    }
}

/// Map marginalia only, never UI: Fira Code 8.5 muted2.
private struct TickLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.sheetMono(8.5)).foregroundStyle(Palette.muted2).fixedSize()
    }
}
