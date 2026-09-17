// Builds app-icon concept SVGs, Icon Composer bundles and the preview page from a
// concepts module.
//
//   node design/icon/build-icons.mjs <concepts.mjs> <preview-dir> [renders-dir]
//
// The concepts module default-exports an async function (lib) => [concept, …] and
// holds every design decision; icon-lib.mjs holds the mechanics. A layered concept
// ({ fill, layers, small? }) yields its flat master(s) and a bundle under
// design/icon/bundles/; a concept that supplies `svg` directly is used as is. With a
// renders directory (PNGs named <key>-<px>.png, see claude-scripts/icon_compile_bundles.sh)
// the preview also shows what actool makes of each bundle. See README.md.
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import * as lib from './icon-lib.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const [conceptsPath, previewDir, rendersDir] = process.argv.slice(2);
if (!conceptsPath || !previewDir) {
  console.error('usage: node build-icons.mjs <concepts.mjs> <preview-dir> [renders-dir]');
  process.exit(1);
}

const mod = await import(pathToFileURL(resolve(conceptsPath)).href);
const concepts = await mod.default(lib);
if (!Array.isArray(concepts) || concepts.length === 0) {
  console.error(`${conceptsPath} returned no concepts`);
  process.exit(1);
}

let bundles = 0;
for (const c of concepts) {
  if (!c.layers) continue;
  c.svg = lib.flatMaster(c);
  if (c.small) c.svgSmall = lib.flatMaster({ ...c, fill: c.small.fill ?? c.fill }, c.small.layers);
  await lib.writeIconBundle(c, join(here, 'bundles'));
  bundles++;
}

await lib.writeConcepts(concepts, here);
const renders = rendersDir ? await lib.loadRenders(concepts, rendersDir) : null;
await lib.buildPreview(concepts, previewDir, mod.lede ?? '', renders);
console.log(`wrote ${concepts.length} concept SVGs and ${bundles} bundles to ${here}, icon-preview.html and arcgis-explorer-icon.html to ${previewDir}${renders ? ' (with actool renders)' : ''}`);
