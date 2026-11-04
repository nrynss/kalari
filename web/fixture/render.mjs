#!/usr/bin/env node
/* Regenerate the rendered fixture snapshots used by web/check.sh.

   This is a development tool, not part of the app and not part of the check.
   The app itself is plain ES modules and needs no Node. The check reads the
   committed snapshots. It verifies a sha256 for every rendered page and for
   every file under web/site/, so a stale snapshot fails the check.

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

/* Synthetic records for the view tests. They carry no measure, so every value
   on the page reads as unknown. They exist to prove the frozen labels and the
   split-pair status, which the committed pilot store cannot exercise. */
function syntheticBenchmark({ runId, sessionId, condition, upgrade }) {
  return {
    kind: "benchmark",
    session_id: sessionId,
    run_id: runId,
    change_kinds: ["pagination_changed"],
    payload: {
      schema: "kalari.benchmark.v1",
      provenance: "frozen",
      status: "valid",
      arm: condition === 5 ? "kalari" : "reference",
      condition,
      upgrade,
      repeat: 1,
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
      source: "web/fixture/render.mjs",
      notes: "Synthetic fixture for the frozen label test. Not a measurement.",
    },
  };
}

const frozenAfter = syntheticBenchmark({
  runId: "fixture-c5-payouts-r1",
  sessionId: "fixture-c5-payouts",
  condition: 5,
  upgrade: "payouts",
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
});
const frozenRuns = [frozenAfter.run_id, frozenBeforeOther.run_id, frozenBeforeSame.run_id];

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
  const sessionRecords = await getJson(base, "api/sessions/payouts-upgrade");
  const runRecords = await getJson(base, "api/runs/pilot-c3-payouts-r5");
  const illustrativeRunRecords = await getJson(base, "api/runs/payouts-attempt-1");
  const runDetails = await runDetailsFor(base, runs, benchmark);

  mkdirSync(OUT, { recursive: true });
  const pages = {
    judges: judgesView({ benchmark, runs, sessions, lessons, runDetails }),
    "judges-empty": judgesView({ benchmark: [], runs, sessions, lessons }),
    "judges-no-store": judgesView({ benchmark: [], runs: [], sessions: [], lessons: [] }),
    "judges-frozen-pair": judgesView({
      benchmark: [frozenAfter, frozenBeforeSame],
      runs: frozenRuns,
      sessions: [],
      lessons: [],
    }),
    "judges-frozen-split": judgesView({
      benchmark: [frozenAfter, frozenBeforeOther],
      runs: frozenRuns,
      sessions: [],
      lessons: [],
    }),
    session: sessionView({ sessionId: "payouts-upgrade", records: sessionRecords, lessons, runs }),
    "session-frozen": sessionView({
      sessionId: "fixture-c5-payouts",
      records: [frozenAfter],
      lessons: [],
      runs: frozenRuns,
    }),
    run: runView({ runId: "pilot-c3-payouts-r5", records: runRecords, runs }),
    "run-frozen": runView({ runId: frozenAfter.run_id, records: [frozenAfter], runs: frozenRuns }),
    "run-illustrative": runView({ runId: "payouts-attempt-1", records: illustrativeRunRecords, runs }),
    "run-endpoint": runView({ runId: endpointRecord.run_id, records: [endpointRecord], runs: endpointRuns }),
  };
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
