import SwiftUI
import WebKit
import OSLog
import ArcGISKit

/// What the map shows: the layer's extent (dashed), features (sample, stored, or query), and
/// the graticule the sheet margins are labelled against. `fitToken` bumps to re-fit;
/// `clearToken` bumps to drop the selection highlight.
struct MapContent: Equatable {
    var extent: BoundingBox?
    var featuresGeoJSON: String?
    var graticuleGeoJSON: String?
    var fit: BoundingBox?
    var fitToken = 0
    var clearToken = 0
}

/// MapLibre GL (MapTiler basemaps by appearance) in a `WKWebView`, fed GeoJSON and reporting
/// its viewport and clicked features back — the same mechanism as DuckLake Explorer.
///
/// Interaction lives in the page: hover uses feature state (evaluated on the GPU, no
/// per-feature work), the selected feature is drawn from its own source, and paint
/// transitions animate the rest dimming and the highlight fading in and out.
struct GeoMapView: NSViewRepresentable {
    let content: MapContent
    let onViewport: (MapViewport) -> Void
    var onFeature: ([String: String]?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(onViewport: onViewport, onFeature: onFeature) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "viewport")
        configuration.userContentController.add(context.coordinator, name: "feature")
        configuration.userContentController.add(context.coordinator, name: "log")
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
        context.coordinator.setReduceMotion(context.environment.accessibilityReduceMotion)
        context.coordinator.apply(content)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "viewport")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "feature")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "log")
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
            .replacingOccurrences(of: "__HALO__", with: dark ? "#2A0F1D" : "#FFFFFF")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var style = "dataviz"
        private let onViewport: (MapViewport) -> Void
        private let onFeature: ([String: String]?) -> Void
        private var loaded = false
        private var pending: MapContent?
        private var applied = MapContent()
        private var reduceMotion = false
        private var reduceMotionSent: Bool?

        init(onViewport: @escaping (MapViewport) -> Void, onFeature: @escaping ([String: String]?) -> Void) {
            self.onViewport = onViewport
            self.onFeature = onFeature
        }

        func reload(_ html: String) {
            loaded = false
            applied = MapContent()
            reduceMotionSent = nil
            webView?.loadHTMLString(html, baseURL: URL(string: "https://tiles.local/"))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            reduceMotionSent = nil
            setReduceMotion(reduceMotion)
            if let pending { apply(pending, force: true) }
        }

        /// The system's Reduce Motion setting, handed to the page so its hover and selection
        /// fades snap instead, as the SwiftUI ones do.
        func setReduceMotion(_ on: Bool) {
            reduceMotion = on
            guard loaded, let webView, reduceMotionSent != on else { return }
            reduceMotionSent = on
            webView.evaluateJavaScript("window.setReduceMotion(\(on));")
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
            if content.clearToken != applied.clearToken {
                webView.evaluateJavaScript("window.clearSelection();")
            }
            applied = content
        }

        private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ArcGISExplorer", category: "map")

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "log" {
                Self.log.error("\(String(describing: message.body), privacy: .public)")
                return
            }
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
      #nokey{position:absolute;left:10px;bottom:10px;font:11px Cabin,sans-serif;color:__INK__;background:__PANEL__;padding:4px 8px;border:1px solid __LINE2__;border-radius:6px;display:none}
    </style>
    </head><body><div id="map"></div><div id="nokey">No MapTiler key: basemap tiles are off. See Config/maptiler.xcconfig.</div><script>
    const ACCENT = '__ACCENT__', GRAT = '__GRAT__', HALO = '__HALO__';
    const KEY = '__MAPTILER_KEY__';
    function log(m) { try { window.webkit.messageHandlers.log.postMessage(String(m)); } catch (e) {} }
    window.onerror = (m, s, l, c) => log('page error: ' + m + ' @' + l + ':' + c);
    if (!KEY) { document.getElementById('nokey').style.display = 'block'; }
    const map = new maplibregl.Map({
      container: 'map',
      style: KEY ? 'https://api.maptiler.com/maps/__MAP_STYLE__/style.json?key=' + KEY
                 : { version: 8, sources: {}, layers: [{ id: 'bg', type: 'background', paint: { 'background-color': '__BG__' } }] },
      center: [-2.2, 54.2], zoom: 4.4, attributionControl: false
    });
    map.addControl(new maplibregl.NavigationControl({showCompass:false}), 'top-right');
    function empty() { return {type:'FeatureCollection', features:[]}; }
    const T = { duration: 260 };
    // Hover strength 0..1 lives in feature state and is tweened below, so outlines fade rather than snap.
    const hov = ['number', ['feature-state', 'hover'], 0];
    // Layer-wide opacities are constants, so changing them animates (data-driven values do not).
    const OP = { fill: 0.18, line: 1, pt: 1 };
    const DIM = { fill: 0.04, line: 0.22, pt: 0.22 };
    const SEL = { fill: 0.45, line: 1, pt: 1 };
    // Two highlight slots: a new pick fades in on one while the old fades out on the other.
    const SLOTS = ['sel0', 'sel1'];
    function addLayers() {
      map.addSource('grat', { type:'geojson', data: empty() });
      map.addLayer({ id:'grat-line', type:'line', source:'grat', paint:{ 'line-color': GRAT, 'line-width': 1, 'line-opacity': 0.9 } });
      map.addSource('features', { type:'geojson', data: empty(), generateId: true });
      map.addLayer({ id:'f-fill', type:'fill', source:'features', filter:['==','$type','Polygon'],
        paint:{ 'fill-color': ACCENT, 'fill-opacity': OP.fill, 'fill-opacity-transition': T } });
      map.addLayer({ id:'f-line', type:'line', source:'features', filter:['any',['==','$type','Polygon'],['==','$type','LineString']],
        paint:{ 'line-color': ACCENT, 'line-width': ['interpolate', ['linear'], hov, 0, 1.2, 1, 2.4], 'line-opacity': OP.line, 'line-opacity-transition': T } });
      map.addLayer({ id:'f-pt', type:'circle', source:'features', filter:['==','$type','Point'],
        paint:{ 'circle-color': ACCENT, 'circle-radius': ['interpolate', ['linear'], hov, 0, 4, 1, 6], 'circle-stroke-color': HALO, 'circle-stroke-width': 1,
                'circle-opacity': OP.pt, 'circle-opacity-transition': T, 'circle-stroke-opacity': OP.pt, 'circle-stroke-opacity-transition': T } });
      for (const s of SLOTS) {
        map.addSource(s, { type:'geojson', data: empty() });
        map.addLayer({ id: s + '-fill', type:'fill', source: s, filter:['==','$type','Polygon'],
          paint:{ 'fill-color': ACCENT, 'fill-opacity': 0, 'fill-opacity-transition': T } });
        map.addLayer({ id: s + '-line', type:'line', source: s, filter:['any',['==','$type','Polygon'],['==','$type','LineString']],
          paint:{ 'line-color': ACCENT, 'line-width': 2.6, 'line-opacity': 0, 'line-opacity-transition': T } });
        map.addLayer({ id: s + '-pt', type:'circle', source: s, filter:['==','$type','Point'],
          paint:{ 'circle-color': ACCENT, 'circle-radius': 7, 'circle-stroke-color': HALO, 'circle-stroke-width': 2,
                  'circle-opacity': 0, 'circle-opacity-transition': T, 'circle-stroke-opacity': 0, 'circle-stroke-opacity-transition': T } });
      }
      map.addSource('extent', { type:'geojson', data: empty() });
      map.addLayer({ id:'extent-line', type:'line', source:'extent', paint:{ 'line-color': ACCENT, 'line-width': 1.5, 'line-dasharray': [3, 2] } });
    }
    function setOpacity(op) {
      map.setPaintProperty('f-fill', 'fill-opacity', op.fill);
      map.setPaintProperty('f-line', 'line-opacity', op.line);
      map.setPaintProperty('f-pt', 'circle-opacity', op.pt);
      map.setPaintProperty('f-pt', 'circle-stroke-opacity', op.pt);
    }
    function showSlot(s, on) {
      map.setPaintProperty(s + '-fill', 'fill-opacity', on ? SEL.fill : 0);
      map.setPaintProperty(s + '-line', 'line-opacity', on ? SEL.line : 0);
      map.setPaintProperty(s + '-pt', 'circle-opacity', on ? SEL.pt : 0);
      map.setPaintProperty(s + '-pt', 'circle-stroke-opacity', on ? SEL.pt : 0);
    }
    // setData parses in a worker; fading in before the new data is drawable would pop it in mid-fade.
    function whenSourceLoaded(id, fn) {
      if (map.isSourceLoaded(id)) { fn(); return; }
      const h = e => { if (e.sourceId === id && map.isSourceLoaded(id)) { map.off('sourcedata', h); fn(); } };
      map.on('sourcedata', h);
    }
    // ---- Reduce Motion: every paint transition drops to zero and the hover strength jumps.
    let reduceMotion = false;
    function applyMotion() {
      const t = reduceMotion ? { duration: 0 } : T;
      const props = [['f-fill', 'fill-opacity'], ['f-line', 'line-opacity'], ['f-pt', 'circle-opacity'], ['f-pt', 'circle-stroke-opacity']];
      for (const s of SLOTS) props.push([s + '-fill', 'fill-opacity'], [s + '-line', 'line-opacity'], [s + '-pt', 'circle-opacity'], [s + '-pt', 'circle-stroke-opacity']);
      for (const [layer, prop] of props) if (map.getLayer(layer)) map.setPaintProperty(layer, prop + '-transition', t);
    }
    // ---- Hover: tween the strength with requestAnimationFrame; only the entering and leaving features tick.
    const HOVER_MS = 140;
    const hoverAnim = new Map();
    let hoverRaf = null, hoverLast = 0, hoveredId = null;
    function tickHover(now) {
      const dt = Math.min(50, now - hoverLast); hoverLast = now;
      let active = false;
      for (const [id, a] of hoverAnim) {
        const step = dt / HOVER_MS;
        a.v = a.target > a.v ? Math.min(a.target, a.v + step) : Math.max(a.target, a.v - step);
        map.setFeatureState({ source: 'features', id: id }, { hover: a.v });
        if (a.v !== a.target) active = true; else if (a.v === 0) hoverAnim.delete(id);
      }
      hoverRaf = active ? requestAnimationFrame(tickHover) : null;
    }
    function animateHover(id, target) {
      if (reduceMotion) { hoverAnim.delete(id); map.setFeatureState({ source: 'features', id: id }, { hover: target }); return; }
      const a = hoverAnim.get(id) || { v: 0, target: 0 };
      a.target = target; hoverAnim.set(id, a);
      if (hoverRaf === null) { hoverLast = performance.now(); hoverRaf = requestAnimationFrame(tickHover); }
    }
    function setHover(id) {
      if (hoveredId === id) return;
      if (hoveredId !== null) animateHover(hoveredId, 0);
      hoveredId = id;
      if (id !== null) animateHover(id, 1);
    }
    function resetHover() {
      if (hoverRaf !== null) cancelAnimationFrame(hoverRaf);
      hoverRaf = null; hoverAnim.clear(); hoveredId = null;
    }
    // ---- Selection
    let selectedId = null, slot = 0, clearTimer = null;
    function select(feature) {
      if (clearTimer) { clearTimeout(clearTimer); clearTimer = null; }
      if (selectedId === feature.id) return;
      const fc = { type: 'FeatureCollection', features: [ { type: 'Feature', properties: {}, geometry: feature.geometry } ] };
      if (selectedId !== null) { showSlot(SLOTS[slot], false); slot = 1 - slot; }
      const next = SLOTS[slot];
      map.getSource(next).setData(fc);
      whenSourceLoaded(next, () => showSlot(next, true));
      selectedId = feature.id;
      setOpacity(DIM);
    }
    window.clearSelection = function() {
      if (clearTimer) { clearTimeout(clearTimer); clearTimer = null; }
      selectedId = null;
      for (const s of SLOTS) showSlot(s, false);
      setOpacity(OP);
      clearTimer = setTimeout(() => {
        clearTimer = null;
        if (selectedId !== null) return;
        for (const s of SLOTS) { const src = map.getSource(s); if (src) src.setData(empty()); }
      }, 300);
    };
    function post() {
      const b = map.getBounds(); const c = map.getCanvas();
      const r = c.getBoundingClientRect();
      window.webkit.messageHandlers.viewport.postMessage({ west: b.getWest(), south: b.getSouth(), east: b.getEast(), north: b.getNorth(), width: r.width, height: r.height, zoom: map.getZoom() });
    }
    const HIT = ['f-fill', 'f-line', 'f-pt'];
    map.on('error', e => log('maplibre: ' + (e && e.error ? e.error.message : e)));
    map.on('load', () => {
      try { addLayers(); } catch (e) { log('layers: ' + e.message); }
      ready = true; queued.splice(0).forEach(g => g());
      post();
      map.on('mousemove', e => {
        const hits = map.queryRenderedFeatures(e.point, { layers: HIT });
        map.getCanvas().style.cursor = hits.length ? 'pointer' : '';
        setHover(hits.length ? hits[0].id : null);
      });
      map.on('mouseout', () => { setHover(null); map.getCanvas().style.cursor = ''; });
      map.on('click', e => {
        const hits = map.queryRenderedFeatures(e.point, { layers: HIT });
        if (hits.length) {
          select(hits[0]);
          const p = Object.assign({}, hits[0].properties);
          p.__geometry = hits[0].geometry.type;
          window.webkit.messageHandlers.feature.postMessage(p);
        } else {
          window.clearSelection();
          window.webkit.messageHandlers.feature.postMessage(null);
        }
      });
    });
    map.on('moveend', post);
    map.on('resize', post);
    function guarded(fn) { return () => { try { fn(); } catch (e) { log('map: ' + e.message); } }; }
    // Our own readiness: isStyleLoaded() flips false while a source reparses after setData,
    // and a callback parked on a second 'load' event would never run.
    let ready = false; const queued = [];
    function whenReady(fn) { const g = guarded(fn); if (ready) g(); else queued.push(g); }
    window.setGraticule = fc => whenReady(() => map.getSource('grat').setData(fc));
    window.setFeatures = fc => whenReady(() => { window.clearSelection(); resetHover(); map.getSource('features').setData(fc); });
    window.setExtent = fc => whenReady(() => map.getSource('extent').setData(fc));
    window.fitTo = b => whenReady(() => { try { map.fitBounds(b, { padding: 40, maxZoom: 14, duration: 0 }); } catch (e) {} });
    window.setReduceMotion = on => { reduceMotion = !!on; whenReady(applyMotion); };
    </script></body></html>
    """
}
