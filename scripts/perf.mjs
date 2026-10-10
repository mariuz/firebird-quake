// perf.mjs – the benchmarks as numbers kept from commit to commit: runs bench, bench:qc (interpreted and
// with every function compiled) and bench:paint, each writing its timings to a JSON (BENCH_JSON), and
// compares them with the history the deployed site serves (perf-history.json: the last 200 runs). Each
// number is set against the median of the last five runs; one more than 50 % and 1 ms (or µs) slower is a
// warning (a CI annotation, not a failure: a number moves by 10 to 35 % from one run to the next). Writes the history with this
// run added to dist/perf-history.json for the build to deploy, and a table to the job summary.
//
//   node scripts/perf.mjs                                    against the deployed history
//   node scripts/perf.mjs --baseline=path/to/history.json    against a file (or none: --baseline=)
//   NODE_USE_ENV_PROXY=1 node scripts/perf.mjs               behind a proxy

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const arg = (name, dflt) => { const a = process.argv.find((x) => x.startsWith(`--${name}=`)); return a ? a.slice(name.length + 3) : dflt; };
const baseline = arg('baseline', 'https://mariuz.github.io/firebird-quake/perf-history.json');
const outFile = arg('out', path.join(root, 'dist/perf-history.json'));
const KEEP = 200, WINDOW = 5, SLOWER = 1.5, BY = 1;

const RUNS = [
  ['tic', 'scripts/bench.mjs', {}],
  ['qc', 'scripts/qcvm-bench.mjs', {}],
  ['qcjit', 'scripts/qcvm-bench.mjs', { QCJIT: 'all' }],
  ['paint', 'scripts/paint-bench.mjs', {}],
];
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'perf-'));
const metrics = {};
for (const [group, script, env] of RUNS) {
  const file = path.join(tmp, `${group}.json`);
  const t0 = performance.now();
  execFileSync(process.execPath, [path.join(root, script)], { cwd: root, env: { ...process.env, ...env, BENCH_JSON: file }, stdio: ['ignore', 'ignore', 'inherit'] });
  for (const [k, v] of Object.entries(JSON.parse(fs.readFileSync(file, 'utf8')))) if (Number.isFinite(v)) metrics[`${group}: ${k}`] = +v.toFixed(2);
  console.log(`${group.padEnd(6)} ${((performance.now() - t0) / 1000).toFixed(0)} s`);
}

let history = [];
if (baseline) {
  try {
    const text = /^https?:/.test(baseline) ? await fetch(baseline).then((r) => (r.ok ? r.text() : '[]')) : fs.readFileSync(baseline, 'utf8');
    history = JSON.parse(text);
    if (!Array.isArray(history)) history = [];
  } catch (e) { console.log(`no history (${e.message})`); }
}
const git = (...a) => { try { return execFileSync('git', a, { cwd: root, encoding: 'utf8' }).trim(); } catch { return null; } };
const run = { commit: process.env.GITHUB_SHA ?? git('rev-parse', 'HEAD'), date: new Date().toISOString(), runner: `${os.cpus()[0]?.model ?? '?'} ×${os.cpus().length}`, metrics };

// against the median of the last runs that have the number
const median = (a) => [...a].sort((x, y) => x - y)[a.length >> 1];
const rows = [], slower = [];
for (const [k, v] of Object.entries(metrics)) {
  const past = history.map((h) => h.metrics?.[k]).filter(Number.isFinite).slice(-WINDOW);
  const base = past.length ? median(past) : null;
  const ratio = base ? v / base : null;
  rows.push([k, v, base, ratio]);
  if (ratio && ratio > SLOWER && v - base > BY) slower.push(`${k}: ${v} against ${base} (${Math.round((ratio - 1) * 100)} % slower)`);
}
const fmt = (x) => (x == null ? '–' : String(+x.toFixed(2)));
const table = [`| benchmark (ms, µs where it says) | this run | median of the last ${WINDOW} | change |`, '|---|---:|---:|---:|',
  ...rows.map(([k, v, b, r]) => `| ${k} | ${fmt(v)} | ${fmt(b)} | ${r ? `${r > 1 ? '+' : ''}${Math.round((r - 1) * 100)} %` : '–'} |`)].join('\n');
console.log(table);
if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, `## Performance\n\n${history.length} runs of history, on ${run.runner}\n\n${table}\n`);
for (const s of slower) console.log(process.env.GITHUB_ACTIONS ? `::warning title=Slower::${s}` : `slower: ${s}`);

fs.mkdirSync(path.dirname(outFile), { recursive: true });
fs.writeFileSync(outFile, JSON.stringify([...history, run].slice(-KEEP)));
console.log(`${outFile}: ${Math.min(history.length + 1, KEEP)} runs`);
fs.rmSync(tmp, { recursive: true, force: true });
