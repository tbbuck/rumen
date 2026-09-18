import SwiftUI
import RumenKit

/// See the layer (SPEC §5.9): a caption that never pretends a sample is the layer, a source
/// picker, and the map drawn as a survey sheet with coordinates in its margins.
struct MapTab: View {
    @Bindable var session: MapSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Chip(text: chipText)
                if session.isLoading {
                    Text(loadingText).font(.sheetUI(12.5)).foregroundStyle(Palette.muted).lineLimit(1)
                    if let fraction = session.transfer?.fraction {
                        ProgressBar(fraction: fraction, height: 4).frame(width: 120)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    Text(session.caption).font(.sheetUI(12.5)).foregroundStyle(Palette.muted).lineLimit(2)
                }
                Spacer()
                SourceMenu(session: session)
                if session.source == .sample, !session.isRaster {
                    AsyncButton("Draw a fresh sample", busy: "Drawing…") { await session.load() }.buttonStyle(LinkButtonStyle(size: 12.5))
                }
            }
            if case .stored = session.source {
                HStack(spacing: 10) {
                    TextField("DuckDB where clause over the file, e.g. POP2000 > 100000", text: $session.storedWhere)
                        .textFieldStyle(SheetFieldStyle(mono: true))
                        .onSubmit { Task { await session.load() } }
                        .frame(maxWidth: 560)
                    AsyncButton("Apply", busy: "Applying…") { await session.load() }.buttonStyle(PrimaryButtonStyle(small: true))
                }
            }
            if let error = session.error { ErrorText(message: error) }
            SheetMap(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: session.layer.id) { await session.load() }
        .onChange(of: session.source) { Task { await session.load() } }
    }

    /// "Waiting for the server…" until the first byte, then a percentage when the length is
    /// trustworthy, otherwise the bytes so far.
    private var loadingText: String {
        guard let transfer = session.transfer else { return "Waiting for the server…" }
        let received = transfer.received.formatted(.byteCount(style: .file))
        if let expected = transfer.expected, let fraction = transfer.fraction {
            let total = expected.formatted(.byteCount(style: .file))
            return "Receiving… \(received) of \(total), \(Int((fraction * 100).rounded()))%"
        }
        return "Receiving… \(received)"
    }

    private var chipText: String {
        switch session.source {
        case .sample: session.isRaster ? session.service.type.name : "Sample"
        case .stored: "Stored"
        case .query: "Query preview"
        }
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
            .menuStyle(.button).buttonStyle(.borderless).fixedSize()
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
                GeoMapView(content: session.content, onViewport: { viewport in
                    session.viewportChanged(viewport)
                }, onFeature: { properties in
                    session.featureClicked(properties)
                }, tileFetcher: session.isRaster ? session.tileFetcher : nil)
                .frame(width: mapRect.width, height: mapRect.height)
                .offset(x: mapRect.minX, y: mapRect.minY)
                .clipped()
                Rectangle().stroke(Palette.line2, lineWidth: 1)
                    .frame(width: mapRect.width, height: mapRect.height)
                    .offset(x: mapRect.minX, y: mapRect.minY)
                    .allowsHitTesting(false)
                if let feature = session.selectedFeature {
                    FeatureInfoPanel(title: session.layer.name, rows: feature) { session.clearSelection() }
                        .offset(x: mapRect.minX + 10, y: mapRect.minY + 10)
                }
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

/// The clicked feature's attributes: a small sheet-styled card inside the map frame.
private struct FeatureInfoPanel: View {
    let title: String
    let rows: [(String, String)]
    let close: () -> Void
    @State private var closeHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title).font(.sheetUI(13, .bold)).foregroundStyle(Palette.ink).lineLimit(1)
                Spacer(minLength: 8)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(closeHovered ? Palette.ink : Palette.muted2)
                        .frame(width: 18, height: 18)
                        .background(closeHovered ? Palette.line : .clear, in: RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverTracking($closeHovered, hand: true)
                .accessibilityLabel("Close the feature panel")
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            Rectangle().fill(Palette.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(row.0).font(.sheetUI(11.5)).foregroundStyle(Palette.muted).frame(width: 110, alignment: .leading).lineLimit(1)
                            Text(row.1).font(.sheetMono(11.5)).foregroundStyle(row.1 == "NULL" ? Palette.muted2 : Palette.ink)
                                .lineLimit(2).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 4)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 260)
        }
        .frame(width: 300)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line2, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
    }
}
