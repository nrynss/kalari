#!/usr/bin/env node
/* Regenerate the rendered fixture snapshots used by web/check.sh.

   This is a development tool, not part of the app and not part of the check.
   The app itself is plain ES modules and needs no Node. The check reads the
   committed snapshots. It verifies a sha256 for every rendered page and for
   every file under web/site/, so a stale snapshot fails the check.

   The script also writes `inputs.json`: for each page, the exact records the
   view was called with. The check derives its expected counts from those
   records, so a new record in the store changes the snapshot and the counts
   together.

       node web/fixture/render.mjs
*/

import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, "../..");
const SITE = path.join(REPO, "web/site");
const OUT = path.join(HERE, "rendered");
const { sessionView, runView, judgesView } = await import(
  path.join(SITE, "app/views.mjs")
);

function sha256(file) {
  return createHash("sha256").update(readFileSync(file)).digest("hex");
}

function walk(directory) {
  const files = [];
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const full = path.join(directory, entry.name);
    if (entry.isDirectory()) files.push(...walk(full));
    else if (entry.isFile()) files.push(full);
  }
  return files.sort();
}

function startServer() {
  return new Promise((resolve, reject) => {
    const child = spawn("python3", [path.join(HERE, "server.py"), "--port", "0"], {
      cwd: REPO,
      stdio: ["ignore", "pipe", "inherit"],
    });
    let buffer = "";
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      reject(new Error("the fixture server did not print its address"));
    }, 5000);
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      buffer += chunk;
      const line = buffer.split("\n")[0];
      if (line.startsWith("http://")) {
        clearTimeout(timer);
        resolve({ child, base: line.trim() });
      }
    });
    child.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.on("exit", (code) => {
      if (code && !buffer.startsWith("http://")) {
        clearTimeout(timer);
        reject(new Error(`the fixture server exited with ${code}`));
      }
    });
  });
}

async function getJson(base, route) {
  const response = await fetch(new URL(route, base));
  if (!response.ok) throw new Error(`${route} answered ${response.status}`);
  return response.json();
}

async function runDetailsFor(base, runs, benchmark) {
  const benchmarkIds = new Set(
    benchmark
      .filter((record) => record.kind === "benchmark" && typeof record.run_id === "string")
      .map((record) => record.run_id),
  );
  const otherIds = benchmark.length ? runs.filter((runId) => !benchmarkIds.has(runId)) : [];
  const results = await Promise.all(otherIds.map((runId) => getJson(base, `api/runs/${runId}`)));
  return Object.fromEntries(otherIds.map((runId, index) => [runId, results[index]]));
}

/* Synthetic records for the view tests. They exercise states the committed
   pilot store cannot show: a frozen condition-five row on its own, a complete
   frozen pair with measures, a second pilot row for one condition, and a page
   with a URL in each display path. Each record sets `synthetic: true`, so the
   validator treats it as a view fixture and never as a measurement. The source
   names a readable JSON fixture, so no record claims an unreadable source. */
function syntheticBenchmark({
  runId,
  sessionId,
  condition,
  upgrade,
  repeat = 1,
  provenance = "frozen",
  source = "web/fixture/sources/synthetic.json",
  measures = {},
}) {
  return {
    kind: "benchmark",
    session_id: sessionId,
    run_id: runId,
    change_kinds: ["pagination_changed"],
    payload: {
      schema: "kalari.benchmark.v1",
      synthetic: true,
      provenance,
      status: "valid",
      arm: condition === 5 ? "kalari" : "reference",
      condition,
      upgrade,
      repeat,
      behaviour: null,
      session_id: sessionId,
      session_continued: false,
      notes_attached: false,
      session_capped: false,
      session_cap_s: null,
      verdict: "PASS",
      right_first_time: true,
      right_first_time_basis: "fixture",
      sandbox_runs: null,
      sandbox_runs_against_v1: null,
      sandbox_runs_against_v2: null,
      wall_time_s: null,
      time_stuck_s: null,
      tokens_input: null,
      tokens_output: null,
      records_lost: null,
      records_duplicated: null,
      records_extra: null,
      records_mismatched: null,
      cost_usd: null,
      grade: null,
      first_v2_grade: null,
      grader_runs: null,
      opencode_exit: null,
      process_elapsed_s: null,
      source,
      notes: "Synthetic view fixture. Not a measurement.",
      ...measures,
    },
  };
}

function gradeFixture(records) {
  return {
    verdict: "PASS",
    output_present: true,
    records,
    unique: records,
    expected: records,
    missing: 0,
    extra: 0,
    duplicates: 0,
    mismatched: 0,
    unreadable_lines: 0,
  };
}

const frozenAfter = syntheticBenchmark({
  runId: "fixture-c5-payouts-r1",
  sessionId: "fixture-c5-payouts",
  condition: 5,
  upgrade: "payouts",
  measures: {
    sandbox_runs: 2,
    sandbox_runs_against_v1: 1,
    sandbox_runs_against_v2: 1,
    wall_time_s: 421.5,
    time_stuck_s: 0,
    tokens_input: 120000,
    tokens_output: 4000,
    records_lost: 0,
    records_duplicated: 0,
    records_extra: 0,
    records_mismatched: 0,
    cost_usd: 0.0123,
    grade: gradeFixture(2431),
    first_v2_grade: gradeFixture(2431),
    grader_runs: { final: { status: "EXIT 0", log_excerpt: "synced 2431 payouts\n" } },
  },
});
const frozenBeforeOther = syntheticBenchmark({
  runId: "fixture-c3-settlements-r1",
  sessionId: "fixture-c3-settlements",
  condition: 3,
  upgrade: "settlements",
});
const frozenBeforeSame = syntheticBenchmark({
  runId: "fixture-c3-payouts-r1",
  sessionId: "fixture-c3-payouts",
  condition: 3,
  upgrade: "payouts",
  measures: {
    sandbox_runs: 3,
    sandbox_runs_against_v1: 2,
    sandbox_runs_against_v2: 1,
    wall_time_s: 512,
    time_stuck_s: 0,
    tokens_input: 118000,
    tokens_output: 3900,
    records_lost: 1,
    records_duplicated: 0,
    records_extra: 0,
    records_mismatched: 0,
    cost_usd: 0.0119,
    grade: { ...gradeFixture(2430), missing: 1 },
    first_v2_grade: { ...gradeFixture(2430), missing: 1 },
    grader_runs: { final: { status: "EXIT 0", log_excerpt: "synced 2430 payouts\n" } },
  },
});
const frozenRuns = [frozenAfter.run_id, frozenBeforeOther.run_id, frozenBeforeSame.run_id];

/* A second pilot row for the fresh settlements column, with the same repeat
   number as one existing row. The contract allows repeats 1 to 5, and the copy
   still comes from both contrast columns: five distinct repeats each. */
const extraRun = syntheticBenchmark({
  runId: "fixture-extra-settlements-r5b",
  sessionId: "fixture-extra-settlements",
  condition: 3,
  upgrade: "settlements",
  repeat: 5,
  provenance: "pilot",
  measures: {
    sandbox_runs: 1,
    sandbox_runs_against_v1: 0,
    sandbox_runs_against_v2: 1,
    wall_time_s: 301.25,
    time_stuck_s: 0,
    tokens_input: 101000,
    tokens_output: 3100,
    records_lost: 0,
    records_duplicated: 0,
    records_extra: 0,
    records_mismatched: 0,
    cost_usd: 0.0098,
    grade: gradeFixture(2431),
    first_v2_grade: gradeFixture(2431),
    grader_runs: { final: { status: "EXIT 0", log_excerpt: "synced 2431 settlements\n" } },
  },
});

const endpointRecord = {
  kind: "run",
  session_id: "endpoint-fixture",
  run_id: "endpoint-fixture-r1",
  change_kinds: ["pagination_changed"],
  payload: {
    request: {
      workspace: "fixture",
      command: ["python3", "sync.py", "--base-url", "ENDPOINT"],
      caps: { timeout_ms: 120000, output_cap_bytes: 65536, memory_mib: 512 },
    },
    verdict: {
      verdict: "exited",
      exit_code: 0,
      wall_ms: 1200,
      stdout: "fetched https://api.example.invalid/payouts\n",
      stdout_truncated: false,
      stderr: "",
    },
    checks: [],
    check_results: [],
    illustrative: true,
  },
};
const endpointRuns = [endpointRecord.run_id];

/* One record per display path that shows a string from the store. Every path
   carries a URL, so the check can prove that each one is redacted. */
const redactionRun = {
  kind: "run",
  session_id: "redaction-fixture",
  run_id: "redaction-fixture-r1",
  change_kinds: ["pagination_changed"],
  payload: {
    request: {
      workspace: "workspace https://api.example.invalid/workspace",
      command: ["curl", "--url", "https://api.example.invalid/command"],
      caps: { timeout_ms: 120000, output_cap_bytes: 65536, memory_mib: 512 },
    },
    verdict: {
      verdict: "exited",
      exit_code: 0,
      wall_ms: 1200,
      stdout: "get https://api.example.invalid/stdout\npost //api.example.invalid/stdout-relative\n",
      stdout_truncated: false,
      stderr: "error //api.example.invalid/stderr\n",
    },
    checks: [],
    check_results: [
      {
        check_id: "check https://api.example.invalid/check-id",
        passed: true,
        detail: "checked 100% of the records against https://api.example.invalid/check-detail",
      },
    ],
    illustrative: true,
  },
};
const redactionLesson = {
  kind: "lesson",
  session_id: "redaction-fixture",
  run_id: "redaction-fixture-r1",
  change_kinds: ["pagination_changed"],
  payload: {
    change_kind: "pagination_changed",
    observation: "lesson https://api.example.invalid/lesson",
    check: {
      assertion: "assert //api.example.invalid/assertion",
      command: ["curl", "https://api.example.invalid/lesson-command"],
    },
  },
};
const redactionBenchmark = syntheticBenchmark({
  runId: "redaction-fixture-r1",
  sessionId: "redaction-fixture",
  condition: 3,
  upgrade: "payouts",
  provenance: "pilot",
  /* The source path itself carries a URL, so the run page must redact it. The
     file at that path is readable JSON, so the record passes the contract. */
  source: "web/fixture/sources/https://api.example.invalid/redaction.json",
  measures: {
    grade: {
      ...gradeFixture(2431),
      note: "grade note 100% complete https://api.example.invalid/grade-note",
    },
    grader_runs: { final: { status: "EXIT 0", log_excerpt: "log //api.example.invalid/grader-log\n" } },
    notes: "notes https://api.example.invalid/notes",
  },
});
const redactionRuns = [redactionRun.run_id, redactionBenchmark.run_id];
const redactionSession = {
  kind: "session",
  session_id: "redaction-fixture",
  run_id: "redaction-fixture-r1",
  change_kinds: ["pagination_changed"],
  payload: {
    title: "Redaction fixture",
    summary: "summary 0.75 complete, 100% of the rows, https://api.example.invalid/summary",
    arm: "kalari",
    illustrative: true,
    notes: "session note //api.example.invalid/session-note",
  },
};
const redactionChange = {
  kind: "change",
  session_id: "redaction-fixture",
  run_id: "redaction-fixture-r1",
  change_kinds: ["pagination_changed"],
  payload: {
    id: "change-1",
    kind: "pagination_changed",
    severity: "high",
    title: "The change https://api.example.invalid/change-title",
    summary: "change detail https://api.example.invalid/change",
    endpoint: "https://api.example.invalid/change-endpoint",
    source: "fixture",
  },
};
const redactionRadius = {
  kind: "blast-radius",
  session_id: "redaction-fixture",
  run_id: "redaction-fixture-r1",
  change_kinds: ["pagination_changed"],
  payload: {
    change_id: "change-1",
    call_sites: [{ path: "payout_sync.py", detail: "call site //api.example.invalid/call-site" }],
    note: "radius note https://api.example.invalid/radius",
  },
};
const redactionDecision = {
  kind: "decision",
  session_id: "redaction-fixture",
  run_id: "redaction-fixture-r1",
  change_kinds: ["pagination_changed"],
  payload: {
    question: "Is this an API change? https://api.example.invalid/question",
    question_set: "fixture",
    model: "clef",
    answer: { type: "probability", choice: "api_change", probabilities: {}, confidence: 0.8 },
  },
};

const { child, base } = await startServer();
try {
  const [benchmark, runs, sessions, lessons] = await Promise.all([
    getJson(base, "api/benchmark"),
    getJson(base, "api/runs"),
    getJson(base, "api/sessions"),
    getJson(base, "api/lessons"),
  ]);
  if (!sessions.includes("payouts-upgrade")) {
    throw new Error("the fixture has no payouts-upgrade session");
  }
  if (!runs.includes("pilot-c3-payouts-r5")) {
    throw new Error("the fixture has no pilot-c3-payouts-r5 run");
  }
  const containment = await getJson(base, "api/sessions/containment-runs");
  const containmentRuns = containment.filter((record) => record.kind === "containment");
  const containmentRunId = containmentRuns.find((record) => record.payload.result.verdict === "killed_timeout")?.run_id;
  const earlierRunId = containmentRuns.find((record) => record.run_id !== containmentRunId)?.run_id;
  if (!containmentRunId || !earlierRunId) throw new Error("the fixture needs a capped containment run and an earlier one");
  const containmentRunRecords = await getJson(base, `api/runs/${containmentRunId}`);
  const earlierRunRecords = await getJson(base, `api/runs/${earlierRunId}`);
  const sessionRecords = await getJson(base, "api/sessions/payouts-upgrade");
  const runRecords = await getJson(base, "api/runs/pilot-c3-payouts-r5");
  const illustrativeRunRecords = await getJson(base, "api/runs/payouts-attempt-1");
  const runDetails = await runDetailsFor(base, runs, benchmark);

  const benchmarkWithExtra = [...benchmark, extraRun];
  const runsWithExtra = [...runs, extraRun.run_id];
  const redactionRecords = [
    redactionSession,
    redactionChange,
    redactionRadius,
    redactionRun,
    redactionLesson,
    redactionBenchmark,
    redactionDecision,
  ];
  const redactionRunRecords = [redactionRun, redactionLesson, redactionBenchmark, redactionDecision];

  const snapshots = {
    judges: {
      view: "judges",
      args: { benchmark, runs, sessions, lessons, runDetails, containment },
      inputs: { benchmark, runs, sessions, lessons, containment },
    },
    "judges-empty": {
      view: "judges",
      args: { benchmark: [], runs, sessions, lessons },
      inputs: { benchmark: [], runs, sessions, lessons },
    },
    "judges-no-store": {
      view: "judges",
      args: { benchmark: [], runs: [], sessions: [], lessons: [] },
      inputs: { benchmark: [], runs: [], sessions: [], lessons: [] },
    },
    "judges-extra-run": {
      view: "judges",
      args: { benchmark: benchmarkWithExtra, runs: runsWithExtra, sessions, lessons, containment },
      inputs: { benchmark: benchmarkWithExtra, runs: runsWithExtra, sessions, lessons, containment },
    },
    "judges-frozen-after": {
      view: "judges",
      args: { benchmark: [frozenAfter], runs: frozenRuns, sessions: [], lessons: [] },
      inputs: { benchmark: [frozenAfter], runs: frozenRuns, sessions: [], lessons: [] },
    },
    "judges-frozen-pair": {
      view: "judges",
      args: { benchmark: [frozenAfter, frozenBeforeSame], runs: frozenRuns, sessions: [], lessons: [] },
      inputs: { benchmark: [frozenAfter, frozenBeforeSame], runs: frozenRuns, sessions: [], lessons: [] },
    },
    "judges-frozen-split": {
      view: "judges",
      args: { benchmark: [frozenAfter, frozenBeforeOther], runs: frozenRuns, sessions: [], lessons: [] },
      inputs: { benchmark: [frozenAfter, frozenBeforeOther], runs: frozenRuns, sessions: [], lessons: [] },
    },
    session: {
      view: "session",
      args: { sessionId: "payouts-upgrade", records: sessionRecords, lessons, runs },
      inputs: { sessionId: "payouts-upgrade", records: sessionRecords, lessons, runs },
    },
    "session-frozen": {
      view: "session",
      args: { sessionId: "fixture-c5-payouts", records: [frozenAfter], lessons: [], runs: frozenRuns },
      inputs: { sessionId: "fixture-c5-payouts", records: [frozenAfter], lessons: [], runs: frozenRuns },
    },
    "session-redaction": {
      view: "session",
      args: { sessionId: "redaction-fixture", records: redactionRecords, lessons: [], runs: redactionRuns },
      inputs: { sessionId: "redaction-fixture", records: redactionRecords, lessons: [], runs: redactionRuns },
    },
    run: {
      view: "run",
      args: { runId: "pilot-c3-payouts-r5", records: runRecords, runs },
      inputs: { runId: "pilot-c3-payouts-r5", records: runRecords, runs },
    },
    "run-frozen": {
      view: "run",
      args: { runId: frozenAfter.run_id, records: [frozenAfter], runs: frozenRuns },
      inputs: { runId: frozenAfter.run_id, records: [frozenAfter], runs: frozenRuns },
    },
    "run-illustrative": {
      view: "run",
      args: { runId: "payouts-attempt-1", records: illustrativeRunRecords, runs },
      inputs: { runId: "payouts-attempt-1", records: illustrativeRunRecords, runs },
    },
    "run-containment": {
      view: "run",
      args: { runId: containmentRunId, records: containmentRunRecords, runs },
      inputs: { runId: containmentRunId, records: containmentRunRecords, runs },
    },
    "run-containment-earlier": {
      view: "run",
      args: { runId: earlierRunId, records: earlierRunRecords, runs },
      inputs: { runId: earlierRunId, records: earlierRunRecords, runs },
    },
    "run-endpoint": {
      view: "run",
      args: { runId: endpointRecord.run_id, records: [endpointRecord], runs: endpointRuns },
      inputs: { runId: endpointRecord.run_id, records: [endpointRecord], runs: endpointRuns },
    },
    "run-redaction": {
      view: "run",
      args: { runId: redactionRun.run_id, records: redactionRunRecords, runs: redactionRuns },
      inputs: { runId: redactionRun.run_id, records: redactionRunRecords, runs: redactionRuns },
    },
  };

  const viewFor = { judges: judgesView, session: sessionView, run: runView };
  mkdirSync(OUT, { recursive: true });
  const pages = {};
  for (const [name, snapshot] of Object.entries(snapshots)) {
    pages[name] = viewFor[snapshot.view](snapshot.args);
  }
  const clean = (html) =>
    `${html
      .split("\n")
      .map((line) => line.replace(/[ \t]+$/u, ""))
      .join("\n")
      .replace(/\n{3,}/g, "\n\n")
      .trim()}\n`;
  for (const [name, html] of Object.entries(pages)) {
    writeFileSync(path.join(OUT, `${name}.html`), clean(html), "utf8");
  }

  const inputsFile = path.join(OUT, "inputs.json");
  const inputs = {
    schema: "kalari.web.inputs.v1",
    generator: "web/fixture/render.mjs",
    pages: Object.fromEntries(
      Object.entries(snapshots).map(([name, snapshot]) => [
        name,
        { view: snapshot.view, ...snapshot.inputs },
      ]),
    ),
  };
  writeFileSync(inputsFile, `${JSON.stringify(inputs, null, 2)}\n`, "utf8");

  const siteFiles = walk(SITE);
  const manifest = {
    schema: "kalari.web.rendered.v1",
    generator: "web/fixture/render.mjs",
    root: "web/site",
    pages: Object.fromEntries(
      Object.keys(pages).map((name) => {
        const file = path.join(OUT, `${name}.html`);
        return [name, { path: path.relative(REPO, file), sha256: sha256(file) }];
      }),
    ),
    sha256: Object.fromEntries(
      siteFiles.map((file) => [path.relative(SITE, file), sha256(file)]),
    ),
    inputs: {
      path: path.relative(REPO, inputsFile),
      sha256: sha256(inputsFile),
    },
    evidence: {
      path: path.relative(REPO, path.join(HERE, "evidence.jsonl")),
      sha256: sha256(path.join(HERE, "evidence.jsonl")),
    },
  };
  writeFileSync(path.join(OUT, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  console.log(`rendered ${Object.keys(pages).length} pages into web/fixture/rendered/`);
} finally {
  child.kill("SIGTERM");
}
