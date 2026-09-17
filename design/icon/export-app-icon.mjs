// Exports one concept as the app's icon assets:
//
//   node design/icon/export-app-icon.mjs <concepts.mjs> <key> <out-dir>
//
// Writes <out-dir>/AppIcon.icon (the Icon Composer bundle Xcode compiles),
// <out-dir>/ArcGISExplorer-icon.svg (flat master) and
// <out-dir>/ArcGISExplorer-icon-small.svg (the 32/16px master), replacing what is there.
// scripts/render-app-icon.sh turns the two masters into the legacy .icns.
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { mkdir, rm, writeFile } from 'node:fs/promises';
import * as lib from './icon-lib.mjs';

const [conceptsPath, key, outDir] = process.argv.slice(2);
if (!conceptsPath || !key || !outDir) {
  console.error('usage: node export-app-icon.mjs <concepts.mjs> <key> <out-dir>');
  process.exit(1);
}

const mod = await import(pathToFileURL(resolve(conceptsPath)).href);
const concept = (await mod.default(lib)).find(c => c.key === key);
if (!concept) {
  console.error(`${conceptsPath} has no concept with key "${key}"`);
  process.exit(1);
}
if (!concept.layers || !concept.small) {
  console.error(`concept "${key}" needs layers and a small variant to be exported`);
  process.exit(1);
}

const out = resolve(outDir);
await mkdir(out, { recursive: true });
await rm(join(out, 'AppIcon.icon'), { recursive: true, force: true });
const bundle = await lib.writeIconBundle({ ...concept, bundle: 'AppIcon' }, out);
await writeFile(join(out, 'ArcGISExplorer-icon.svg'), lib.flatMaster(concept));
await writeFile(join(out, 'ArcGISExplorer-icon-small.svg'), lib.flatMaster({ ...concept, fill: concept.small.fill ?? concept.fill }, concept.small.layers));
console.log(`exported "${key}" to ${bundle}, ArcGISExplorer-icon.svg and ArcGISExplorer-icon-small.svg in ${out}`);
