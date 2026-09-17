// Builds app-icon concept SVGs and the preview page from a concepts module.
//
//   node design/icon/build-icons.mjs <concepts.mjs> <preview-dir>
//
// The concepts module default-exports an async function (lib) => [{ key, file, name,
// svg, why, tradeoff }] and holds every design decision; icon-lib.mjs holds the
// mechanics (tile, geography projection, preview page). See README.md.
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import * as lib from './icon-lib.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const [conceptsPath, previewDir, ledeArg] = process.argv.slice(2);
if (!conceptsPath || !previewDir) {
  console.error('usage: node build-icons.mjs <concepts.mjs> <preview-dir> [lede]');
  process.exit(1);
}

const mod = await import(pathToFileURL(resolve(conceptsPath)).href);
const concepts = await mod.default(lib);
if (!Array.isArray(concepts) || concepts.length === 0) {
  console.error(`${conceptsPath} returned no concepts`);
  process.exit(1);
}

await lib.writeConcepts(concepts, here);
await lib.buildPreview(concepts, previewDir, ledeArg ?? mod.lede ?? '');
console.log(`wrote ${concepts.length} concept SVGs to ${here}, icon-preview.html and arcgis-explorer-icon.html to ${previewDir}`);
