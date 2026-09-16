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

// The front sheet as it was in the first rounds: white paper, the blue graticule, a
// wash of water in the lower corner, and on it the layer (sand islands) with the
// dashed extent. No sea fill: the water is a corner of the sheet, not the map.
function paperMap(box, featH, gratStep, strokeW, dash, feature) {
  const win = windowFor(box, featH, feature);
  const proj = project(win);
  const ext = extentRect(queryExtent, proj);
  const g = [];
  for (let x = box.x + gratStep / 2; x < box.x + box.w; x += gratStep) g.push(`M${x} ${box.y}V${box.y + box.h}`);
  for (let y = box.y + gratStep / 2; y < box.y + box.h; y += gratStep) g.push(`M${box.x} ${y}H${box.x + box.w}`);
  const X = f => (box.x + f * box.w).toFixed(0), Y = f => (box.y + f * box.h).toFixed(0);
  const wave = `M${X(0)} ${Y(0.76)} C ${X(0.18)} ${Y(0.72)} ${X(0.30)} ${Y(0.78)} ${X(0.46)} ${Y(0.83)} S ${X(0.78)} ${Y(0.92)} ${X(1)} ${Y(0.86)} V${Y(1)} H${X(0)} Z`;
  return `<rect x="${box.x}" y="${box.y}" width="${box.w}" height="${box.h}" fill="${p.paper}"/>
      <path d="${wave}" fill="${p.water}"/>
      <path d="${g.join('')}" stroke="${p.grat}" stroke-width="4" fill="none"/>
      <path d="${pathFor(feature, proj)}" fill="${p.land}" stroke="${p.landLine}" stroke-width="${Math.round(strokeW * 0.35)}" stroke-linejoin="round" fill-rule="evenodd"/>
      <rect x="${ext.x.toFixed(1)}" y="${ext.y.toFixed(1)}" width="${ext.w.toFixed(1)}" height="${ext.h.toFixed(1)}" fill="${p.accentSoft}" stroke="${p.accent}" stroke-width="${strokeW}" stroke-dasharray="${dash}"/>`;
}

// A faintly gridded grey sheet for the back of the stack, as in round two.
function greySheet(box, gratStep) {
  const g = [];
  for (let x = box.x + gratStep / 2; x < box.x + box.w; x += gratStep) g.push(`M${x} ${box.y}V${box.y + box.h}`);
  for (let y = box.y + gratStep / 2; y < box.y + box.h; y += gratStep) g.push(`M${box.x} ${y}H${box.x + box.w}`);
  return `<path d="${g.join('')}" stroke="${p.ghostGrat}" stroke-width="4" fill="none"/>`;
}

// C · Pulled layer: three sheets from one server, the white front one lifted away.
// Options pick the iteration:
//   desk:   'plain' (flat ground) | 'grid' (the desk is a faintly gridded sheet too)
//   front:  'bleed' (map fills the sheet) | 'margins' (margins with tick marks, map inset)
//   lift:   how far the front sheet is pulled up-right, in px
//   featH:  how much of the front map the islands fill
function conceptC({ name, desk = 'plain', front = 'bleed', lift = 150, featH = 0.72, feature = bold }) {
  const w = 480, h = 560, rx = 28, m = 32;
  const backS = { x: 168, y: 356, w, h, fill: '#D6DBD3' };
  const midS = { x: 246, y: 262, w, h, fill: '#E6E9E3' };
  const frontS = { x: 246 + Math.round(lift * 0.65), y: 262 - lift, w, h };
  const map = front === 'margins'
    ? { x: frontS.x + m, y: frontS.y + m, w: w - 2 * m, h: h - 2 * m }
    : { x: frontS.x, y: frontS.y, w, h };
  const defs = `${SOFT}
    <clipPath id="back"><rect x="${backS.x}" y="${backS.y}" width="${w}" height="${h}" rx="${rx}"/></clipPath>
    <clipPath id="mid"><rect x="${midS.x}" y="${midS.y}" width="${w}" height="${h}" rx="${rx}"/></clipPath>
    <clipPath id="front"><rect x="${frontS.x}" y="${frontS.y}" width="${w}" height="${h}" rx="${rx}"/></clipPath>
    <clipPath id="map"><rect x="${map.x}" y="${map.y}" width="${map.w}" height="${map.h}"/></clipPath>`;
  const sheet = (s, clip, content, shadow) => `<rect x="${s.x}" y="${s.y + 22}" width="${w}" height="${h}" rx="${rx}" fill="#000" opacity="${shadow}" filter="url(#soft)"/>
    <g clip-path="url(#${clip})">
      <rect x="${s.x}" y="${s.y}" width="${w}" height="${h}" fill="${s.fill ?? p.paper}"/>
      ${content}
    </g>`;
  let ground = `<rect width="1024" height="1024" fill="${p.ground}"/>`;
  if (desk === 'grid') {
    const gg = [];
    for (let x = 72; x < 1024; x += 160) gg.push(`M${x} 0V1024`);
    for (let y = 72; y < 1024; y += 160) gg.push(`M0 ${y}H1024`);
    ground += `\n    <path d="${gg.join('')}" stroke="rgba(34,42,38,0.06)" stroke-width="4" fill="none"/>`;
  }
  let frontContent = `<g clip-path="url(#map)">${paperMap(map, featH, 96, 12, '34 22', feature)}</g>`;
  if (front === 'margins') {
    const ticks = [];
    for (let x = map.x + 96; x < map.x + map.w; x += 96) ticks.push(`M${x} ${frontS.y + 10}V${map.y - 6}`);
    for (let y = map.y + 96; y < map.y + map.h; y += 96) ticks.push(`M${frontS.x + 10} ${y}H${map.x - 6}`);
    frontContent = `<path d="${ticks.join('')}" stroke="${p.muted2}" stroke-width="4" fill="none"/>
      ${frontContent}
      <rect x="${map.x}" y="${map.y}" width="${map.w}" height="${map.h}" fill="none" stroke="${p.line2}" stroke-width="3"/>`;
  }
  const body = `${ground}
    ${sheet(backS, 'back', greySheet(backS, 96), 0.18)}
    ${sheet(midS, 'mid', greySheet(midS, 96), 0.2)}
    ${sheet(frontS, 'front', frontContent, 0.3)}`;
  return svgDoc(name, 'Three sheets from one server: two greyed, faintly gridded sheets behind, and the white front sheet lifted away with the blue graticule, a wash of water in the corner, the layer and its extent. Extraction as a gesture.', defs, body);
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

// Four iterations of C, each in both shortlisted accents.
const iterations = [
  { key: 'C1', file: 'C1', name: 'C1 · round-two sheets', opts: { desk: 'plain', front: 'bleed', lift: 150, featH: 0.72 }, why: 'The sheets as they were in round two: greyed, faintly gridded sheets behind; the white front sheet with the blue graticule and a wash of water in the lower corner. The map fills the sheet.' },
  { key: 'C2', file: 'C2', name: 'C2 · gridded desk', opts: { desk: 'grid', front: 'bleed', lift: 150, featH: 0.72 }, why: 'C1 with the desk drawn as a faintly gridded sheet too, so the whole tile is paper.' },
  { key: 'C3', file: 'C3', name: 'C3 · margins and ticks', opts: { desk: 'plain', front: 'margins', lift: 150, featH: 0.74 }, why: 'C1 with margins and tick marks on the front sheet, the marginalia from the early B, and the map inset inside a thin frame.' },
  { key: 'C4', file: 'C4', name: 'C4 · lifted further', opts: { desk: 'plain', front: 'bleed', lift: 190, featH: 0.8 }, why: 'C1 with the front sheet pulled further out and the islands larger, for presence at Dock size.' },
];

const concepts = iterations.flatMap(it => [
  { key: it.key + 'p', file: `${it.file}-petrol.svg`, name: `${it.name}, petrol`, svg: withAccent(PETROL, () => conceptC({ ...it.opts, name: `${it.name}, petrol` })), why: it.why, tradeoff: 'Extent in petrol (#116C7E).' },
  { key: it.key + 's', file: `${it.file}-slate.svg`, name: `${it.name}, ink slate`, svg: withAccent(SLATE, () => conceptC({ ...it.opts, name: `${it.name}, ink slate` })), why: it.why, tradeoff: 'Extent in ink slate (#34475A).' },
]);

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
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 28px; }
  .concept { display: flex; flex-direction: column; gap: 14px; }
  .big { width: 260px; max-width: 100%; aspect-ratio: 1; }
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
  <p class="lede">Four iterations of C, the pulled layer, each in petrol (#116C7E) and in ink slate (#34475A). Apple's squircle tile at Dock (128, 64), sidebar (32) and Finder list (16) sizes. The geography is Great Britain and Ireland from Overture Maps. The two Dock strips show the icons beside neighbours on a light and a dark desktop.</p>
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
