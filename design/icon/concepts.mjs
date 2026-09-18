// Rumen app icon. Every design decision is in this file; icon-lib.mjs holds
// the mechanics.
//
//   node design/icon/build-icons.mjs design/icon/concepts.mjs <preview-dir> [renders-dir]
//   node design/icon/export-app-icon.mjs design/icon/concepts.mjs peel Resources/AppIcon
//
// Decided 2026-09-17: **Peel**. A white map sheet on OS Explorer orange with its
// bottom-right corner lifted (the layer coming away from the server), a faint blue grid
// and a Landranger-magenta extent, the app's own map language and UI accent. Chosen from a
// clean-slate set of four, then from four steps on how strongly the curl reads: the
// bigger flap with a flat underside won over a shaded roll, a pink underside and a second
// sheet beneath. Locator, the runner-up, is kept below unbuilt. No clusters of small dots.
const WHITE = '#FFFFFF';

export const lede = 'Peel, as shipped: a white map sheet on OS Explorer orange with its corner lifted, a faint grid and a Landranger-magenta extent.';

const fill = (d, colour, opacity) => `<path d="${d}" fill="${colour}"${opacity != null ? ` fill-opacity="${opacity}"` : ''}/>`;
const ringOf = (x, y, w, h) => [[x, y], [x + w, y], [x + w, y + h], [x, y + h]];
const shift = (pts, dx, dy) => pts.map(([x, y]) => [x + dx, y + dy]);

// Grid rects as rings, so they can be cut to a convex shape.
function gridRings(box, step, offset, t) {
  const out = [];
  for (let x = box.x + offset; x < box.x + box.w; x += step) out.push(ringOf(x - t / 2, box.y, t, box.h));
  for (let y = box.y + offset; y < box.y + box.h; y += step) out.push(ringOf(box.x, y - t / 2, box.w, t));
  return out;
}

// ---- Peel ----------------------------------------------------------------------------
export function peel(lib) {
  // The sheet, inset 96px from the tile, with its bottom-right corner cut off along the
  // crease; the flap is that corner curled back over the sheet, its tip rounded.
  const x0 = 196, y0 = 196, x1 = 828, y1 = 828, c = 340;
  const sheet = [[x0, y0], [x1, y0], [x1, y1 - c], [x1 - c, y1], [x0, y1]];
  const A = [x1 - c, y1], B = [x1, y1 - c], T = [x1 - c * 0.88, y1 - c * 0.88];
  const flapAt = (dx, dy) => {
    const p = ([x, y]) => `${(x + dx).toFixed(1)} ${(y + dy).toFixed(1)}`;
    return `M${p(A)}`
      + `Q${p([x1 - c * 0.05, y1 - c * 0.05])} ${p(B)}`
      + `Q${p([T[0] + c * 0.34, T[1] - c * 0.02])} ${p([T[0] + c * 0.07, T[1]])}`
      + `Q${p(T)} ${p([T[0], T[1] + c * 0.07])}`
      + `Q${p([T[0] - c * 0.02, T[1] + c * 0.34])} ${p(A)}Z`;
  };
  const flap = flapAt(0, 0);

  // Map language on the sheet: a 9-cell grid in survey blue, the layer's extent in the
  // UI accent.
  const inner = { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
  const step = inner.w / 9;
  const grid = gridRings(inner, step, step, 4).map(g => lib.clipRingToConvex(g, sheet));
  const ex = { x: x0 + 96, y: y0 + 92, w: 292, h: 236 };
  const magenta = '#D6337F';
  const tile = { top: '#FFA23A', bottom: '#F26A1B' };
  const shade = '#8A3A08';
  const underside = '#EEF1F5';

  return {
    key: 'peel', bundle: 'Peel', file: 'peel.svg', name: 'Peel',
    comment: 'A white map sheet with its corner lifted, on OS Explorer orange.',
    why: 'A white map sheet on OS Explorer orange with its corner lifted: the layer coming away from the server. The grid and the Landranger-magenta extent are the app’s own map language, and magenta is the UI accent.',
    tradeoff: 'The lifted corner is what makes it, and it is the first thing to go: by 16px it is a white square on orange with a magenta mark.',
    fill: tile,
    shadow: 0.4,
    groups: { flap: { shadow: 0.5 } },
    layers: [
      { name: 'sheet-shadow', flatOnly: true, blur: 10, body: fill(lib.ringsToPath([shift(sheet, 0, 16)]), shade, 0.32) },
      { name: 'sheet', glass: true, body: fill(lib.ringsToPath([sheet]), WHITE) },
      { name: 'grid', body: fill(lib.ringsToPath(grid), '#BFD3E8') },
      { name: 'extent', body: fill(lib.rectRingPath(ex.x, ex.y, ex.w, ex.h, 22), magenta) },
      { name: 'flap-shadow', flatOnly: true, blur: 8, body: `<path d="${flapAt(-8, 12)}" fill="${shade}" fill-opacity="0.32"/>` },
      { name: 'flap', glass: true, group: 'flap', body: `<path d="${flap}" fill="${underside}"/>` },
    ],
    // 32px and 16px: no grid, a heavier extent, the flap darker so the corner survives.
    small: {
      layers: [
        { name: 'sheet', body: fill(lib.ringsToPath([sheet]), WHITE) },
        { name: 'extent', body: fill(lib.rectRingPath(ex.x - 16, ex.y - 8, ex.w + 56, ex.h + 60, 46), magenta) },
        { name: 'flap-shadow', body: `<path d="${flapAt(-14, 18)}" fill="${shade}" fill-opacity="0.3"/>` },
        { name: 'flap', body: `<path d="${flap}" fill="#D9DFE7"/>` },
      ],
    },
  };
}

// ---- Locator (runner-up, kept, not built) ----------------------------------------------
// The app's own extent locator as the icon: a white frame with the layer's box pulled
// down out through it, on Landranger magenta.
export function locator(lib) {
  const fx = 262, fy = 226, fs = 500, t = 56;
  const interior = { x: fx + t, y: fy + t, w: fs - 2 * t, h: fs - 2 * t };
  const step = interior.w / 6;
  const box = { x: 398, y: 596, w: 228, h: 214 };
  const tile = { top: '#E9509A', bottom: '#B01C63' };
  const haloDefs = `<linearGradient id="locator-halo" gradientUnits="userSpaceOnUse" x1="0" y1="${lib.TILE.y}" x2="0" y2="${lib.TILE.y + lib.TILE.h}"><stop offset="0" stop-color="${tile.top}"/><stop offset="1" stop-color="${tile.bottom}"/></linearGradient>`;
  const halo = g => fill(lib.rectPath(box.x - g, box.y - g, box.w + 2 * g, box.h + 2 * g), 'url(#locator-halo)');
  return {
    key: 'locator', bundle: 'Locator', file: 'locator.svg', name: 'Locator',
    comment: 'The extent locator with its box pulled out of the frame.',
    why: 'The extent locator that sits beside every layer in the app, blown up: a white frame for the server’s extent, and the layer’s own box pulled down and out through it. On Landranger magenta, the UI accent.',
    tradeoff: 'The most abstract; it needs the app to explain it, and magenta is loud in a Dock.',
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
  return [peel(lib)];
}
