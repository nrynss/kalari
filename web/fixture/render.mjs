#!/usr/bin/env node
/* Regenerate the rendered fixture snapshots used by web/check.sh.

   This is a development tool, not part of the app and not part of the check.
   The app itself is plain ES modules and needs no Node. The check reads the
   committed snapshots and verifies their hashes against the view code and the
   fixture evidence, so a stale snapshot fails the check.

       node web/fixture/render.mjs
*/

import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, "../..");
const OUT = path.join(HERE, "rendered");
const { sessionView, runView, judgesView } = await import(
  path.join(REPO, "web/app/views.mjs")
);

function sha256(file) {
  return createHash("sha256").update(readFileSync(file)).digest("hex");
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

  mkdirSync(OUT, { recursive: true });
  const pages = {
    judges: judgesView({ benchmark, runs, sessions, lessons }),
    "judges-empty": judgesView({ benchmark: [], runs, sessions, lessons }),
    "judges-no-store": judgesView({ benchmark: [], runs: [], sessions: [], lessons: [] }),
    session: sessionView({ sessionId: "payouts-upgrade", records: sessionRecords, lessons, runs }),
    run: runView({ runId: "pilot-c3-payouts-r5", records: runRecords, runs }),
    "run-illustrative": runView({ runId: "payouts-attempt-1", records: illustrativeRunRecords, runs }),
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

  const sources = {
    views: path.join(REPO, "web/app/views.mjs"),
    format: path.join(REPO, "web/app/format.mjs"),
    labels: path.join(REPO, "web/app/labels.mjs"),
    evidence: path.join(HERE, "evidence.jsonl"),
  };
  const manifest = {
    schema: "kalari.web.rendered.v1",
    generator: "web/fixture/render.mjs",
    pages: Object.fromEntries(
      Object.keys(pages).map((name) => [name, `web/fixture/rendered/${name}.html`]),
    ),
    sha256: Object.fromEntries(
      Object.entries(sources).map(([key, file]) => [
        key,
        { path: path.relative(REPO, file), sha256: sha256(file) },
      ]),
    ),
  };
  writeFileSync(path.join(OUT, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  console.log(`rendered ${Object.keys(pages).length} pages into web/fixture/rendered/`);
} finally {
  child.kill("SIGTERM");
}
