// ArcGIS Explorer app icon: four concepts, started fresh on 2026-09-17. Every design
// decision is in this file; icon-lib.mjs holds the mechanics.
//
//   node design/icon/build-icons.mjs design/icon/concepts.mjs <preview-dir> [renders-dir]
//
// All four sit on a paper tile with the map in petrol and ink, because the earlier rounds
// showed that a light tile with contrast built in value is what survives the Dock. No
// scattered points and no invented geography: Great Britain and Ireland generalised to
// logo grade are the only map content, and the dashed rectangle is the app's own object,
// a query extent crossing land rather than outlining it.
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));

export const lede = 'Four directions on the same paper tile, with the same coastline, the same query extent and the same three colours, so the only thing to judge is the object: a survey sheet, a folded map, a layer pulled off a stack, a lens. Contrast is built in value (paper 97, sea 91, petrol 41, ink 19 on the L* scale) because hue does not survive the Dock.';

// Palette. Lightness ladder: paper 97 · sea 91 · sheet2 88 · sheet3 79 · desk 70 ·
// petrol 41 · ink 19.
const P = {
  paper: '#F6F7F3',
  paperLow: '#EAEDE6',
  sheet2: '#DADFD6',
  sheet3: '#BEC6BB',
  desk: '#A3ACA2',
  deskLow: '#98A197',
  sea: '#DCE6EE',
  grat: '#A6B8C8',
  petrol: '#116C7E',
  ink: '#232F3A',
};

const lonLatBox = (x0, y0, x1, y1) => ({ type: 'Polygon', coordinates: [[[x0, y0], [x1, y0], [x1, y1], [x0, y1], [x0, y0]]] });

// The query extent in degrees: Dublin to the Wash, the Bristol Channel to the Solway.
// It crosses land on both islands.
const EXTENT = lonLatBox(-7.0, 51.7, -0.6, 55.2);

// Dash geometry shared by every concept, in tile px.
const DASH = { t: 18, on: 38, off: 24 };

const fill = (d, colour, opacity) => `<path d="${d}" fill="${colour}"${opacity != null ? ` fill-opacity="${opacity}"` : ''}/>`;

const ringOf = (x, y, w, h) => [[x, y], [x + w, y], [x + w, y + h], [x, y + h]];

// Grid rects as rings so they can be clipped to a convex panel or sheet.
function gridRings(box, step, offset, t) {
  const out = [];
  for (let x = box.x + offset; x < box.x + box.w; x += step) out.push(ringOf(x - t / 2, box.y, t, box.h));
  for (let y = box.y + offset; y < box.y + box.h; y += step) out.push(ringOf(box.x, y - t / 2, box.w, t));
  return out;
}

// A solid frame as two rings (outer clockwise, inner counter-clockwise), clip-safe.
const frameRings = (x, y, w, h, t) => [ringOf(x, y, w, h), ringOf(x + t, y + t, w - 2 * t, h - 2 * t).reverse()];

// ---- A · Survey sheet -------------------------------------------------------------
// The tile is the map sheet: neatline with margin ticks, blue graticule, land in petrol,
// the extent in ink.
function sheet(lib, land) {
  const T = lib.TILE;
  const m = 76;
  const map = { x: T.x + m, y: T.y + m, w: T.w - 2 * m, h: T.h - 2 * m };
  const frame = 12;
  const outer = { x: map.x - frame, y: map.y - frame, w: map.w + 2 * frame, h: map.h + 2 * frame };
  const step = map.w / 10;

  const proj = lib.project(lib.windowFor(map, 0.86, land));
  const ext = lib.extentRect(EXTENT, proj);

  const smallProj = lib.project(lib.windowFor(map, 0.94, land));
  const sext = lib.extentRect(EXTENT, smallProj);

  return {
    key: 'sheet', bundle: 'Sheet', file: 'sheet.svg', name: 'A · Survey sheet',
    comment: 'The tile is the map sheet itself.',
    why: 'The tile is the map sheet itself: neatline and margin ticks, a blue graticule, Great Britain and Ireland in petrol, and the dashed query extent crossing both islands. The app’s own map tab, as the icon.',
    tradeoff: 'The least distinctive silhouette of the four: at 16px it is a pale tile with a petrol island and a dark frame.',
    fill: { top: P.paper, bottom: P.paperLow },
    layers: [
      { name: 'sea', body: fill(lib.rectPath(map.x, map.y, map.w, map.h), P.sea) },
      { name: 'graticule', body: fill(lib.graticuleRects(map, step, step, 4), P.grat) },
      { name: 'land', glass: true, body: fill(lib.pathFor(land, proj), P.petrol) },
      { name: 'extent', body: fill(lib.dashedRectPath(ext.x, ext.y, ext.w, ext.h, DASH.t, DASH.on, DASH.off), P.ink) },
      { name: 'neatline', body: fill(lib.rectRingPath(outer.x, outer.y, outer.w, outer.h, frame) + lib.neatlineTicks(outer, 10, 18, 6, 6), P.ink) },
    ],
    small: {
      layers: [
        { name: 'sea', body: fill(lib.rectPath(map.x, map.y, map.w, map.h), P.sea) },
        { name: 'land', body: fill(lib.pathFor(land, smallProj), P.petrol) },
        { name: 'extent', body: fill(lib.rectRingPath(sext.x, sext.y, sext.w, sext.h, 44), P.ink) },
        { name: 'neatline', body: fill(lib.rectRingPath(outer.x - 16, outer.y - 16, outer.w + 32, outer.h + 32, 30), P.ink) },
      ],
    },
  };
}

// ---- B · Folded map ---------------------------------------------------------------
// A sheet folded in four on the desk, the map printed across the creases, alternate
// panels in shade.
function fold(lib, land) {
  const x0 = 156, x1 = 868, top = 214, bot = 810, dz = 32, n = 4;
  const pw = (x1 - x0) / n;
  const joints = Array.from({ length: n + 1 }, (_, j) => [x0 + j * pw, j % 2 === 0 ? dz : -dz]);
  const panels = Array.from({ length: n }, (_, i) => {
    const [xa, da] = joints[i], [xb, db] = joints[i + 1];
    return [[xa, top + da], [xb, top + db], [xb, bot + db], [xa, bot + da]];
  });
  const outline = [...joints.map(([x, d]) => [x, top + d]), ...joints.slice().reverse().map(([x, d]) => [x, bot + d])];
  const shadowOf = dy => outline.map(([x, y]) => [x, y + dy]);
  const inner = { x: x0, y: top + dz, w: x1 - x0, h: bot - top - 2 * dz };
  const step = inner.h / 8;

  const proj = lib.project(lib.windowFor(inner, 0.9, land));
  const ext = lib.extentRect(EXTENT, proj);
  const grid = gridRings({ x: x0, y: top - dz, w: x1 - x0, h: bot - top + 2 * dz }, step, step / 2, 3)
    .flatMap(g => panels.map(p => lib.clipRingToConvex(g, p)));
  const creases = joints.slice(1, -1).map(([x, d]) => lib.rectPath(x - 2, top + d, 4, bot - top)).join('');
  const shaded = [panels[1], panels[3]];

  const smallProj = lib.project(lib.windowFor(inner, 0.98, land));
  const sext = lib.extentRect(EXTENT, smallProj);

  return {
    key: 'fold', bundle: 'Fold', file: 'fold.svg', name: 'B · Folded map',
    comment: 'A sheet folded in four on the desk.',
    why: 'A Landranger folded in four on the desk, the same sheet printed across the creases, alternate panels in shade. The one concept that says paper map before it says data.',
    tradeoff: 'The creases cost it width: the islands are smaller than on A, and the zigzag edge is gone by 32px.',
    fill: { top: P.desk, bottom: P.deskLow },
    shadow: 0.45,
    layers: [
      { name: 'shadow', flatOnly: true, body: fill(lib.ringsToPath([shadowOf(14)]), P.ink, 0.22) },
      { name: 'sheet', glass: true, body: fill(lib.ringsToPath([outline]), P.paper) },
      { name: 'graticule', body: fill(lib.ringsToPath(grid), P.grat) },
      { name: 'land', glass: true, body: fill(lib.pathFor(land, proj), P.petrol) },
      { name: 'extent', body: fill(lib.dashedRectPath(ext.x, ext.y, ext.w, ext.h, DASH.t, DASH.on, DASH.off), P.ink) },
      { name: 'shade', body: fill(lib.ringsToPath(shaded), P.ink, 0.10) + fill(creases, P.ink, 0.22) },
    ],
    small: {
      layers: [
        { name: 'sheet', body: fill(lib.ringsToPath([outline]), P.paper) },
        { name: 'land', body: fill(lib.pathFor(land, smallProj), P.petrol) },
        { name: 'extent', body: fill(lib.rectRingPath(sext.x, sext.y, sext.w, sext.h, 40), P.ink) },
        { name: 'shade', body: fill(lib.ringsToPath(shaded), P.ink, 0.16) },
      ],
    },
  };
}

// ---- C · Pulled layer -------------------------------------------------------------
// Three sheets stepping down in value, the front one drawn down and out of the pile,
// carrying the map. The outer sheets overflow the tile's corners.
function stack(lib, land) {
  const S = 600;
  const front = { x: 214, y: 274 };
  const sheets = [
    { name: 'back', rot: -13, dx: -78, dy: -126, colour: P.sheet3 },
    { name: 'mid', rot: -6.5, dx: -40, dy: -66, colour: P.sheet2 },
    { name: 'front', rot: 0, dx: 0, dy: 0, colour: P.paper },
  ];
  const place = (s, [x, y]) => {
    const cx = front.x + S / 2 + s.dx, cy = front.y + S / 2 + s.dy;
    const a = (s.rot * Math.PI) / 180, c = Math.cos(a), si = Math.sin(a);
    return [cx + x * c - y * si, cy + x * si + y * c];
  };
  const corners = [[-S / 2, -S / 2], [S / 2, -S / 2], [S / 2, S / 2], [-S / 2, S / 2]];
  const ringFor = (s, dx = 0, dy = 0) => corners.map(([x, y]) => place(s, [x + dx, y + dy]));

  const inner = { x: front.x + 34, y: front.y + 34, w: S - 68, h: S - 68 };
  const step = inner.w / 10;
  const proj = lib.project(lib.windowFor(inner, 0.86, land));
  const ext = lib.extentRect(EXTENT, proj);

  // A faint grid on the sheet behind, drawn in its own frame and cut to its edge.
  const mid = sheets[1];
  const localGrid = gridRings({ x: -S / 2 + 34, y: -S / 2 + 34, w: S - 68, h: S - 68 }, step, step, 3)
    .map(g => g.map(pt => place(mid, pt)))
    .map(g => lib.clipRingToConvex(g, ringFor(mid)));

  const smallProj = lib.project(lib.windowFor(inner, 0.96, land));
  const sext = lib.extentRect(EXTENT, smallProj);

  // Bottom to top: each sheet's hard shadow then the sheet; the faint grid on the mid
  // sheet goes in before the front sheet covers it.
  const sheetLayers = (shadow, glass) => sheets.flatMap(s => [
    ...(shadow ? [{ name: `${s.name}-shadow`, flatOnly: true, body: fill(lib.ringsToPath([ringFor(s, 8, 14)]), P.ink, 0.18) }] : []),
    { name: s.name, glass, body: fill(lib.ringsToPath([ringFor(s)]), s.colour) },
    ...(s === mid && shadow ? [{ name: 'grid-behind', body: fill(lib.ringsToPath(localGrid), P.grat, 0.7) }] : []),
  ]);

  return {
    key: 'stack', bundle: 'Stack', file: 'stack.svg', name: 'C · Pulled layer',
    comment: 'Three sheets, the front one drawn down and out of the pile.',
    why: 'Three sheets stepping down in value, the front one drawn down and out of the pile, carrying the map. The download story in one shape: a layer, taken off the stack.',
    tradeoff: 'Four values on one tile; the outer sheets overflow the corners so the front sheet keeps its size, and the map is smaller than on A.',
    fill: { top: P.desk, bottom: P.deskLow },
    shadow: 0.45,
    layers: [
      ...sheetLayers(true, true),
      { name: 'graticule', body: fill(lib.graticuleRects(inner, step, step, 3), P.grat) },
      { name: 'land', glass: true, body: fill(lib.pathFor(land, proj), P.petrol) },
      { name: 'extent', body: fill(lib.dashedRectPath(ext.x, ext.y, ext.w, ext.h, DASH.t, DASH.on, DASH.off), P.ink) },
    ],
    small: {
      layers: [
        ...sheetLayers(false, false),
        { name: 'land', body: fill(lib.pathFor(land, smallProj), P.petrol) },
        { name: 'extent', body: fill(lib.rectRingPath(sext.x, sext.y, sext.w, sext.h, 40), P.ink) },
      ],
    },
  };
}

// ---- D · Lens ---------------------------------------------------------------------
// A loupe on a gridded sheet: paper and a faint grid outside the ring, the map in full
// colour inside it.
function lens(lib, land) {
  const cx = 512, cy = 506, R = 338, T = 44, rIn = R - T;
  const box = { x: cx - rIn, y: cy - rIn, w: 2 * rIn, h: 2 * rIn };
  const circle = lib.circlePolygon(cx, cy, rIn, 120);
  const step = box.w / 9;

  const proj = lib.project(lib.windowFor(box, 0.98, land));
  const landInside = lib.ringsToPath(lib.projectedRings(land, proj).map(r => lib.clipRingToConvex(r, circle)));
  const ext = lib.extentRect(EXTENT, proj);
  const dashes = lib.ringsToPath(lib.dashedRectRings(ext.x, ext.y, ext.w, ext.h, DASH.t, DASH.on, DASH.off).map(r => lib.clipRingToConvex(r, circle)));
  const outerGrid = lib.graticuleRects(lib.TILE, step, step / 2, 4);

  const sR = 338, sT = 68, sIn = sR - sT;
  const sCircle = lib.circlePolygon(cx, cy, sIn, 120);
  const sBox = { x: cx - sIn, y: cy - sIn, w: 2 * sIn, h: 2 * sIn };
  const smallProj = lib.project(lib.windowFor(sBox, 1.0, land));
  const sLand = lib.ringsToPath(lib.projectedRings(land, smallProj).map(r => lib.clipRingToConvex(r, sCircle)));
  const sext = lib.extentRect(EXTENT, smallProj);
  const sExtent = lib.ringsToPath(frameRings(sext.x, sext.y, sext.w, sext.h, 40).map(r => lib.clipRingToConvex(r, sCircle)));

  return {
    key: 'lens', bundle: 'Lens', file: 'lens.svg', name: 'D · Lens',
    comment: 'A loupe on a gridded sheet.',
    why: 'A loupe on a gridded sheet: outside the ring the paper and its faint grid, inside it the map in full colour with the extent. The boldest shape in the set and the only one that is not a rectangle.',
    tradeoff: 'Reads as a porthole or a badge before it reads as a map, and the ring is all that is left at 16px.',
    fill: { top: P.paper, bottom: P.paperLow },
    layers: [
      { name: 'grid-outside', body: fill(outerGrid, P.grat, 0.55) },
      { name: 'sea', body: fill(lib.circlePath(cx, cy, rIn), P.sea) },
      { name: 'graticule', body: fill(lib.graticuleChords(cx, cy, rIn, step, step / 2, 4), P.grat) },
      { name: 'land', glass: true, body: fill(landInside, P.petrol) },
      { name: 'extent', body: fill(dashes, P.ink) },
      { name: 'ring', glass: true, body: fill(lib.ringPath(cx, cy, R, rIn), P.ink) },
    ],
    small: {
      layers: [
        { name: 'sea', body: fill(lib.circlePath(cx, cy, sIn), P.sea) },
        { name: 'land', body: fill(sLand, P.petrol) },
        { name: 'extent', body: fill(sExtent, P.ink) },
        { name: 'ring', body: fill(lib.ringPath(cx, cy, sR, sIn), P.ink) },
      ],
    },
  };
}

export default async function concepts(lib) {
  const land = await lib.loadFeature(join(here, 'geography-bold.json'), 2);
  return [sheet(lib, land), fold(lib, land), stack(lib, land), lens(lib, land)];
}
