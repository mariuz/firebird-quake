// build.mjs – assemble the static site into dist/.
//
//   node scripts/build.mjs            build
//   node scripts/build.mjs --serve    build, then serve dist/ on :8080 WITHOUT
//                                     COOP/COEP headers – exactly like GitHub
//                                     Pages – so the service worker is tested.
//
// Everything is referenced relatively: a project site lives under /<repo>/.

import { build } from 'esbuild-wasm';
import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import crypto from 'node:crypto';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';
import { FirebirdBrowser, DirectTransport } from 'firebird-wasm/browser';
import { createSchema, loaderSql, SQL_FILES } from '../src/loader.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const OUT = path.join(root, 'dist');
const PKG = path.join(root, 'node_modules/firebird-wasm/dist');

// wasm-loader.js has a Node-only require() of the Emscripten glue; browsers
// take the globalThis path, so keep the glue out of the bundle.
const EXTERNAL = ['*firebird-embedded.js'];

fs.rmSync(OUT, { recursive: true, force: true });
fs.mkdirSync(OUT, { recursive: true });

// The schema as a database image: createSchema (every table, procedure and generated loader, 3 to 4 s in
// the browser) run here once, the database dumped and gzipped (0.7 MB), so the page opens it in a tenth
// of a second instead. Its name carries a hash of what built it (the SQL files, the generated loaders,
// the engine's version), and the page asks for that name, so an image never outlives its code.
// SCHEMA_IMAGE=0 skips it (the page then builds the schema itself, as before).
let schemaImage = null;
if (process.env.SCHEMA_IMAGE !== '0') {
  const sql = Object.fromEntries(SQL_FILES.map((n) => [n, fs.readFileSync(path.join(root, `sql/${n}.sql`), 'utf8')]));
  const engine = JSON.parse(fs.readFileSync(path.join(root, 'node_modules/firebird-wasm/package.json'), 'utf8')).version;
  const hash = crypto.createHash('sha256').update(engine).update(loaderSql()).update(SQL_FILES.map((n) => sql[n].replace(/\r\n/g, '\n')).join('\n')).digest('hex').slice(0, 12);
  const db = new FirebirdBrowser(`memory://schema-${hash}`, { transport: new DirectTransport() });
  await createSchema(db, sql);
  const bytes = await db.dumpDataDir();
  await db.close();
  schemaImage = `schema-${hash}.fdb.gz`;
  fs.writeFileSync(path.join(OUT, schemaImage), zlib.gzipSync(bytes, { level: 9 }));
}

await build({
  entryPoints: [path.join(root, 'src/main.js')],
  outfile: path.join(OUT, 'main.js'),
  bundle: true,
  format: 'esm',
  platform: 'browser',
  target: 'es2020',
  sourcemap: true,
  minify: true,
  loader: { '.sql': 'text' },
  external: EXTERNAL,
  define: { __SCHEMA_IMAGE__: JSON.stringify(schemaImage) },
  logLevel: 'warning',
});

// The engine Worker: a classic script that loads the Emscripten glue first and
// finds the .wasm next to itself, whatever path prefix the site is served from.
const worker = await build({
  entryPoints: [path.join(PKG, 'browser/worker-entry.js')],
  bundle: true,
  format: 'iife',
  platform: 'browser',
  target: 'es2020',
  write: false,
  minify: true,
  external: EXTERNAL,
  logLevel: 'warning',
});
fs.writeFileSync(
  path.join(OUT, 'firebird-engine-worker.js'),
  "importScripts(new URL('./firebird-embedded.js', self.location.href).href);\n" +
    'self.FIREBIRD_WORKER_OPTIONS = { locateFile: (f) => new URL(f, self.location.href).href };\n' +
    worker.outputFiles[0].text,
);

for (const f of ['firebird-embedded.js', 'firebird-embedded.wasm']) {
  fs.copyFileSync(path.join(PKG, 'wasm', f), path.join(OUT, f));
}

// public/ verbatim (index.html, css, service worker, pak/ if present)
fs.cpSync(path.join(root, 'public'), OUT, { recursive: true });
// GitHub Pages runs Jekyll by default, which drops _underscored paths.
fs.writeFileSync(path.join(OUT, '.nojekyll'), '');

const size = (dir) => fs.readdirSync(dir, { withFileTypes: true })
  .reduce((s, e) => s + (e.isDirectory() ? size(path.join(dir, e.name)) : fs.statSync(path.join(dir, e.name)).size), 0);
console.log(`dist/ ${(size(OUT) / 1024 / 1024).toFixed(1)} MB`);
if (!fs.existsSync(path.join(OUT, 'pak/pak0.pak'))) {
  console.warn('note: no public/pak/pak0.pak – run `npm run fetch-pak`, or pick a PAK in the page');
}

if (process.argv.includes('--serve')) {
  // --coi: send COOP/COEP from the server (for browsers without service workers); without it, the
  // page relies on coi-serviceworker.js exactly as it does on GitHub Pages.
  const coi = process.argv.includes('--coi');
  const TYPES = {
    '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
    '.wasm': 'application/wasm', '.map': 'application/json', '.pak': 'application/octet-stream', '.zip': 'application/zip', '.gz': 'application/gzip', '.svg': 'image/svg+xml',
  };
  const port = Number(process.env.PORT ?? 8080);
  http.createServer((req, res) => {
    const url = new URL(req.url, 'http://localhost');
    let file = path.join(OUT, decodeURIComponent(url.pathname));
    if (url.pathname.endsWith('/')) file = path.join(file, 'index.html');
    if (!path.resolve(file).startsWith(OUT) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
      res.writeHead(404).end('not found');
      return;
    }
    const headers = { 'Content-Type': TYPES[path.extname(file)] ?? 'application/octet-stream', 'Cache-Control': 'no-store' };
    if (coi) Object.assign(headers, { 'Cross-Origin-Opener-Policy': 'same-origin', 'Cross-Origin-Embedder-Policy': 'require-corp' });
    res.writeHead(200, headers);
    fs.createReadStream(file).pipe(res);
  }).listen(port, () => console.log(`serving dist/ on http://localhost:${port}/ (${coi ? 'with COOP/COEP' : 'no COOP/COEP, like Pages'})`));
}
