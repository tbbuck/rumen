import SwiftUI
import WebKit
import ArcGISKit

/// What the map shows: the layer's extent (dashed), features (sample, stored, or query), and
/// the graticule the sheet margins are labelled against. `fitToken` bumps to re-fit.
struct MapContent: Equatable {
    var extent: BoundingBox?
    var featuresGeoJSON: String?
    var graticuleGeoJSON: String?
    var fit: BoundingBox?
    var fitToken = 0
}

/// MapLibre GL (MapTiler basemaps by appearance) in a `WKWebView`, fed GeoJSON and reporting
/// its viewport back for the sheet margins — the same mechanism as DuckLake Explorer.
struct GeoMapView: NSViewRepresentable {
    let content: MapContent
    let onViewport: (MapViewport) -> Void
    var onFeature: ([String: String]?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(onViewport: onViewport, onFeature: onFeature) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "viewport")
        configuration.userContentController.add(context.coordinator, name: "feature")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        let style = Self.styleName(for: context.environment.colorScheme)
        context.coordinator.style = style
        context.coordinator.webView = webView
        webView.loadHTMLString(Self.page(style: style), baseURL: URL(string: "https://tiles.local/"))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let style = Self.styleName(for: context.environment.colorScheme)
        if style != context.coordinator.style {
            context.coordinator.style = style
            context.coordinator.reload(Self.page(style: style))
        }
        context.coordinator.apply(content)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "viewport")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "feature")
    }

    static func styleName(for scheme: ColorScheme) -> String { scheme == .dark ? "dataviz-dark" : "dataviz" }

    private static func page(style: String) -> String {
        let dark = style.hasSuffix("dark")
        return html
            .replacingOccurrences(of: "__MAPTILER_KEY__", with: MapConfig.maptilerKey)
            .replacingOccurrences(of: "__MAP_STYLE__", with: style)
            .replacingOccurrences(of: "__ACCENT__", with: dark ? "#EA6AA6" : "#B8236B")
            .replacingOccurrences(of: "__GRAT__", with: dark ? "#34506A" : "#C5D3E2")
            .replacingOccurrences(of: "__BG__", with: dark ? "#1A2128" : "#F2F4F0")
            .replacingOccurrences(of: "__PANEL__", with: dark ? "#212930" : "#FAFBF8")
            .replacingOccurrences(of: "__LINE2__", with: dark ? "#445362" : "#BEC5BA")
            .replacingOccurrences(of: "__INK__", with: dark ? "#E7EAE6" : "#222A26")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var style = "dataviz"
        private let onViewport: (MapViewport) -> Void
        private let onFeature: ([String: String]?) -> Void
        private var loaded = false
        private var pending: MapContent?
        private var applied = MapContent()

        init(onViewport: @escaping (MapViewport) -> Void, onFeature: @escaping ([String: String]?) -> Void) {
            self.onViewport = onViewport
            self.onFeature = onFeature
        }

        func reload(_ html: String) {
            loaded = false
            applied = MapContent()
            webView?.loadHTMLString(html, baseURL: URL(string: "https://tiles.local/"))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            if let pending { apply(pending, force: true) }
        }

        /// Injects only what changed since the last apply.
        func apply(_ content: MapContent, force: Bool = false) {
            pending = content
            guard loaded, let webView else { return }
            if force || content.extent != applied.extent {
                let fc = content.extent.map { GeoJSON.featureCollection([#"{"type":"Feature","properties":{},"geometry":\#(GeoJSON.box($0))}"#]) }
                    ?? GeoJSON.featureCollection([])
                webView.evaluateJavaScript("window.setExtent(\(fc));")
            }
            if force || content.featuresGeoJSON != applied.featuresGeoJSON {
                webView.evaluateJavaScript("window.setFeatures(\(content.featuresGeoJSON ?? GeoJSON.featureCollection([])));")
            }
            if force || content.graticuleGeoJSON != applied.graticuleGeoJSON {
                webView.evaluateJavaScript("window.setGraticule(\(content.graticuleGeoJSON ?? GeoJSON.featureCollection([])));")
            }
            if let fit = content.fit, force || content.fitToken != applied.fitToken || content.fit != applied.fit {
                webView.evaluateJavaScript("window.fitTo([[\(fit.minX),\(fit.minY)],[\(fit.maxX),\(fit.maxY)]]);")
            }
            applied = content
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "feature" {
                if let dict = message.body as? [String: Any] {
                    var properties = [String: String]()
                    for (key, value) in dict { properties[key] = value is NSNull ? "NULL" : "\(value)" }
                    onFeature(properties)
                } else {
                    onFeature(nil)
                }
                return
            }
            guard message.name == "viewport", let dict = message.body as? [String: Any],
                  let west = dict["west"] as? Double, let south = dict["south"] as? Double,
                  let east = dict["east"] as? Double, let north = dict["north"] as? Double,
                  let width = dict["width"] as? Double, let height = dict["height"] as? Double else { return }
            let zoom = dict["zoom"] as? Double ?? 0
            onViewport(MapViewport(west: west, south: south, east: east, north: north, width: width, height: height, zoom: zoom))
        }
    }

    private static let html = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <script src="https://unpkg.com/maplibre-gl@4.7.1/dist/maplibre-gl.js"></script>
    <link href="https://unpkg.com/maplibre-gl@4.7.1/dist/maplibre-gl.css" rel="stylesheet">
    <style>
      html,body,#map{margin:0;height:100%;width:100%;background:__BG__}
      .maplibregl-ctrl-group{background:__PANEL__;border:1px solid __LINE2__;border-radius:6px;box-shadow:none}
      .maplibregl-ctrl-group button{width:26px;height:26px}
      .maplibregl-ctrl-group button+button{border-top:1px solid __LINE2__}
      .maplibregl-ctrl button .maplibregl-ctrl-icon{filter:none}
      #nokey{position:absolute;left:10px;bottom:10px;font:11px Cabin,sans-serif;color:__INK__;background:__PANEL__;padding:4px 8px;border:1px solid __LINE2__;border-radius:6px;display:none}
    </style>
    </head><body><div id="map"></div><div id="nokey">No MapTiler key: basemap tiles are off. See Config/maptiler.xcconfig.</div><script>
    const ACCENT = '__ACCENT__', GRAT = '__GRAT__';
    const KEY = '__MAPTILER_KEY__';
    if (!KEY) { document.getElementById('nokey').style.display = 'block'; }
    const map = new maplibregl.Map({
      container: 'map',
      style: KEY ? 'https://api.maptiler.com/maps/__MAP_STYLE__/style.json?key=' + KEY
                 : { version: 8, sources: {}, layers: [{ id: 'bg', type: 'background', paint: { 'background-color': '__BG__' } }] },
      center: [-2.2, 54.2], zoom: 4.4, attributionControl: false
    });
    map.addControl(new maplibregl.NavigationControl({showCompass:false}), 'top-right');
    function empty() { return {type:'FeatureCollection', features:[]}; }
    function addLayers() {
      map.addSource('grat', { type:'geojson', data: empty() });
      map.addLayer({ id:'grat-line', type:'line', source:'grat', paint:{ 'line-color': GRAT, 'line-width': 1, 'line-opacity': 0.9 } });
      map.addSource('features', { type:'geojson', data: empty() });
      map.addLayer({ id:'f-fill', type:'fill', source:'features', filter:['==','$type','Polygon'], paint:{ 'fill-color': ACCENT, 'fill-opacity': 0.18 } });
      map.addLayer({ id:'f-line', type:'line', source:'features', filter:['any',['==','$type','Polygon'],['==','$type','LineString']], paint:{ 'line-color': ACCENT, 'line-width': 1.2 } });
      map.addLayer({ id:'f-pt', type:'circle', source:'features', filter:['==','$type','Point'], paint:{ 'circle-color': ACCENT, 'circle-radius': 4, 'circle-stroke-color': '#ffffff', 'circle-stroke-width': 1 } });
      map.addSource('extent', { type:'geojson', data: empty() });
      map.addLayer({ id:'extent-line', type:'line', source:'extent', paint:{ 'line-color': ACCENT, 'line-width': 1.5, 'line-dasharray': [3, 2] } });
    }
    function post() {
      const b = map.getBounds(); const c = map.getCanvas();
      const r = c.getBoundingClientRect();
      window.webkit.messageHandlers.viewport.postMessage({ west: b.getWest(), south: b.getSouth(), east: b.getEast(), north: b.getNorth(), width: r.width, height: r.height, zoom: map.getZoom() });
    }
    const HIT = ['f-fill', 'f-line', 'f-pt'];
    map.on('load', () => {
      addLayers(); post();
      for (const id of HIT) {
        map.on('mouseenter', id, () => { map.getCanvas().style.cursor = 'pointer'; });
        map.on('mouseleave', id, () => { map.getCanvas().style.cursor = ''; });
      }
      map.on('click', e => {
        const hits = map.queryRenderedFeatures(e.point, { layers: HIT });
        if (hits.length) {
          const p = Object.assign({}, hits[0].properties);
          p.__geometry = hits[0].geometry.type;
          window.webkit.messageHandlers.feature.postMessage(p);
        } else {
          window.webkit.messageHandlers.feature.postMessage(null);
        }
      });
    });
    map.on('moveend', post);
    map.on('resize', post);
    function whenReady(fn) { if (map.isStyleLoaded() && map.getSource('features')) fn(); else map.once('load', fn); }
    window.setGraticule = fc => whenReady(() => map.getSource('grat').setData(fc));
    window.setFeatures = fc => whenReady(() => map.getSource('features').setData(fc));
    window.setExtent = fc => whenReady(() => map.getSource('extent').setData(fc));
    window.fitTo = b => whenReady(() => { try { map.fitBounds(b, { padding: 40, maxZoom: 14, duration: 0 }); } catch (e) {} });
    </script></body></html>
    """
}
