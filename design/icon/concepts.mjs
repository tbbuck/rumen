// ArcGIS Explorer app icon. Every design decision is in this file; icon-lib.mjs holds
// the mechanics.
//
//   node design/icon/build-icons.mjs design/icon/concepts.mjs <preview-dir> [renders-dir]
//
// State on 2026-09-17: of the clean-slate set, Tom binned Layers (too close to Dropbox)
// and Contours (too 90s), found Peel and Locator fun and leans to Peel. The build is
// four steps along one axis of Peel, how strongly the curl reads. Locator is kept
// below, unbuilt. No clusters of small dots anywhere.
const WHITE = '#FFFFFF';

export const lede = 'Peel, four steps along one axis: how strongly the lifted corner reads. Each step keeps everything from the one before and changes one thing. Same sheet, same grid, same extent, same orange.';

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
// A white map sheet on OS Explorer orange, its corner lifted: the layer coming away.
//   v.c          flap size along each edge, in tile px
//   v.underside  'flat' | 'rolled' (grey at the crease to white at the tip, cast shadow)
//                | 'tinted' (the same roll in pale magenta)
//   v.beneath    a second sheet under the corner: one layer comes away, the rest stay
function peel(lib, v) {
  const x0 = 196, y0 = 196, x1 = 828, y1 = 828, c = v.c;
  const sheet = [[x0, y0], [x1, y0], [x1, y1 - c], [x1 - c, y1], [x0, y1]];
  // The lifted corner, curled back over the sheet: crease from A to B, tip T inside.
  const A = [x1 - c, y1], B = [x1, y1 - c], T = [x1 - c * 0.88, y1 - c * 0.88];
  const flapAt = (dx, dy) => `M${A[0] + dx} ${A[1] + dy}Q${x1 - c * 0.05 + dx} ${y1 - c * 0.05 + dy} ${B[0] + dx} ${B[1] + dy}Q${T[0] + c * 0.34 + dx} ${T[1] - c * 0.02 + dy} ${T[0] + dx} ${T[1] + dy}Q${T[0] - c * 0.02 + dx} ${T[1] + c * 0.34 + dy} ${A[0] + dx} ${A[1] + dy}Z`;
  const flap = flapAt(0, 0);

  const inner = { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
  const step = inner.w / 9;
  const grid = gridRings(inner, step, step, 4).map(g => lib.clipRingToConvex(g, sheet));
  const ex = { x: x0 + 96, y: y0 + 92, w: 292, h: 236 };
  const magenta = '#D6337F';
  const tile = { top: '#FFA23A', bottom: '#F26A1B' };
  const shade = '#8A3A08';

  // Underside: flat, or shaded from the crease (dark) to the tip (light).
  // The roll: dark right at the crease where the paper turns under, light by a third
  // of the way to the tip, flat from there.
  const rolled = v.underside !== 'flat';
  const [dark, mid, light] = v.underside === 'tinted' ? ['#D0709F', '#F3C3DA', '#FCE4EF'] : ['#9AA5B4', '#DEE4EB', WHITE];
  const M = [x1 - c / 2, y1 - c / 2];
  const undersideDefs = rolled
    ? `<linearGradient id="${v.key}-underside" gradientUnits="userSpaceOnUse" x1="${M[0]}" y1="${M[1]}" x2="${T[0]}" y2="${T[1]}"><stop offset="0" stop-color="${dark}"/><stop offset="0.32" stop-color="${mid}"/><stop offset="0.6" stop-color="${light}"/><stop offset="1" stop-color="${light}"/></linearGradient>`
    : '';
  const undersideFill = rolled ? `url(#${v.key}-underside)` : '#EEF1F5';
  const undersideSmall = v.underside === 'tinted' ? '#ECB4CF' : '#D9DFE7';

  // The flap's cast shadow on the sheet: two offset steps in the flat master (no
  // filters), a stronger group shadow in the bundle.
  const castShadow = rolled
    ? `<path d="${flapAt(-16, 20)}" fill="${shade}" fill-opacity="0.14"/><path d="${flapAt(-7, 10)}" fill="${shade}" fill-opacity="0.2"/>`
    : `<path d="${flapAt(-6, 10)}" fill="${shade}" fill-opacity="0.28"/>`;

  const beneathRing = ringOf(x0 + 24, y0 + 24, x1 - x0, y1 - y0);
  const beneath = v.beneath
    ? [
      { name: 'beneath-shadow', flatOnly: true, body: fill(lib.ringsToPath([shift(beneathRing, 0, 12)]), shade, 0.24) },
      { name: 'beneath', glass: true, body: fill(lib.ringsToPath([beneathRing]), '#D9E2EC') },
    ]
    : [];

  return {
    key: v.key, bundle: v.bundle, file: `${v.key}.svg`, name: v.name,
    comment: v.comment,
    why: v.why,
    tradeoff: v.tradeoff,
    fill: tile,
    shadow: 0.4,
    groups: { flap: { shadow: rolled ? 0.7 : 0.4 } },
    layers: [
      ...beneath,
      { name: 'sheet-shadow', flatOnly: true, body: fill(lib.ringsToPath([shift(sheet, 0, 14)]), shade, 0.28) },
      { name: 'sheet', glass: true, body: fill(lib.ringsToPath([sheet]), WHITE) },
      { name: 'grid', body: fill(lib.ringsToPath(grid), '#BFD3E8') },
      { name: 'extent', body: fill(lib.rectRingPath(ex.x, ex.y, ex.w, ex.h, 22), magenta) },
      { name: 'flap-shadow', flatOnly: true, body: castShadow },
      { name: 'flap', glass: true, group: 'flap', defs: undersideDefs, body: `<path d="${flap}" fill="${undersideFill}"/>` },
    ],
    small: {
      layers: [
        ...(v.beneath ? [{ name: 'beneath', body: fill(lib.ringsToPath([beneathRing]), '#CDD8E4') }] : []),
        { name: 'sheet', body: fill(lib.ringsToPath([sheet]), WHITE) },
        { name: 'extent', body: fill(lib.rectRingPath(ex.x - 16, ex.y - 8, ex.w + 56, ex.h + 60, 46), magenta) },
        { name: 'flap-shadow', body: `<path d="${flapAt(-14, 18)}" fill="${shade}" fill-opacity="0.3"/>` },
        { name: 'flap', body: `<path d="${flap}" fill="${undersideSmall}"/>` },
      ],
    },
  };
}

const peelSteps = [
  {
    key: 'peelbig', bundle: 'PeelBig', name: 'C1 · Bigger curl', c: 340, underside: 'flat', beneath: false,
    comment: 'The flap grown from 250 to 340 on the tile.',
    why: 'The flap grown from 250 to 340px on the tile, nothing else changed: at 64px the curl is now a shape rather than a notch.',
    tradeoff: 'The underside is still one flat tint, so the curl reads as a fold, not a roll.',
  },
  {
    key: 'peelrolled', bundle: 'PeelRolled', name: 'C2 · Rolled underside', c: 340, underside: 'rolled', beneath: false,
    comment: 'Underside shaded from grey at the crease to white at the tip, with a cast shadow.',
    why: 'C1 with the underside shaded from grey at the crease to white at the tip, and a cast shadow on the sheet under it: the corner is lifting off the page.',
    tradeoff: 'Grey on white on orange: the roll is subtle on a dark desktop.',
  },
  {
    key: 'peeltinted', bundle: 'PeelTinted', name: 'C3 · Tinted underside', c: 340, underside: 'tinted', beneath: false,
    comment: 'The roll in pale magenta.',
    why: 'C2 with the underside in pale magenta, the same family as the extent: the peel becomes a colour event as well as a shape, and the icon carries the UI accent twice.',
    tradeoff: 'Pink on orange is a bold pairing; the underside of a printed sheet is not usually pink.',
  },
  {
    key: 'peelbeneath', bundle: 'PeelBeneath', name: 'C4 · Layer beneath', c: 340, underside: 'rolled', beneath: true,
    comment: 'A second, grey-blue sheet under the corner.',
    why: 'C2 with a second, grey-blue sheet showing under the lifted corner and along two edges: one layer comes away, the rest stay on the server.',
    tradeoff: 'Two sheets and a flap is the busiest of the four, and the edge of the sheet beneath is gone by 32px.',
  },
];

// ---- Locator (kept, not built) -----------------------------------------------------
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
    key: 'locator', bundle: 'Locator', file: 'locator.svg', name: 'D · Locator',
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
  return peelSteps.map(v => peel(lib, v));
}
