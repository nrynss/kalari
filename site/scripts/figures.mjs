// Build-time figures for the judges walkthrough.
//
// Reads only committed evidence, recomputes every number the judges page
// shows, and fails the build when a computed figure disagrees with
// bench/RESULTS.md. No figure on the page is typed by hand.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { globSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..');

let commit = 'main';
try {
  commit = execSync('git rev-parse HEAD', { cwd: root }).toString().trim();
} catch {
  commit = 'main';
}
const repo = 'https://github.com/nrynss/kalari';
const demo = 'https://kalari.nryn.dev';
const blob = (p) => `${repo}/blob/${commit}/${p}`;
const runUrl = (id) => `${demo}/run.html?id=${id}`;

const readJson = (p) => JSON.parse(readFileSync(path.join(root, p), 'utf8'));
const results = readFileSync(path.join(root, 'bench/RESULTS.md'), 'utf8');
const fail = (msg) => {
  console.error(`figures: FAIL ${msg}`);
  process.exit(1);
};
const check = (name, got, want) => {
  if (JSON.stringify(got) !== JSON.stringify(want)) fail(`${name}: got ${JSON.stringify(got)} want ${JSON.stringify(want)}`);
};

// The frozen comparison rows.
const kalariPaths = globSync('bench/runs/kalari/condition-*.json', { cwd: root }).sort();
const referencePaths = globSync('bench/runs/reference/condition-*.json', { cwd: root }).sort();
check('kalari file count', kalariPaths.length, 20);
check('reference file count', referencePaths.length, 40);

const groups = {};
for (const p of [...kalariPaths, ...referencePaths]) {
  const doc = readJson(p);
  const key = `${doc.arm}-${doc.condition}-${doc.upgrade}`;
  (groups[key] ??= []).push({ path: p, doc });
}

// Parse the EXPECTED block in RESULTS.md section 10 and compare exactly.
import { execFileSync } from 'node:child_process';
const EXPECTED = JSON.parse(execFileSync('python3', ['site/scripts/expected.py'], { cwd: root }).toString());

const r3 = (n) => Math.round(n * 1000) / 1000;
const r6 = (n) => Math.round(n * 1000000) / 1000000;

for (const [key, want] of Object.entries(EXPECTED)) {
  const items = groups[key];
  if (!items) fail(`missing group ${key}`);
  check(`${key} repeats`, items.length, 5);
  const m = items.map((x) => x.doc.measures);
  const agents = items.map((x) => x.doc.http_retries?.agent ?? {});
  const gradings = items.map((x) => x.doc.http_retries?.grading ?? {});
  const known = agents.filter((a) => a.status === 'ok');
  const sum = (f) => m.reduce((a, x) => a + (x[f] ?? 0), 0);
  const got = {
    P: m.filter((x) => x.verdict === 'PASS').length,
    R: m.filter((x) => x.right_first_time).length,
    sb: sum('sandbox_runs'),
    wall: r3(sum('wall_time_s')),
    stuck: r3(sum('time_stuck_s')),
    cost: r6(items.reduce((a, x) => a + x.doc.cost_usd, 0)),
    tin: sum('tokens_input'),
    tout: sum('tokens_output'),
    lost: 0,
    dup: 0,
    capped: items.filter((x) => x.doc.session_capped).length,
    ag_unknown: agents.filter((a) => a.status === 'unknown').length,
    ag: [
      known.reduce((a, x) => a + (x.b5_429_responses ?? 0), 0),
      known.reduce((a, x) => a + (x.matching_retry_attempts ?? 0), 0),
      known.reduce((a, x) => a + (x.successful_matching_retries ?? 0), 0),
    ],
    gr: [
      gradings.reduce((a, x) => a + (x.b5_429_responses ?? 0), 0),
      gradings.reduce((a, x) => a + (x.matching_retry_attempts ?? 0), 0),
      gradings.reduce((a, x) => a + (x.successful_matching_retries ?? 0), 0),
    ],
  };
  for (const x of items) {
    const lost = x.doc.records_lost ?? x.doc.measures.records_lost;
    const dup = x.doc.records_duplicated ?? x.doc.measures.records_duplicated;
    if ((lost ?? 0) !== 0) fail(`${key} lost nonzero`);
    if ((dup ?? 0) !== 0) fail(`${key} dup nonzero`);
  }
  for (const [k, v] of Object.entries(want)) check(`${key} ${k}`, got[k], v);
}

// Zero-lesson finding: no Kalari row published a lesson.
for (const p of kalariPaths) {
  const doc = readJson(p);
  check(`${p} lessons`, doc.lessons_published, []);
  check(`${p} recall`, doc.recall_required_checks, []);
  check(`${p} killed runs`, doc.killed_timeout_runs, 0);
}

// Arm-level summaries quoted on the judges page.
const arm = (paths) => {
  const docs = paths.map((p) => readJson(p));
  return {
    sessions: docs.length,
    cost: r6(docs.reduce((a, d) => a + d.cost_usd, 0)),
    wall: r3(docs.reduce((a, d) => a + d.measures.wall_time_s, 0)),
    stuck: r3(docs.reduce((a, d) => a + d.measures.time_stuck_s, 0)),
    runs: docs.reduce((a, d) => a + d.measures.sandbox_runs, 0),
  };
};
const kalariArm = arm(kalariPaths);
const referenceArm = arm(referencePaths);
check('kalari sessions', kalariArm.sessions, 20);
check('reference sessions', referenceArm.sessions, 40);
check('kalari runs', kalariArm.runs, 58);
check('reference runs', referenceArm.runs, 85);
check('kalari cost per session', Math.round((kalariArm.cost / 20) * 1000) / 1000, 0.019);
check('reference cost per session', Math.round((referenceArm.cost / 40) * 1000) / 1000, 0.082);
check('cost ratio', Math.round((referenceArm.cost / 40 / (kalariArm.cost / 20)) * 10) / 10, 4.2);
check('kalari wall per session', Math.round(kalariArm.wall / 20), 26);
check('reference wall per session', Math.round(referenceArm.wall / 40), 84);
check('wall ratio', Math.round((referenceArm.wall / 40 / (kalariArm.wall / 20)) * 10) / 10, 3.3);
check('kalari stuck', kalariArm.stuck, 0);
check('reference stuck rounded', Math.round(referenceArm.stuck), 799);

// Section 2 display table: every row must match the recomputed aggregates.
const table = {};
for (const line of results.split('\n')) {
  const cells = line.split('|').map((c) => c.trim());
  if (cells.length < 9 || !/^\d$/.test(cells[1])) continue;
  const key = `${cells[1] === '4' || cells[1] === '5' ? 'kalari' : 'reference'}-${cells[1]}-${cells[2]}`;
  table[key] = {
    cost: Number(cells[3]),
    runs: Number(cells[4]),
    wall: Number(cells[5]),
    stuck: Number(cells[6]),
  };
}
for (const [key, want] of Object.entries(EXPECTED)) {
  const row = table[key];
  if (!row) fail(`section 2 table missing ${key}`);
  const items = groups[key];
  const cost = r6(items.reduce((a, x) => a + x.doc.cost_usd, 0));
  const wall = r3(items.reduce((a, x) => a + x.doc.measures.wall_time_s, 0));
  const stuck = r3(items.reduce((a, x) => a + x.doc.measures.time_stuck_s, 0));
  const runs = items.reduce((a, x) => a + x.doc.measures.sandbox_runs, 0);
  const close = (a, b) => Math.abs(a - b) < 0.051;
  if (!close(row.cost, cost)) fail(`${key} table cost: got ${row.cost} want ${cost}`);
  check(`${key} table runs`, row.runs, runs);
  if (!close(row.wall, wall)) fail(`${key} table wall: got ${row.wall} want ${wall}`);
  if (!close(row.stuck, stuck)) fail(`${key} table stuck: got ${row.stuck} want ${stuck}`);
}

// The reference problem that motivates Kalari.
const refReadme = readFileSync(path.join(root, 'bench/reference-paging/README.md'), 'utf8');
for (const s of ['imported 100 items', '2,431']) {
  if (!refReadme.includes(s)) fail(`reference README lost string: ${s}`);
}

// Containment runs: ordinary published runs with a cap and a verdict.
const containment = [];
for (const n of [1, 2]) {
  const lines = readFileSync(
    path.join(root, `tests/live/containment-evidence/run-${n}.jsonl`),
    'utf8',
  )
    .split('\n')
    .filter((l) => l.trim().length > 0)
    .map((l) => JSON.parse(l));
  const run = lines.find((r) => r.kind === 'run');
  const held = lines.find((r) => r.kind === 'containment');
  containment.push({
    n,
    verdict: run.payload.verdict.verdict ?? run.payload.verdict,
    exit_code: run.payload.verdict.exit_code ?? null,
    wall_ms: run.payload.timings.wall_ms,
    passed: run.payload.verdict.passed,
    cap_ms: run.payload.request.caps.timeout_ms,
    pages: held.payload.result.pages_fetched ?? null,
    boundary: held.payload.network.observed ?? held.payload.network,
    cleanup: held.payload.cleanup ?? null,
    evidence: `tests/live/containment-evidence/run-${n}.jsonl`,
    evidenceUrl: blob(`tests/live/containment-evidence/run-${n}.jsonl`),
  });
}
check('run 1 verdict', containment[0].verdict, 'exited');
check('run 1 wall', containment[0].wall_ms, 437);
check('run 2 verdict', containment[1].verdict, 'killed_timeout');
check('run 2 wall', containment[1].wall_ms, 5009);
check('run 2 cap', containment[1].cap_ms, 5000);
check('run 2 pages', containment[1].pages, 68);

// The showcase grid: 14 committed runs, manufactured, kept apart.
const showcaseReadme = readFileSync(
  path.join(root, 'bench/showcase/disbursements/README.md'),
  'utf8',
);
const MODEL_NAMES = {
  glm: 'GLM 5.3 Flash',
  qwen27b: 'Qwen3.8 27B',
  muse: 'Muse Glimmer 30B',
  mimo: 'MiMo V2.6 Flash',
  deepseek: 'DeepSeek V4.1 Flash',
};
const modelFromFile = (p, doc) =>
  MODEL_NAMES[doc.model?.split('-')[0]] ??
  MODEL_NAMES[path.basename(p, '.json').split('-')[0]] ??
  'unknown';
const showcase = [];
for (const p of globSync('bench/showcase/disbursements/runs/*/*.json', { cwd: root }).sort()) {
  const doc = readJson(p);
  const grade = doc.grade ?? {};
  const label = path.basename(p, '.json');
  const row = {
    path: p,
    fileUrl: blob(p),
    arm: doc.arm,
    model: modelFromFile(p, doc),
    label,
    verdict: grade.verdict ?? doc.measures?.verdict ?? null,
    lost: doc.records_lost ?? 0,
    dup: doc.records_duplicated ?? 0,
    changed: doc.records_mismatched ?? 0,
    wall: doc.wall_time_s ?? doc.measures?.wall_time_s ?? null,
    cost: doc.cost_usd ?? null,
  };
  showcase.push(row);
}
check('showcase run count', showcase.length, 14);
check(
  'showcase reference fails',
  showcase.filter((r) => r.arm === 'reference' && r.verdict === 'FAIL').length,
  5,
);
check(
  'showcase reference silent corruption',
  showcase.filter((r) => r.arm === 'reference' && r.verdict === 'FAIL' && r.changed === 23).length,
  4,
);
check(
  'showcase reference loud failure',
  showcase.filter((r) => r.arm === 'reference' && r.verdict === 'FAIL' && r.lost === 2341).length,
  1,
);
check(
  'showcase kalari catches',
  showcase.filter((r) => r.arm === 'kalari' && r.changed === 23).length,
  3,
);
for (const r of showcase) {
  if (!showcaseReadme.includes(r.path.split('runs/')[1].replace('.json', '')))
    fail(`showcase README missing ${r.path}`);
}

const groupRows = Object.entries(groups)
  .map(([key, items]) => {
    const [armName, cond, upgrade] = key.split('-');
    const m = items.map((x) => x.doc.measures);
    const sum = (f) => m.reduce((a, x) => a + (x[f] ?? 0), 0);
    return {
      key,
      arm: armName,
      condition: Number(cond),
      upgrade,
      pass: `${m.filter((x) => x.verdict === 'PASS').length}/5`,
      rft: `${m.filter((x) => x.right_first_time).length}/5`,
      cost: r6(items.reduce((a, x) => a + x.doc.cost_usd, 0)),
      runs: sum('sandbox_runs'),
      wall: Math.round(sum('wall_time_s') * 10) / 10,
      stuck: Math.round(sum('time_stuck_s') * 10) / 10,
      tin: sum('tokens_input'),
      tout: sum('tokens_output'),
      repeats: items.map((x) => ({
        file: x.path,
        fileUrl: blob(x.path),
        runUrl: runUrl(x.doc.run_id),
      })),
    };
  })
  .sort((a, b) => a.arm.localeCompare(b.arm) || a.condition - b.condition || a.upgrade.localeCompare(b.upgrade));

const figures = {
  commit,
  repo,
  demo,
  frozen: {
    sessions: 60,
    kalariSessions: 20,
    referenceSessions: 40,
    kalari: { costPerSession: 0.019, wallPerSession: 26, stuck: 0, runs: 58 },
    reference: { costPerSession: 0.082, wallPerSession: 84, stuck: 799, runs: 85 },
    costRatio: 4.2,
    wallRatio: 3.3,
    groups: groupRows,
  },
  containment,
  showcase,
  referenceProblem: { items: 2431, imported: 100, lost: 2331 },
};

mkdirSync(path.join(here, '..', 'src', 'data'), { recursive: true });
writeFileSync(
  path.join(here, '..', 'src', 'data', 'figures.json'),
  JSON.stringify(figures, null, 2) + '\n',
);
console.log('figures: OK (60 frozen rows, 2 containment runs, 14 showcase runs)');
