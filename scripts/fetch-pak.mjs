// fetch-pak.mjs – get the Quake shareware data into public/pak/pak0.pak.
//
// The shareware release (quake106.zip, 9 MB) is freely redistributable. It
// holds resource.1, an LHA archive, with id1/pak0.pak inside. Extracting LHA
// needs a tool: 7-Zip (7z), lha or lhasa. On Debian/Ubuntu CI:
//   sudo apt-get install -y lhasa
//
//   node scripts/fetch-pak.mjs            downloads and extracts
//   PAK=/path/to/pak0.pak node scripts/fetch-pak.mjs   copies a pak you have

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const outDir = path.join(root, 'public/pak');
const out = path.join(outDir, 'pak0.pak');
fs.mkdirSync(outDir, { recursive: true });

if (process.env.PAK) {
  fs.copyFileSync(process.env.PAK, out);
  console.log(`copied ${process.env.PAK} → ${path.relative(root, out)}`);
  process.exit(0);
}
if (fs.existsSync(out)) {
  console.log(`${path.relative(root, out)} already present (${(fs.statSync(out).size / 1048576).toFixed(1)} MB)`);
  process.exit(0);
}

const URLS = [
  'https://ftp.netbsd.org/pub/pkgsrc/distfiles/quake106.zip',
  'https://distfiles.macports.org/quake/quake106.zip',
];
const MD5 = '8cee4d03ee092909fdb6a4f84f0c1357';

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'quake106-'));
let zip = null;
for (const url of URLS) {
  try {
    console.log(`downloading ${url}…`);
    const resp = await fetch(url);
    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
    const buf = Buffer.from(await resp.arrayBuffer());
    const { createHash } = await import('node:crypto');
    const md5 = createHash('md5').update(buf).digest('hex');
    if (md5 !== MD5) throw new Error(`md5 ${md5} does not match ${MD5}`);
    zip = path.join(tmp, 'quake106.zip');
    fs.writeFileSync(zip, buf);
    break;
  } catch (e) {
    console.warn(`  ${e.message}`);
  }
}
if (!zip) {
  console.error('could not download quake106.zip; put a pak0.pak at public/pak/pak0.pak yourself (PAK=... node scripts/fetch-pak.mjs)');
  process.exit(1);
}

// unzip quake106.zip → resource.1 (the zip is "stored"/deflated; use the platform's tools)
const run = (cmd, args) => execFileSync(cmd, args, { stdio: 'pipe', cwd: tmp });
const which = (cmds) => {
  for (const c of cmds) {
    try { execFileSync(process.platform === 'win32' ? 'where' : 'which', [c], { stdio: 'pipe' }); return c; } catch { /* next */ }
  }
  return null;
};
const sevenZip = which(['7z', '7za', '7zz']) ?? (process.platform === 'win32' && fs.existsSync('C:/Program Files/7-Zip/7z.exe') ? 'C:/Program Files/7-Zip/7z.exe' : null);
try {
  if (sevenZip) run(sevenZip, ['x', '-y', 'quake106.zip']);
  else if (which(['unzip'])) run('unzip', ['-o', 'quake106.zip']);
  else if (process.platform === 'win32') run('powershell', ['-NoProfile', '-Command', `Expand-Archive -Force quake106.zip ${tmp}`]);
  else throw new Error('no unzip tool found');
  const res1 = path.join(tmp, 'resource.1');
  if (!fs.existsSync(res1)) throw new Error('resource.1 not found in the zip');
  if (sevenZip) run(sevenZip, ['x', '-y', '-olha', 'resource.1']);
  else if (which(['lha'])) { fs.mkdirSync(path.join(tmp, 'lha'), { recursive: true }); run('lha', ['xw=lha', 'resource.1']); }
  else if (which(['lhasa'])) { fs.mkdirSync(path.join(tmp, 'lha'), { recursive: true }); run('lhasa', ['xw=lha', 'resource.1']); }
  else throw new Error('resource.1 is an LHA archive: install 7-Zip, lha or lhasa to extract it');
  const found = findFile(path.join(tmp, 'lha'), /^pak0\.pak$/i);
  if (!found) throw new Error('pak0.pak not found inside resource.1');
  fs.copyFileSync(found, out);
  console.log(`wrote ${path.relative(root, out)} (${(fs.statSync(out).size / 1048576).toFixed(1)} MB)`);
} catch (e) {
  console.error(e.message);
  process.exit(1);
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}

function findFile(dir, re) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { const r = findFile(p, re); if (r) return r; } else if (re.test(e.name)) return p;
  }
  return null;
}
