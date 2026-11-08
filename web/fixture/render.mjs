#!/usr/bin/env node
/* Regenerate the fixture snapshots used by web/check.sh.

   This is a development tool, not part of the app and not part of the check.
   The app itself is plain ES modules and needs no Node. The check reads the
   committed snapshots. It verifies a sha256 for every rendered page and for
   every file under web/site/, so a stale snapshot fails the check.

   The script also writes `inputs.json`: for each page, the exact records the
   view was called with. The check derives its expectations from those
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
const { sessionView, runView } = await import(path.join(SITE, "app/views.mjs"));
const { judges023View: judgesView } = await import(path.join(SITE, "app/judges023.mjs"));

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

/* One repeat session stands in for every run and session page. It is in the
   store, so the snapshot inputs match the API. */
const SPOT_RUN = "kalari-payouts-918666ca";

const { child, base } = await startServer();
try {
  const [benchmark, runs, sessions, lessons] = await Promise.all([
    getJson(base, "api/benchmark"),
    getJson(base, "api/runs"),
    getJson(base, "api/sessions"),
    getJson(base, "api/lessons"),
  ]);
  if (!runs.includes(SPOT_RUN)) {
    throw new Error(`the fixture has no ${SPOT_RUN} run`);
  }
  const containment = await getJson(base, "api/sessions/containment-023");
  const runRecords = await getJson(base, `api/runs/${SPOT_RUN}`);
  const sessionRecords = await getJson(base, `api/sessions/${SPOT_RUN}`);
  const containmentRunId = containment.find((record) => record.kind === "containment")?.run_id;
  if (!containmentRunId) throw new Error("the fixture has no containment run");
  const containmentRunRecords = await getJson(base, `api/runs/${containmentRunId}`);

  const live = { benchmark, runs, sessions, lessons, containment, warnings: [] };
  const snapshots = {
    judges: {
      view: "judges",
      args: live,
      inputs: { benchmark, runs, sessions, lessons, containment },
    },
    "judges-empty": {
      view: "judges",
      args: { benchmark: [], runs, sessions, lessons, containment, warnings: [] },
      inputs: { benchmark: [], runs, sessions, lessons, containment },
    },
    "judges-no-store": {
      view: "judges",
      args: { benchmark: [], runs: [], sessions: [], lessons: [], containment: [], warnings: [] },
      inputs: { benchmark: [], runs: [], sessions: [], lessons: [], containment: [] },
    },
    run: {
      view: "run",
      args: { runId: SPOT_RUN, records: runRecords, runs },
      inputs: { runId: SPOT_RUN, records: runRecords, runs },
    },
    session: {
      view: "session",
      args: { sessionId: SPOT_RUN, records: sessionRecords, lessons, runs },
      inputs: { sessionId: SPOT_RUN, records: sessionRecords, lessons, runs },
    },
    "run-containment": {
      view: "run",
      args: { runId: containmentRunId, records: containmentRunRecords, runs },
      inputs: { runId: containmentRunId, records: containmentRunRecords, runs },
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
  const inputs = {
    schema: "kalari.web.inputs.v1",
    pages: Object.fromEntries(Object.entries(snapshots).map(([name, snapshot]) => [name, snapshot.inputs])),
  };
  writeFileSync(path.join(OUT, "inputs.json"), `${JSON.stringify(inputs, null, 2)}\n`, "utf8");
  const manifest = {
    schema: "kalari.web.rendered.v1",
    generator: "web/fixture/render.mjs",
    root: "web/site",
    pages: Object.fromEntries(
      Object.keys(pages).map((name) => [
        name,
        { path: `web/fixture/rendered/${name}.html`, sha256: sha256(path.join(OUT, `${name}.html`)) },
      ]),
    ),
    sha256: Object.fromEntries(
      walk(SITE)
        .filter((file) => !file.endsWith(".DS_Store"))
        .map((file) => [path.relative(SITE, file).replace(/\\/g, "/"), sha256(file)]),
    ),
    inputs: { path: "web/fixture/rendered/inputs.json", sha256: sha256(path.join(OUT, "inputs.json")) },
    evidence: { path: "web/fixture/evidence.jsonl", sha256: sha256(path.join(HERE, "evidence.jsonl")) },
  };
  writeFileSync(path.join(OUT, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  console.log(`rendered ${Object.keys(pages).length} snapshots`);
} finally {
  child.kill("SIGTERM");
}
