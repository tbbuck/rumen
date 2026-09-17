// ArcGIS Explorer app icon: four concepts from a clean slate, 2026-09-17. Every design
// decision is in this file; icon-lib.mjs holds the mechanics.
//
//   node design/icon/build-icons.mjs design/icon/concepts.mjs <preview-dir> [renders-dir]
//
// Four different objects in four different palettes, nothing shared between them but the
// mechanics. Three are a white glass glyph on a saturated tile, which is how macOS 26
// icons are built; the fourth is a printed sheet. No clusters of small dots anywhere.
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readFile } from 'node:fs/promises';

const here = dirname(fileURLToPath(import.meta.url));

export const lede = 'Four objects in four palettes, each designed for the Dock first: white glass on a saturated tile for three of them, a printed sheet for the fourth. Nothing is shared between them but the mechanics.';

const WHITE = '#FFFFFF';

const fill = (d, colour, opacity) => `<path d="${d}" fill="${colour}"${opacity != null ? ` fill-opacity="${opacity}"` : ''}/>`;
const ringOf = (x, y, w, h) => [[x, y], [x + w, y], [x + w, y + h], [x, y + h]];
const lonLatBox = (x0, y0, x1, y1) => ({ type: 'Polygon', coordinates: [[[x0, y0], [x1, y0], [x1, y1], [x0, y1], [x0, y0]]] });
const rotate = (pts, cx, cy, deg) => {
  const a = (deg * Math.PI) / 180, c = Math.cos(a), s = Math.sin(a);
  return pts.map(([x, y]) => [cx + (x - cx) * c - (y - cy) * s, cy + (x - cx) * s + (y - cy) * c]);
};

// Grid rects as rings, so they can be cut to a convex shape.
function gridRings(box, step, offset, t) {
  const out = [];
  for (let x = box.x + offset; x < box.x + box.w; x += step) out.push(ringOf(x - t / 2, box.y, t, box.h));
  for (let y = box.y + offset; y < box.y + box.h; y += step) out.push(ringOf(box.x, y - t / 2, box.w, t));
  return out;
}

// ---- A · Layers ------------------------------------------------------------------
// The GIS layer stack: three white sheets in plan-oblique, the top one lifted and turned
// as it comes off the pile. Mac blue.
function layers(lib) {
  const cx = 512, W = 540, H = 290;
  const rhombus = (cy, deg = 0) => rotate([[cx, cy - H / 2], [cx + W / 2, cy], [cx, cy + H / 2], [cx - W / 2, cy]], cx, cy, deg);
  const sheets = [
    { name: 'bottom', ring: rhombus(676), opacity: 0.5 },
    { name: 'middle', ring: rhombus(572), opacity: 0.72 },
    { name: 'top', ring: rhombus(404, -7), opacity: 1 },
  ];
  return {
    key: 'layers', bundle: 'Layers', file: 'layers.svg', name: 'A · Layers',
    comment: 'Three sheets in plan-oblique, the top one lifted off the pile.',
    why: 'The layer stack every GIS user already reads, in white glass on Mac blue, with the top sheet lifted and turned as it comes off the pile. Three shapes, one idea: layers, and taking one.',
    tradeoff: 'The most generic silhouette of the four, so it leans on colour and glass for identity.',
    fill: { top: '#4C9BFF', bottom: '#1D5AE4' },
    layers: sheets.map(s => ({ name: s.name, glass: true, opacity: s.opacity, body: fill(lib.ringsToPath([s.ring]), WHITE) })),
    small: { layers: sheets.map(s => ({ name: s.name, opacity: Math.max(0.62, s.opacity), body: fill(lib.ringsToPath([s.ring]), WHITE) })) },
  };
}

// ---- B · Contours ---------------------------------------------------------------
// Schiehallion at 50 m, in the orange of an OS Explorer sheet on cream. Real terrain
// from the Copernicus DEM (contours.sh); contour lines were invented for this mountain.
async function contours(lib) {
  const geo = JSON.parse(await readFile(join(here, 'contours.json'), 'utf8'));
  const summit = [-4.0989, 56.6667];
  const half = 2200; // metres each way
  const dLat = half / 111320, dLon = half / (111320 * Math.cos((summit[1] * Math.PI) / 180));
  const window = lonLatBox(summit[0] - dLon, summit[1] - dLat, summit[0] + dLon, summit[1] + dLat);
  const proj = lib.project(lib.windowFor(lib.TILE, 1, window));

  const lines = geo.features.flatMap(f => {
    const parts = f.geometry.type === 'MultiLineString' ? f.geometry.coordinates : [f.geometry.coordinates];
    return parts.map(coords => ({ elev: f.properties.elev, coords }));
  });
  const bands = (keep, width) => lib.ringsToPath(lines.filter(l => keep(l.elev)).flatMap(l => {
    let pts = l.coords.map(proj);
    const [x0, y0] = pts[0], [x1, y1] = pts[pts.length - 1];
    const closed = Math.hypot(x1 - x0, y1 - y0) < 0.5;
    if (closed) pts = pts.slice(0, -1);
    if (pts.length < (closed ? 3 : 2)) return [];
    return lib.ribbonRings(lib.chaikin(pts, 2, closed), width, closed);
  }));

  return {
    key: 'contours', bundle: 'Contours', file: 'contours.svg', name: 'B · Contours',
    comment: 'Schiehallion at 50 m from the Copernicus DEM.',
    why: 'Schiehallion at 50 m intervals, index lines every 250 m, in the orange of an OS Explorer sheet on cream. Real terrain, and the mountain contour lines were invented for. It says map before it says anything else.',
    tradeoff: 'Texture, not a glyph: at 16px it is a warm tile with orange grain, and it says nothing about servers or downloads.',
    fill: { top: '#FCF7EC', bottom: '#F4EBD5' },
    shadow: 0.2,
    layers: [
      { name: 'contours', body: fill(bands(e => e % 250 !== 0, 5), '#E9873B') },
      { name: 'index', glass: true, body: fill(bands(e => e % 250 === 0, 9), '#D8651A') },
    ],
    small: {
      layers: [
        { name: 'contours', body: fill(bands(e => e % 100 === 0, 26), '#E27625') },
      ],
    },
  };
}

// ---- C · Peel ----------------------------------------------------------------------
// A white map sheet on OS Explorer orange, its corner lifted: the layer coming away.
function peel(lib) {
  const x0 = 196, y0 = 196, x1 = 828, y1 = 828, c = 250;
  const sheet = [[x0, y0], [x1, y0], [x1, y1 - c], [x1 - c, y1], [x0, y1]];
  // The lifted corner, curled back over the sheet: crease from A to B, tip T inside.
  const A = [x1 - c, y1], B = [x1, y1 - c], T = [x1 - c * 0.88, y1 - c * 0.88];
  const flap = `M${A[0]} ${A[1]}Q${x1 - c * 0.05} ${y1 - c * 0.05} ${B[0]} ${B[1]}Q${T[0] + c * 0.34} ${T[1] - c * 0.02} ${T[0]} ${T[1]}Q${T[0] - c * 0.02} ${T[1] + c * 0.34} ${A[0]} ${A[1]}Z`;
  const shadowOf = (pts, dx, dy) => pts.map(([x, y]) => [x + dx, y + dy]);
  const inner = { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
  const step = inner.w / 9;
  const grid = gridRings(inner, step, step, 4).map(g => lib.clipRingToConvex(g, sheet));
  const ex = { x: x0 + 128, y: y0 + 118, w: 306, h: 250 };
  const magenta = '#D6337F';

  return {
    key: 'peel', bundle: 'Peel', file: 'peel.svg', name: 'C · Peel',
    comment: 'A map sheet with its corner lifted.',
    why: 'A white map sheet on OS Explorer orange with its corner lifted: the layer coming away from the server. The grid and the Landranger-magenta extent are the app’s own map language, and magenta is the UI accent.',
    tradeoff: 'The lifted corner is what makes it, and it is the first thing to go: by 32px it is a white square on orange.',
    fill: { top: '#FFA23A', bottom: '#F26A1B' },
    shadow: 0.4,
    layers: [
      { name: 'sheet-shadow', flatOnly: true, body: fill(lib.ringsToPath([shadowOf(sheet, 0, 14)]), '#8A3A08', 0.28) },
      { name: 'sheet', glass: true, body: fill(lib.ringsToPath([sheet]), WHITE) },
      { name: 'grid', body: fill(lib.ringsToPath(grid), '#BFD3E8') },
      { name: 'extent', body: fill(lib.rectRingPath(ex.x, ex.y, ex.w, ex.h, 22), magenta) },
      { name: 'flap-shadow', flatOnly: true, body: `<path d="${flap}" fill="#8A3A08" fill-opacity="0.28" transform="translate(-6 10)"/>` },
      { name: 'flap', glass: true, body: `<path d="${flap}" fill="#EEF1F5"/>` },
    ],
    small: {
      layers: [
        { name: 'sheet', body: fill(lib.ringsToPath([sheet]), WHITE) },
        { name: 'extent', body: fill(lib.rectRingPath(ex.x - 20, ex.y - 10, ex.w + 60, ex.h + 60, 46), magenta) },
        { name: 'flap', body: `<path d="${flap}" fill="#DDE3EA"/>` },
      ],
    },
  };
}

// ---- D · Locator -----------------------------------------------------------------
// The app's own extent locator as the icon: a white frame with the layer's box pulled
// down out of it, on Landranger magenta.
function locator(lib) {
  const fx = 262, fy = 226, fs = 500, t = 56;
  const interior = { x: fx + t, y: fy + t, w: fs - 2 * t, h: fs - 2 * t };
  const step = interior.w / 6;
  const box = { x: 398, y: 596, w: 228, h: 214 };
  const tile = { top: '#E9509A', bottom: '#B01C63' };
  // A halo in the tile's own gradient around the box, so the box reads as passing through
  // the frame rather than merging with it. userSpaceOnUse from the tile's top to its
  // bottom edge matches the ground in both the flat master and the bundle.
  const haloDefs = `<linearGradient id="locator-halo" gradientUnits="userSpaceOnUse" x1="0" y1="${lib.TILE.y}" x2="0" y2="${lib.TILE.y + lib.TILE.h}"><stop offset="0" stop-color="${tile.top}"/><stop offset="1" stop-color="${tile.bottom}"/></linearGradient>`;
  const halo = g => fill(lib.rectPath(box.x - g, box.y - g, box.w + 2 * g, box.h + 2 * g), 'url(#locator-halo)');
  return {
    key: 'locator', bundle: 'Locator', file: 'locator.svg', name: 'D · Locator',
    comment: 'The extent locator with its box pulled out of the frame.',
    why: 'The extent locator that sits beside every layer in the app, blown up: a white frame for the server’s extent, and the layer’s own box pulled down and out through it. On Landranger magenta, the UI accent, so the icon and the app share a colour.',
    tradeoff: 'The most abstract of the four; it needs the app to explain it, and magenta is loud in a Dock.',
    fill: tile,
    shadow: 0.4,
    layers: [
      { name: 'grid', body: fill(lib.graticuleRects(interior, step, step, 4), WHITE, 0.3) },
      { name: 'frame', glass: true, body: fill(lib.rectRingPath(fx, fy, fs, fs, t), WHITE) },
      { name: 'halo', defs: haloDefs, body: halo(16) },
      { name: 'box-shadow', flatOnly: true, body: fill(lib.rectPath(box.x, box.y + 12, box.w, box.h), '#6E0D3E', 0.35) },
      { name: 'box', glass: true, body: fill(lib.rectPath(box.x, box.y, box.w, box.h), WHITE) },
    ],
    small: {
      layers: [
        { name: 'frame', body: fill(lib.rectRingPath(fx - 10, fy - 10, fs + 20, fs + 20, 74), WHITE) },
        { name: 'halo', defs: haloDefs, body: halo(34) },
        { name: 'box', body: fill(lib.rectPath(box.x - 10, box.y - 10, box.w + 20, box.h + 30), WHITE) },
      ],
    },
  };
}

export default async function concepts(lib) {
  return [layers(lib), await contours(lib), peel(lib), locator(lib)];
}
