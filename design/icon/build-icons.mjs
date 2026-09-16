// Builds the app-icon concept SVGs (1024 canvas, Apple squircle tile baked in)
// and a preview page that shows each at Dock and Finder sizes on light and dark
// grounds. The SVGs are the sources of truth for the flat masters; the page is
// generated, never edited by hand.
//
//   node design/icon/build-icons.mjs <preview-dir>
//
// Geography comes from design/icon/geography.json (Overture Maps division areas,
// pulled by `duckdb -f design/icon/geography.sql`): Great Britain, Ireland and the
// Isle of Man are the feature. Writes design/icon/<Name>.svg for each
// concept and, in <preview-dir>, icon-preview.html (standalone) and
// arcgis-explorer-icon.html (Artifact fragment).
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const previewDir = process.argv[2];
if (!previewDir) {
  console.error('usage: node build-icons.mjs <preview-dir>');
  process.exit(1);
}

// Apple's macOS icon tile: superellipse |x/a|^n + |y/a|^n = 1, 824 across on a
// 1024 canvas, exponent 5 (same as DuckLake Explorer's squircle-path.mjs).
function squirclePath() {
  const cx = 512, cy = 512, a = 412, n = 5, steps = 180;
  const pts = [];
  for (let i = 0; i < steps; i++) {
    const t = (i / steps) * Math.PI * 2;
    const c = Math.cos(t), s = Math.sin(t);
    const x = cx + Math.sign(c) * a * Math.pow(Math.abs(c), 2 / n);
    const y = cy + Math.sign(s) * a * Math.pow(Math.abs(s), 2 / n);
    pts.push(`${x.toFixed(1)} ${y.toFixed(1)}`);
  }
  return 'M ' + pts.join(' L ') + ' Z';
}
const SQUIRCLE = squirclePath();

// Sheet palette (DESIGN-TOKENS.md, Day), plus the icon's own grounds.
// Land is a warm sand so that cool accents (greens, teals, inks) stand off it; the
// water stays pale blue.
const p = { ground: '#EDEFE9', paper: '#FFFFFF', land: '#E6E0CC', landLine: '#C3B89C', line2: '#BEC5BA', grat: '#CBD7E4', water: '#DCE7F0', muted2: '#8A948E', accent: '#116C7E', accentSoft: 'rgba(17,108,126,0.10)', ghost: '#9FB0BF', ghostGrat: 'rgba(34,42,38,0.09)' };

// The two shortlisted extent colours.
const PETROL = '#116C7E';
const SLATE = '#34475A';

// The extent is a query box over part of the layer, not the layer's own bounding
// box: England and Wales, with the top edge cutting across Britain and Scotland and
// Ireland left outside.
const queryExtent = { type: 'Polygon', coordinates: [[[-6.0, 49.9], [1.9, 49.9], [1.9, 55.05], [-6.0, 55.05], [-6.0, 49.9]]] };

// ---- Geography -------------------------------------------------------------

// Every part in a geography file is the feature: Great Britain and Ireland, generalised
// to logo grade. The extent is the bounding box of both. Two strengths are available.
async function loadFeature(file) {
  const geo = JSON.parse(await readFile(join(here, file), 'utf8'));
  const feature = { type: 'MultiPolygon', coordinates: geo.flatMap(f => f.geojson.type === 'Polygon' ? [f.geojson.coordinates] : f.geojson.coordinates) };
  if (feature.coordinates.length === 0) {
    console.error(`${file} is empty; re-run duckdb -f design/icon/geography.sql`);
    process.exit(1);
  }
  return feature;
}
const smooth = await loadFeature('geography.json');
const bold = await loadFeature('geography-bold.json');

function rings(geojson) {
  if (geojson.type === 'Polygon') return geojson.coordinates;
  if (geojson.type === 'MultiPolygon') return geojson.coordinates.flat();
  return [];
}

function bboxOf(geojson) {
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const ring of rings(geojson)) for (const [x, y] of ring) {
    if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y;
  }
  return { x0, y0, x1, y1 };
}

// A window onto the map: the feature's bounding box is centred in `box` and spans
// `featH` of its height. Equal scale in x and y (equirectangular corrected by cos of
// the mid latitude), so shapes keep their proportions.
function windowFor(box, featH, feature) {
  const fb = bboxOf(feature);
  const midLat = (fb.y0 + fb.y1) / 2;
  const k = Math.cos(midLat * Math.PI / 180);
  const latSpan = (fb.y1 - fb.y0) / featH;
  const scale = box.h / latSpan;                // px per degree of latitude
  const lonSpan = box.w / (scale * k);
  const lonCentre = (fb.x0 + fb.x1) / 2;
  return { lon0: lonCentre - lonSpan / 2, latTop: midLat + latSpan / 2, k, scale, box };
}

function project(win) {
  return ([lon, lat]) => [win.box.x + (lon - win.lon0) * win.k * win.scale, win.box.y + (win.latTop - lat) * win.scale];
}

function pathFor(geojson, proj) {
  return rings(geojson).map(r => 'M' + r.map(pt => { const [x, y] = proj(pt); return `${x.toFixed(1)} ${y.toFixed(1)}`; }).join('L') + 'Z').join('');
}

function extentRect(geojson, proj) {
  const b = bboxOf(geojson);
  const [x0, y0] = proj([b.x0, b.y1]);
  const [x1, y1] = proj([b.x1, b.y0]);
  return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
}

// The map fragment inside `box`: water, graticule, the British Isles in magenta,
// and their dashed extent.
function mapFragment(box, featH, gratStep, strokeW, dash, feature = smooth) {
  const win = windowFor(box, featH, feature);
  const proj = project(win);
  const ext = extentRect(queryExtent, proj);
  const g = [];
  for (let x = box.x + gratStep / 2; x < box.x + box.w; x += gratStep) g.push(`M${x} ${box.y}V${box.y + box.h}`);
  for (let y = box.y + gratStep / 2; y < box.y + box.h; y += gratStep) g.push(`M${box.x} ${y}H${box.x + box.w}`);
  // The layer is land on a sheet: sage fill, thin darker edge. Magenta belongs to
  // the extent alone, whose faint tint marks what falls inside it.
  return `<rect x="${box.x}" y="${box.y}" width="${box.w}" height="${box.h}" fill="${p.water}"/>
      <path d="${pathFor(feature, proj)}" fill="${p.land}" stroke="${p.landLine}" stroke-width="${Math.round(strokeW * 0.35)}" stroke-linejoin="round" fill-rule="evenodd"/>
      <path d="${g.join('')}" stroke="${p.grat}" stroke-width="4" fill="none"/>
      <rect x="${ext.x.toFixed(1)}" y="${ext.y.toFixed(1)}" width="${ext.w.toFixed(1)}" height="${ext.h.toFixed(1)}" fill="${p.accentSoft}" stroke="${p.accent}" stroke-width="${strokeW}" stroke-dasharray="${dash}"/>`;
}

// A quieter sheet for the back of a stack: the graticule, and optionally the same
// layer as a grey outline, so the stack reads as several layers of one place.
function ghostFragment(box, featH, gratStep, feature, withOutline) {
  const win = windowFor(box, featH, feature);
  const proj = project(win);
  const g = [];
  for (let x = box.x + gratStep / 2; x < box.x + box.w; x += gratStep) g.push(`M${x} ${box.y}V${box.y + box.h}`);
  for (let y = box.y + gratStep / 2; y < box.y + box.h; y += gratStep) g.push(`M${box.x} ${y}H${box.x + box.w}`);
  const outline = withOutline ? `<path d="${pathFor(feature, proj)}" fill="none" stroke="${p.ghost}" stroke-width="10" stroke-linejoin="round"/>` : '';
  return `<path d="${g.join('')}" stroke="${p.ghostGrat}" stroke-width="4" fill="none"/>
      ${outline}`;
}

// ---- Concepts --------------------------------------------------------------

function svgDoc(name, comment, defs, body) {
  return `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 1024 1024" width="1024" height="1024">
  <!-- ArcGIS Explorer app icon concept "${name}". ${comment}
       Geography: Great Britain, Ireland and the Isle of Man from Overture Maps (OSM, ODbL).
       Flat master: Apple's macOS squircle tile (824pt on a 1024pt canvas) is baked in.
       Generated by design/icon/build-icons.mjs; edit the script, not this file. -->
  <defs>
    <path id="squircle" d="${SQUIRCLE}"/>
    <clipPath id="tile"><use xlink:href="#squircle"/></clipPath>
    ${defs}
  </defs>
  <g clip-path="url(#tile)">
    ${body}
  </g>
</svg>
`;
}

const SOFT = `<filter id="soft" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="16"/></filter>`;

// A · Footprint: the tile is the sheet.
function conceptA(feature = bold, name = 'A · Footprint') {
  const tile = { x: 0, y: 0, w: 1024, h: 1024 };
  const body = `<g>
      ${mapFragment(tile, 0.62, 160, 18, '46 30', feature)}
    </g>`;
  return svgDoc(name, 'The tile is the survey sheet: graticule, Great Britain and Ireland as land, and a dashed query extent over England and Wales.', '', body);
}

// B · Sheet: a white map sheet with margins and ticks on the pale ground.
function conceptB(feature = bold) {
  const sheet = { x: 156, y: 156, w: 712, h: 712 };
  const map = { x: 202, y: 202, w: 620, h: 620 };
  const ticks = [];
  for (let x = map.x + 96; x < map.x + map.w; x += 96) ticks.push(`M${x} ${sheet.y + 14}V${map.y - 6}`);
  for (let y = map.y + 96; y < map.y + map.h; y += 96) ticks.push(`M${sheet.x + 14} ${y}H${map.x - 6}`);
  const defs = `${SOFT}
    <clipPath id="map"><rect x="${map.x}" y="${map.y}" width="${map.w}" height="${map.h}"/></clipPath>`;
  const body = `<rect width="1024" height="1024" fill="${p.ground}"/>
    <rect x="${sheet.x}" y="${sheet.y + 24}" width="${sheet.w}" height="${sheet.h}" rx="26" fill="#000" opacity="0.22" filter="url(#soft)"/>
    <rect x="${sheet.x}" y="${sheet.y}" width="${sheet.w}" height="${sheet.h}" rx="26" fill="${p.paper}"/>
    <path d="${ticks.join('')}" stroke="${p.muted2}" stroke-width="5" fill="none"/>
    <g clip-path="url(#map)">
      ${mapFragment(map, 0.68, 96, 14, '40 26', feature)}
    </g>
    <rect x="${map.x}" y="${map.y}" width="${map.w}" height="${map.h}" fill="none" stroke="${p.line2}" stroke-width="4"/>`;
  return svgDoc('B · Sheet', 'A white map sheet with margins and ticks on the pale ground; the Solent, the island and its extent drawn on it.', defs, body);
}

// C · Pulled layer: three distinct sheets from one server, the front one lifted away.
// The tile ground is itself a sheet, with a faint graticule and a wash of water in
// the corner. Back sheet: blank paper. Middle: paper with the graticule. Front,
// white and pulled up-right: a map with margins and tick marks, the layer, and its
// extent.
function conceptC(feature = bold, name = 'C · Pulled layer') {
  const w = 480, h = 560, rx = 28, m = 34;
  const back = { x: 168, y: 356, w, h, fill: '#DCE0D8' };
  const mid = { x: 246, y: 262, w, h, fill: '#F4F5F1' };
  const front = { x: 344, y: 120, w, h };
  const map = { x: front.x + m, y: front.y + m, w: w - 2 * m, h: h - 2 * m };
  const defs = `${SOFT}
    <clipPath id="back"><rect x="${back.x}" y="${back.y}" width="${w}" height="${h}" rx="${rx}"/></clipPath>
    <clipPath id="mid"><rect x="${mid.x}" y="${mid.y}" width="${w}" height="${h}" rx="${rx}"/></clipPath>
    <clipPath id="front"><rect x="${front.x}" y="${front.y}" width="${w}" height="${h}" rx="${rx}"/></clipPath>
    <clipPath id="map"><rect x="${map.x}" y="${map.y}" width="${map.w}" height="${map.h}"/></clipPath>`;
  const sheet = (s, clip, content) => `<rect x="${s.x}" y="${s.y + 22}" width="${w}" height="${h}" rx="${rx}" fill="#000" opacity="0.26" filter="url(#soft)"/>
    <g clip-path="url(#${clip})">
      <rect x="${s.x}" y="${s.y}" width="${w}" height="${h}" fill="${s.fill ?? p.paper}"/>
      ${content}
    </g>
    <rect x="${s.x}" y="${s.y}" width="${w}" height="${h}" rx="${rx}" fill="none" stroke="${p.line2}" stroke-width="3"/>`;
  // Ground: the desk is a sheet too.
  const tile = { x: 0, y: 0, w: 1024, h: 1024 };
  const groundGrid = [];
  for (let x = 72; x < 1024; x += 160) groundGrid.push(`M${x} 0V1024`);
  for (let y = 72; y < 1024; y += 160) groundGrid.push(`M0 ${y}H1024`);
  const ground = `<rect width="1024" height="1024" fill="${p.ground}"/>
    <path d="M0 790 C 130 760 230 800 340 828 S 560 900 700 878 S 900 826 1024 846 V1024 H0 Z" fill="${p.water}" opacity="0.7"/>
    <path d="${groundGrid.join('')}" stroke="rgba(34,42,38,0.07)" stroke-width="4" fill="none"/>`;
  // Front sheet: margins with tick marks, then the map inset.
  const ticks = [];
  for (let x = map.x + 96; x < map.x + map.w; x += 96) ticks.push(`M${x} ${front.y + 10}V${map.y - 6}`);
  for (let y = map.y + 96; y < map.y + map.h; y += 96) ticks.push(`M${front.x + 10} ${y}H${map.x - 6}`);
  const frontContent = `<path d="${ticks.join('')}" stroke="${p.muted2}" stroke-width="4" fill="none"/>
      <g clip-path="url(#map)">
        ${mapFragment(map, 0.72, 96, 12, '34 22', feature)}
      </g>
      <rect x="${map.x}" y="${map.y}" width="${map.w}" height="${map.h}" fill="none" stroke="${p.line2}" stroke-width="3"/>`;
  const body = `${ground}
    ${sheet(back, 'back', '')}
    ${sheet(mid, 'mid', ghostFragment(mid, 0.7, 96, feature, false))}
    ${sheet(front, 'front', frontContent)}`;
  return svgDoc(name, 'Three sheets from one server on a gridded desk: blank paper, gridded paper, and the white front sheet lifted away carrying a margined map with the layer and its extent. Extraction as a gesture.', defs, body);
}

function hexToRgba(hex, alpha) {
  const n = parseInt(hex.slice(1), 16);
  return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${alpha})`;
}

function withAccent(hex, fn) {
  const saved = { accent: p.accent, accentSoft: p.accentSoft };
  p.accent = hex;
  p.accentSoft = hexToRgba(hex, 0.10);
  try { return fn(); } finally { Object.assign(p, saved); }
}

const concepts = [
  { key: 'C', file: 'C-pulled-layer.svg', name: 'C · Pulled layer, petrol', svg: withAccent(PETROL, () => conceptC(bold, 'C · Pulled layer, petrol')), why: 'Three sheets from one server on a gridded desk with a wash of water in the corner: blank paper, gridded paper, and the white front sheet lifted away carrying a margined map with tick marks, the layer, and its extent in petrol. The only concept that shows what the app does: extraction.', tradeoff: 'Busiest silhouette; a stack can read as a generic layers glyph.' },
  { key: 'C2', file: 'C-pulled-layer-slate.svg', name: 'C · Pulled layer, ink slate', svg: withAccent(SLATE, () => conceptC(bold, 'C · Pulled layer, ink slate')), why: 'The same frame with the extent in ink slate: no colour signal, only the drawn line, so the sand and water carry the colour.', tradeoff: 'The extent is quieter at 16px than petrol.' },
  { key: 'A', file: 'A-footprint.svg', name: 'A · Footprint, petrol', svg: conceptA(bold, 'A · Footprint, petrol'), why: 'For context: the tile as the sheet, with the same map and extent.', tradeoff: 'Pale ground, so quiet on a light desktop.' },
  { key: 'B', file: 'B-sheet.svg', name: 'B · Sheet, petrol', svg: conceptB(), why: 'For context: the map on a white sheet with margins and ticks on the pale ground.', tradeoff: 'The ticks vanish below 64px.' },
];

// ---- Preview page ----------------------------------------------------------

// Inline an SVG into the page with ids namespaced per concept and the fixed size removed.
function inlineSvg(key, svg) {
  return svg
    .replace(/ width="1024" height="1024"/, '')
    .replace(/id="([^"]+)"/g, `id="${key}-$1"`)
    .replace(/url\(#([^)]+)\)/g, `url(#${key}-$1)`)
    .replace(/xlink:href="#([^"]+)"/g, `xlink:href="#${key}-$1"`)
    .replace(/<!--[\s\S]*?-->/, '');
}

const sizes = [128, 64, 32, 16];
const rows = concepts.map(c => {
  const art = inlineSvg(c.key, c.svg);
  return `<section class="concept">
    <div class="big">${art}</div>
    <div class="text">
      <h2>${c.name}</h2>
      <p>${c.why}</p>
      <p class="trade">${c.tradeoff}</p>
    </div>
    <div class="sizes">${sizes.map(s => `<div class="sz" style="width:${s}px;height:${s}px">${art}</div>`).join('')}</div>
  </section>`;
}).join('\n');

function dock(theme, items = concepts) {
  const cells = items.map(c => `<div class="dock-item">${inlineSvg(c.key + theme, c.svg)}</div>`).join('');
  return `<div class="dock ${theme}"><div class="dock-item ghost"></div>${cells}<div class="dock-item ghost"></div></div>`;
}


const css = `
  body { margin: 0; background: var(--bg); color: var(--ink); font-family: "Cabin", "Gill Sans", "Helvetica Neue", sans-serif; }
  .wrap { max-width: 1240px; margin: 0 auto; padding-block: 32px 60px; padding-inline: 24px; }
  h1 { font-size: 22px; font-weight: 700; margin: 0 0 4px; }
  .lede { color: var(--muted); font-size: 14px; margin: 0 0 28px; max-width: 720px; line-height: 1.5; }
  .strip { border-radius: 16px; padding: 24px; margin-bottom: 28px; }
  .strip.light { background: #F1F2EE; color: #222A26; --muted: #5E6863; }
  .strip.dark { background: #26292E; color: #E7EAE6; --muted: #A2ACA6; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 28px; }
  .concept { display: flex; flex-direction: column; gap: 14px; }
  .big { width: 300px; max-width: 100%; aspect-ratio: 1; }
  .big.small { width: 220px; }
  .hex { font-weight: 400; color: var(--muted); font-size: 12px; margin-left: 6px; }
  .big svg, .sz svg, .dock-item svg { width: 100%; height: 100%; display: block; filter: drop-shadow(0 1.5px 3px rgba(0,0,0,.22)); }
  .sizes { display: flex; align-items: flex-end; gap: 14px; height: 128px; }
  h2 { font-size: 15px; font-weight: 700; margin: 0 0 4px; }
  .text p { margin: 0; font-size: 13px; line-height: 1.45; color: var(--muted); max-width: 320px; }
  .text .trade { margin-top: 4px; }
  .dock { display: flex; gap: 10px; padding: 10px; border-radius: 22px; background: var(--dock); border: 1px solid var(--dock-line); width: max-content; max-width: 100%; margin: 18px auto 0; overflow-x: auto; }
  .dock.dark { --dock: rgba(40,42,48,.85); --dock-line: rgba(255,255,255,.08); }
  .dock-item { width: 64px; height: 64px; flex: 0 0 64px; }
  .dock-item.ghost { border-radius: 14px; background: rgba(120,125,120,.35); width: 52px; height: 52px; flex-basis: 52px; margin: 6px; }
  .label { font-size: 12px; color: var(--muted); text-align: center; margin-top: 8px; }
`;

const content = `<div class="wrap">
  <h1>ArcGIS Explorer app icon</h1>
  <p class="lede">C, the pulled layer, in the two shortlisted extent colours, petrol (#116C7E) and ink slate (#34475A), with A and B alongside for context. Apple's squircle tile at Dock (128, 64), sidebar (32) and Finder list (16) sizes. The geography is Great Britain and Ireland from Overture Maps. The two Dock strips show the icons beside neighbours on a light and a dark desktop.</p>
  <div class="strip light">
    <div class="grid">${rows}</div>
    ${dock('light')}
    <div class="label">Light desktop, 64px</div>
  </div>
  <div class="strip dark">
    ${dock('dark')}
    <div class="label">Dark desktop, 64px</div>
  </div>
</div>
`;

const fontLink = `<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Cabin:wght@400;500;600;700&display=swap">`;

const page = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ArcGIS Explorer Icon</title>
${fontLink}
<style>
  :root { --bg: #E9EAE6; --ink: #222A26; --muted: #5E6863; --dock: rgba(255,255,255,.55); --dock-line: rgba(0,0,0,.08); }
${css}
</style>
</head>
<body>
${content}
</body>
</html>
`;

// The same page as a fragment for publishing as an Artifact (the host supplies the
// document skeleton and paints its own ground, so the page tokens follow its theme).
const artifactPage = `<title>ArcGIS Explorer Icon</title>
${fontLink}
<style>
  :root { --bg: #E9EAE6; --ink: #222A26; --muted: #5E6863; --dock: rgba(255,255,255,.55); --dock-line: rgba(0,0,0,.08); }
  @media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { --bg: #14181D; --ink: #E7EAE6; --muted: #A2ACA6; } }
  :root[data-theme="dark"] { --bg: #14181D; --ink: #E7EAE6; --muted: #A2ACA6; }
${css}
</style>
${content}`;

await mkdir(previewDir, { recursive: true });
for (const c of concepts) await writeFile(join(here, c.file), c.svg);
await writeFile(join(previewDir, 'icon-preview.html'), page);
await writeFile(join(previewDir, 'arcgis-explorer-icon.html'), artifactPage);
console.log(`wrote ${concepts.length} concept SVGs to ${here}, icon-preview.html and arcgis-explorer-icon.html to ${previewDir}`);
