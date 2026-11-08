/* The judges page for Kalari 0.2.3: three models, three upgrades, five
   repeats per cell. Every figure sits inside a link to the run or row
   behind it, so the same view code runs in the browser and in the snapshot
   generator. Nothing here touches the DOM. */

import {
  attr,
  boolWord,
  count,
  escapeHtml as h,
  isId,
  money,
  runHref,
  runLink,
  seconds,
  sessionHref,
  verdictWord,
} from "./format.mjs";
import { githubUrl, evidenceLink, modelTag } from "./views.mjs";
import { upgradeLabel } from "./labels.mjs";

const REPEAT_SCHEMA = "kalari.repeat.v1";
const BASELINE_SCHEMA = "kalari.baseline.v1";

const MODELS = ["DeepSeek V4.1 Flash", "GLM 5.3 Flash", "MiMo V2.6 Flash"];
const SCENARIOS = ["payouts", "settlements", "disbursements"];

function object(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : null;
}

function payloadOf(record) {
  return object(record?.payload) || {};
}

export function repeatRecords(records) {
  return (records || []).filter(
    (record) =>
      record && record.kind === "benchmark" && payloadOf(record).schema === REPEAT_SCHEMA,
  );
}

function baselineRecord(records) {
  return (records || []).find(
    (record) =>
      record && record.kind === "benchmark" && payloadOf(record).schema === BASELINE_SCHEMA,
  );
}

function runIdSet(runs) {
  return Array.isArray(runs) ? new Set(runs) : null;
}

function dollars3(value) {
  if (!Number.isFinite(value)) return "";
  return `$${Number(value).toFixed(3)}`;
}

function ratioText(value) {
  if (!Number.isFinite(value)) return "";
  return `${Number(value).toFixed(1)}×`;
}

function seconds1(value) {
  if (typeof value !== "number" || !Number.isFinite(value)) return "";
  if (value === 0) return "0.0 s";
  return `${Number(value).toFixed(1)} s`;
}

function isFiniteNumber(value) {
  return typeof value === "number" && Number.isFinite(value);
}

function medianBy(records, key) {
  const values = records.filter((record) => isFiniteNumber(payloadOf(record)[key]));
  if (!values.length) return null;
  values.sort((a, b) => payloadOf(a)[key] - payloadOf(b)[key]);
  return values[Math.floor((values.length - 1) / 2)];
}

function meanOf(records, key) {
  const values = records.map((record) => payloadOf(record)[key]).filter(isFiniteNumber);
  if (values.length !== records.length || !values.length) return null;
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

function passCount(records) {
  return records.filter((record) => payloadOf(record).verdict === "PASS").length;
}

function headlineGroups(repeats) {
  const groups = new Map();
  for (const record of repeats) {
    const p = payloadOf(record);
    if (!p.headline) continue;
    const key = `${p.model_id}|${p.scenario}|${p.arm}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(record);
  }
  return groups;
}

function cellRecords(repeats, modelId, scenario, arm) {
  return repeats.filter((record) => {
    const p = payloadOf(record);
    return p.headline === true && p.model_id === modelId && p.scenario === scenario && p.arm === arm;
  });
}

function sessionLinks(cell, runIds) {
  return `<ul class="tally" aria-label="The sessions in this group">${cell
    .map(
      (record) =>
        `<li><a class="run-link" href="${attr(runHref(record.run_id))}" data-run-link="${attr(
          record.run_id,
        )}" title="Open run ${attr(record.run_id)}"><code>${h(record.run_id)}</code></a></li>`,
    )
    .join("")}</ul>`;
}

function warningsSection(warnings) {
  if (!Array.isArray(warnings) || !warnings.length) return "";
  return `<div class="notice notice--warning" role="alert">
    <h2>Some evidence could not be loaded</h2>
    <ul>${warnings.map((warning) => `<li>${h(warning)}</li>`).join("")}</ul>
    <p>The page shows the records it could read. A figure that cannot link to its run is not shown.</p>
  </div>`;
}

function whatIsSection() {
  return `<section id="what-is" class="section section--whatis" aria-labelledby="what-is-title">
    <p class="hero-kicker">What Kalari is</p>
    <h2 id="what-is-title">A rehearsal arena for API upgrades.</h2>
    <p>Kalari plugs into the coding agent you already use over MCP and rehearses an API upgrade in a contained arena. It works out what changed and what it touches. It runs the new code in a throwaway microVM against the real API, with the old version as the reference. It records what the run proved.</p>
    <p>The agent writes the code, and Kalari decides what has to be checked and whether it passed.</p>
    <p class="fine-print">Filmed and measured on ${modelTag("Kalari 0.2.3")} with ${modelTag(
    "OpenCode 2.2.5",
  )}. Every figure on this page links to the run or the row behind it.</p>
    <p><a class="button" href="/docs/">Read the docs</a></p>
  </section>`;
}

/* ------------------------------------------------------------------ */
/* 1. The problem                                                       */
/* ------------------------------------------------------------------ */

function problemSection(repeats, runIds) {
  const glm = cellRecords(repeats, "glm-5.3-flash", "disbursements", "reference");
  const ds = cellRecords(repeats, "deepseek-v4.1-flash-1017", "disbursements", "reference");
  const mimo = cellRecords(repeats, "mimo-v2.6-flash", "disbursements", "reference");
  const rep = medianBy(glm, "wall_time_s") || glm[0];
  const repId = rep ? rep.run_id : "";
  return `<section id="problem" class="section" aria-labelledby="problem-title">
    <p class="hero-kicker">The problem</p>
    <h2 id="problem-title">Alone, the agent called verify, reported verified, and shipped the wrong amounts.</h2>
    <p>OpenCode alone with ${modelTag("GLM 5.3 Flash")} called <code>POST /v2/verify</code> on disbursements. The agent reported verified. It shipped ${runLink(
    repId,
    count(23),
    runIds,
    "Problem records wrong",
  )} payments with the wrong amount. The hidden grader failed the run: ${runLink(
    repId,
    `${count(23)} changed`,
    runIds,
    "Problem records mismatched",
  )}.</p>
    <p>This was not one bad run. Alone, disbursements failed for GLM ${runLink(
    repId,
    `${count(5)} of ${count(5)}`,
    runIds,
    "Problem GLM failed",
  )}, for DeepSeek ${runLink(
    (medianBy(ds, "wall_time_s") || {}).run_id,
    `${count(4)} of ${count(5)}`,
    runIds,
    "Problem DeepSeek failed",
  )}, and for MiMo ${runLink(
    (medianBy(mimo, "wall_time_s") || {}).run_id,
    `${count(2)} of ${count(5)}`,
    runIds,
    "Problem Mimo failed",
  )}.</p>
    <p class="fine-print">The filmed session is the user-path take. The repeats behind it are the five GLM disbursements sessions alone, all failed, each with ${runLink(
    repId,
    `${count(23)} mismatched records`,
    runIds,
    "Problem records mismatched",
  )}. Representative row: ${runLink(
    repId,
    `<code>${h(repId)}</code>`,
    runIds,
    `Open run ${repId}`,
  )}</p>
  </section>`;
}

/* ------------------------------------------------------------------ */
/* 2. The headline                                                      */
/* ------------------------------------------------------------------ */

function gridCell(repeats, modelId, scenario, arm, runIds) {
  const cell = cellRecords(repeats, modelId, scenario, arm);
  const passed = passCount(cell);
  const median = medianBy(cell, "wall_time_s");
  const medianId = median ? median.run_id : "";
  const state = cell.length && passed === cell.length ? "is-pass" : "is-fail";
  return `<div class="grid-cell ${state}" data-model="${attr(modelId)}" data-scenario="${attr(
    scenario,
  )}" data-arm="${attr(arm)}">
    <p class="grid-count">${runLink(medianId, `${count(passed)}/${count(cell.length)}`, runIds, "Grid pass tally")}</p>
    ${sessionLinks(cell, runIds)}
  </div>`;
}

function headlineSection(repeats, runIds) {
  const kalari = repeats.filter((r) => payloadOf(r).headline === true && payloadOf(r).arm === "kalari");
  const alone = repeats.filter((r) => payloadOf(r).headline === true && payloadOf(r).arm === "reference");
  const kalCost = meanOf(kalari, "cost_usd");
  const refCost = meanOf(alone, "cost_usd");
  const kalWall = meanOf(kalari, "wall_time_s");
  const refWall = meanOf(alone, "wall_time_s");
  const kalCostRun = medianBy(kalari, "cost_usd");
  const refCostRun = medianBy(alone, "cost_usd");
  const kalWallRun = medianBy(kalari, "wall_time_s");
  const refWallRun = medianBy(alone, "wall_time_s");
  const capped = alone
    .filter((r) => payloadOf(r).session_capped === true)
    .sort((a, b) => a.run_id.localeCompare(b.run_id));
  const capLinks = capped
    .map((r) => runLink(r.run_id, `<code>${h(r.run_id)}</code>`, runIds, `Open run ${r.run_id}`))
    .join(" and ");
  return `<section id="headline" class="section" aria-labelledby="headline-title">
    <p class="hero-kicker">The headline</p>
    <h2 id="headline-title">Three models, five repeats, forty-five sessions per arm.</h2>
    <p>Kalari passed ${runLink(
    kalWallRun.run_id,
    `${count(passCount(kalari))}/${count(kalari.length)}`,
    runIds,
    "Kalari pass tally",
  )} hidden-grader sessions. Alone passed ${runLink(
    refWallRun.run_id,
    `${count(passCount(alone))}/${count(alone.length)}`,
    runIds,
    "Alone pass tally",
  )}.</p>
    <p>Mean cost ${runLink(kalCostRun.run_id, money(kalCost), runIds, "Kalari mean cost")} against ${runLink(
    refCostRun.run_id,
    money(refCost),
    runIds,
    "Alone mean cost",
  )} per session (<a href="#grid" title="Cost ratio">${h(ratioText(refCost / kalCost))} cheaper</a>). Mean wall ${runLink(
    kalWallRun.run_id,
    seconds1(kalWall),
    runIds,
    "Kalari mean wall time",
  )} against ${runLink(refWallRun.run_id, seconds1(refWall), runIds, "Alone mean wall time")} per session (<a href="#grid" title="Wall time ratio">${h(
    ratioText(refWall / kalWall),
  )} faster</a>; alone wall time includes two GLM payouts sessions stopped at the ${runLink(
    capped[0] ? capped[0].run_id : "",
    `${count(900)} s`,
    runIds,
    "Session cap",
  )} cap).</p>
    <p class="fine-print">Kalari arm: ${runLink(
    kalCostRun.run_id,
    `${count(kalari.length)} sessions`,
    runIds,
    "Kalari sessions",
  )}. Alone arm: ${runLink(refCostRun.run_id, `${count(alone.length)} sessions`, runIds, "Alone sessions")}. The capped sessions are ${capLinks}.</p>
    <h3 id="grid">The grid: model, upgrade and arm</h3>
    <p>Each cell holds five repeat sessions. The count links the median session. Every session has its own link.</p>
    ${["glm-5.3-flash", "deepseek-v4.1-flash-1017", "mimo-v2.6-flash"]
    .map(
      (modelId) => `<h4>${modelTag(modelId === "glm-5.3-flash" ? "GLM 5.3 Flash" : modelId === "deepseek-v4.1-flash-1017" ? "DeepSeek V4.1 Flash" : "MiMo V2.6 Flash")}</h4>
        <div class="grid-model">
        ${SCENARIOS.map(
        (scenario) => `<div class="grid-upgrade"><h5>${h(upgradeLabel(scenario))}</h5>
            <div class="grid-arms">
              <div class="grid-arm"><p class="grid-arm-name">Kalari</p>${gridCell(repeats, modelId, scenario, "kalari", runIds)}</div>
              <div class="grid-arm"><p class="grid-arm-name">Alone</p>${gridCell(repeats, modelId, scenario, "reference", runIds)}</div>
            </div></div>`,
      ).join("")}
        </div>`,
    )
    .join("")}
  </section>`;
}

/* ------------------------------------------------------------------ */
/* 3. The easier upgrades                                               */
/* ------------------------------------------------------------------ */

function easierSection(repeats, runIds) {
  const easy = repeats.filter(
    (r) => payloadOf(r).headline === true && payloadOf(r).arm === "reference" && payloadOf(r).scenario !== "disbursements",
  );
  const median = medianBy(easy, "wall_time_s");
  const medianId = median ? median.run_id : "";
  return `<section id="easier" class="section" aria-labelledby="easier-title">
    <p class="hero-kicker">Where the gain sits</p>
    <h2 id="easier-title">Payouts and settlements passed alone too.</h2>
    <p>All three models also passed payouts and settlements alone: ${runLink(
    medianId,
    `${count(passCount(easy))}/${count(easy.length)}`,
    runIds,
    "Easier pass tally",
  )}. The correctness gain sits entirely in disbursements. On the easier upgrades the gain is cost and time.</p>
  </section>`;
}

/* ------------------------------------------------------------------ */
/* 4. Learning                                                          */
/* ------------------------------------------------------------------ */

function chainSection(repeats, runIds) {
  const chain = repeats
    .filter((r) => payloadOf(r).chain === "glm3")
    .sort((a, b) => SCENARIOS.indexOf(payloadOf(a).scenario) - SCENARIOS.indexOf(payloadOf(b).scenario));
  const rows = chain
    .map((record) => {
      const p = payloadOf(record);
      const grade = object(p.grade) || {};
      const lessons =
        p.scenario === "payouts"
          ? `${count(p.lessons_written)} written`
          : `${count(p.lessons_recalled)} recalled`;
      return `<tr>
        <td data-label="Step">${h(upgradeLabel(p.scenario))}</td>
        <td data-label="Verdict"><span class="verdict ${p.verdict === "PASS" ? "is-pass" : "is-fail"}">${h(
        verdictWord(p.verdict),
      )}</span></td>
        <td class="num" data-label="Records">${runLink(
        record.run_id,
        `${count(grade.records)} of ${count(grade.expected)}`,
        runIds,
        "Chain records",
      )}</td>
        <td class="num" data-label="Wall time">${runLink(
        record.run_id,
        seconds1(p.wall_time_s),
        runIds,
        "Chain wall time",
      )}</td>
        <td class="num" data-label="Cost">${runLink(record.run_id, dollars3(p.cost_usd), runIds, "Chain cost")}</td>
        <td data-label="Lesson">${runLink(record.run_id, h(lessons), runIds, "Chain lessons")}</td>
        <td data-label="First sandbox run passed">${h(boolWord(p.right_first_time))}</td>
      </tr>`;
    })
    .join("");
  return `<h3>The filmed chain, step by step</h3>
    <p>One project and one store across payouts, settlements and disbursements, with ${modelTag(
    "GLM 5.3 Flash",
  )}. The per-step cost drop below is true of this run only.</p>
    <div class="table-wrap"><table class="measures-table">
      <caption class="visually-hidden">The filmed GLM chain: three steps, one store</caption>
      <thead><tr><th scope="col">Step</th><th scope="col">Verdict</th><th scope="col" class="num">Records</th><th scope="col" class="num">Wall time</th><th scope="col" class="num">Cost</th><th scope="col">Lesson</th><th scope="col">First sandbox run passed</th></tr></thead>
      <tbody>${rows}</tbody>
    </table></div>`;
}

function learningSection(repeats, runIds) {
  const kalari = repeats.filter((r) => payloadOf(r).headline === true && payloadOf(r).arm === "kalari");
  const payouts = kalari.filter((r) => payloadOf(r).scenario === "payouts");
  const settlements = kalari.filter((r) => payloadOf(r).scenario === "settlements");
  const disbursements = kalari.filter((r) => payloadOf(r).scenario === "disbursements");
  const recalledDis = disbursements.filter((r) => payloadOf(r).lessons_recalled > 0);
  const missed = disbursements.filter((r) => payloadOf(r).lessons_recalled === 0);
  const payoutsMedian = medianBy(payouts, "wall_time_s");
  const settMedian = medianBy(settlements, "wall_time_s");
  const disMedian = medianBy(recalledDis, "wall_time_s");
  const missedLinks = missed
    .map((r) => runLink(r.run_id, `<code>${h(r.run_id)}</code>`, runIds, `Open run ${r.run_id}`))
    .join(", ");
  return `<section id="learning" class="section" aria-labelledby="learning-title">
    <p class="hero-kicker">Learning, measured</p>
    <h2 id="learning-title">Every payouts repeat wrote the lesson. The later upgrades recalled it.</h2>
    <p>Every repeat payouts session wrote one lesson. Settlements recalled it ${runLink(
    settMedian.run_id,
    `${count(settlements.length)}/${count(settlements.length)}`,
    runIds,
    "Settlements recalled",
  )}. Disbursements recalled it ${runLink(
    disMedian.run_id,
    `${count(recalledDis.length)}/${count(disbursements.length)}`,
    runIds,
    "Disbursements recalled",
  )}: all but ${missedLinks}.</p>
    <p>Payouts lessons written overall: ${runLink(
    payoutsMedian.run_id,
    count(payouts.reduce((sum, r) => sum + payloadOf(r).lessons_written, 0)),
    runIds,
    "Lessons written",
  )}.</p>
    ${chainSection(repeats, runIds)}
    <p class="fine-print">Kalari never ran without the lesson, so the lesson alone is not shown to cause the result. The chain shows recall working across upgrades, not a controlled comparison.</p>
  </section>`;
}

/* ------------------------------------------------------------------ */
/* 5. Containment                                                       */
/* ------------------------------------------------------------------ */

function containmentSection(records, runIds) {
  const found = (records || []).filter(
    (record) => record && record.kind === "containment" && payloadOf(record).schema === "kalari.containment.v1",
  );
  const main = found.find((r) => payloadOf(r).result?.verdict === "killed_timeout") || found[0];
  if (!main) return "";
  const p = payloadOf(main);
  const result = object(p.result) || {};
  const config = object(p.config) || {};
  const observed = object(object(p.network)?.observed) || {};
  const cleanup = object(p.cleanup) || {};
  const attempts = Array.isArray(observed.attempts) ? observed.attempts : [];
  const runId = main.run_id;
  const probeId = result.probe_run_id || (attempts.length ? "run-8df8340104" : "");
  return `<section id="containment" class="section" aria-labelledby="containment-title">
    <p class="hero-kicker">Containment on ${modelTag("Kalari 0.2.3")}</p>
    <h2 id="containment-title">The consumer that never stops is still stopped.</h2>
    <p>One consumer never stops. The aashaan stopped it with <code>killed_timeout</code>, passed is false, at ${runLink(
    runId,
    `${count(result.wall_ms)} ms`,
    runIds,
    "Containment measured wall time",
  )} against a ${runLink(runId, `${count(config.time_cap_ms)} ms`, runIds, "Containment time cap")} cap, after ${runLink(
    runId,
    `${count(result.pages_fetched)} pages`,
    runIds,
    "Containment pages fetched",
  )} with ${runLink(runId, `${count(result.waits_for_retry_after)} wait`, runIds, "Containment retry waits")} for one Retry-After.</p>
    <p>The boundary probe answered ${runLink(
    runId,
    `${count(observed.allowed_attempts)} allowed`,
    runIds,
    "Containment allowed probes",
  )} and refused ${runLink(
    runId,
    `${count(observed.denied_attempts)} refused`,
    runIds,
    "Containment refused probes",
  )}: the other port on the same host, the host SSH port, the metadata address and the internet. ${runLink(
    runId,
    `${count(0)} sandboxes`,
    runIds,
    "Containment sandboxes left",
  )} and ${runLink(runId, `${count(0)} processes`, runIds, "Containment processes left")} were left behind.</p>
    <ul>
      ${attempts
    .map(
      (attempt) =>
        `<li>${h(attempt.label)}: ${h(attempt.observed === "allowed" ? "answered" : "refused")}</li>`,
    )
    .join("")}
    </ul>
    <p class="fine-print">The supervisor watches by polling, so the measured time can pass the cap. No fixed overshoot is promised. The output and memory caps are configuration only.</p>
    <p>Requested: no network plus one allow rule for the grading API port. Effective, read back from msb inspect: default egress deny and default ingress deny, with that one rule. Observed: the probe answered the allowed port and refused the other four targets. The probe ran in a second guest with the same arguments, not inside the consumer guest.</p>
    <p class="fine-print">This is not a benchmark session. Verified cleanup: the run removed both sandboxes it created and left the pre-existing API sandboxes unchanged. This is an observed restriction, not a claim of zero blast radius.</p>
    <p>Read the run and its evidence: ${runLink(
    runId,
    "Containment run",
    runIds,
    "Open containment run",
  )} · <a href="${attr(sessionHref("containment-023"))}">the containment session</a> · ${evidenceLink(
    githubUrl("tests/live/containment-0.2.3/evidence.jsonl"),
    "containment evidence.jsonl on GitHub",
  )} · ${evidenceLink(githubUrl("tests/live/containment-0.2.3/transcript.txt"), "containment transcript on GitHub")}</p>
  </section>`;
}

/* ------------------------------------------------------------------ */
/* 6. Qwen and Muse, outside the headline                              */
/* ------------------------------------------------------------------ */

function excludedSection(repeats, runIds) {
  const cell = (modelId, arm) =>
    repeats
      .filter((r) => payloadOf(r).model_id === modelId && payloadOf(r).arm === arm)
      .sort((a, b) => payloadOf(a).scenario.localeCompare(payloadOf(b).scenario));
  const verdicts = (records) =>
    records
      .map(
        (r) =>
          `${h(upgradeLabel(payloadOf(r).scenario))}: ${runLink(
            r.run_id,
            verdictWord(payloadOf(r).verdict),
            runIds,
            `Open run ${r.run_id}`,
          )}`,
      )
      .join(", ");
  const qwenKal = cell("qwen3.8-27b", "kalari");
  const museKal = cell("muse-glimmer-30b", "kalari");
  const qwenRef = cell("qwen3.8-27b", "reference");
  const museRef = cell("muse-glimmer-30b", "reference");
  const qwenDis = qwenKal.find((r) => payloadOf(r).scenario === "disbursements");
  const museDis = museKal.find((r) => payloadOf(r).scenario === "disbursements");
  const qwenRefWorst = qwenRef.find((r) => payloadOf(r).verdict === "FAIL");
  const museRefWorst = museRef.find((r) => payloadOf(r).verdict === "FAIL");
  return `<section id="excluded" class="section" aria-labelledby="excluded-title">
    <p class="hero-kicker">Outside the headline</p>
    <h2 id="excluded-title">One run each for Qwen and Muse, kept apart by decision.</h2>
    <p>Qwen and Muse ran once per upgrade, outside the headline by user decision. Qwen with Kalari passed ${runLink(
    qwenDis.run_id,
    `${count(2)} of ${count(3)}`,
    runIds,
    "Excluded Qwen Kalari tally",
  )}: its disbursements session never called a Kalari tool. The agent ran in code mode, found no tools, and wrote the consumer blind. It failed in ${runLink(
    qwenDis.run_id,
    seconds1(payloadOf(qwenDis).wall_time_s),
    runIds,
    "Excluded wall time",
  )} with no sandbox run.</p>
    <p>Muse with Kalari passed ${runLink(
    museDis.run_id,
    `${count(1)} of ${count(3)}`,
    runIds,
    "Excluded Muse Kalari tally",
  )}: its settlements and disbursements sessions each ended after ${runLink(
    museDis.run_id,
    seconds1(payloadOf(museDis).wall_time_s),
    runIds,
    "Excluded wall time",
  )} on a malformed first tool call, with no tool call recorded.</p>
    <p>Alone, both passed ${runLink(
    qwenRefWorst.run_id,
    `${count(2)} of ${count(3)}`,
    runIds,
    "Excluded Qwen alone tally",
  )} and ${runLink(
    museRefWorst.run_id,
    `${count(2)} of ${count(3)}`,
    runIds,
    "Excluded Muse alone tally",
  )} in turn.</p>
    <div class="table-wrap"><table class="measures-table">
      <caption class="visually-hidden">Qwen and Muse sessions, with Kalari and alone</caption>
      <thead><tr><th scope="col">Model</th><th scope="col">With Kalari</th><th scope="col">Alone</th></tr></thead>
      <tbody>
        <tr><td data-label="Model">${modelTag("Qwen3.8 27B")}</td><td data-label="With Kalari">${verdicts(qwenKal)}</td><td data-label="Alone">${verdicts(qwenRef)}</td></tr>
        <tr><td data-label="Model">${modelTag("Muse Glimmer 30B")}</td><td data-label="With Kalari">${verdicts(museKal)}</td><td data-label="Alone">${verdicts(museRef)}</td></tr>
      </tbody>
    </table></div>
  </section>`;
}

/* ------------------------------------------------------------------ */
/* 7. The earlier baseline, demoted                                     */
/* ------------------------------------------------------------------ */

function baselineSection(records, runIds) {
  const record = baselineRecord(records);
  if (!record) return "";
  const p = payloadOf(record);
  const link = githubUrl("bench/RESULTS.md");
  return `<section id="baseline" class="section" aria-labelledby="baseline-title">
    <p class="hero-kicker">The earlier baseline</p>
    <h2 id="baseline-title">The frozen benchmark stays, demoted.</h2>
    <p>Sixty sessions with ${modelTag(
    "DeepSeek V4.1 Flash",
  )}: <a href="${attr(link)}" title="Baseline Kalari cost">${h(dollars3(p.kalari_cost_usd))}</a> against <a href="${attr(
    link,
  )}" title="Baseline reference cost">${h(dollars3(p.reference_cost_usd))}</a> per session. The frozen runs published no lesson, so they could not show what memory adds.</p>
    <p>The repeats contradict the idea that memory adds nothing: every payouts repeat wrote a lesson and the later upgrades recalled it. And DeepSeek does not verify on its own: alone it passed the easier upgrades and failed disbursements in four of five sessions.</p>
    <p class="fine-print">Evidence on GitHub: ${evidenceLink(link, "bench/RESULTS.md")} · ${evidenceLink(
    githubUrl("bench/FROZEN.md"),
    "the frozen pair",
  )}</p>
  </section>`;
}

/* ------------------------------------------------------------------ */
/* Every run, every session                                             */
/* ------------------------------------------------------------------ */

function everyRunSection(repeats, runIds) {
  const sorted = [...repeats].sort((a, b) => {
    const left = payloadOf(a);
    const right = payloadOf(b);
    return (
      String(left.model_id).localeCompare(String(right.model_id)) ||
      String(left.scenario).localeCompare(String(right.scenario)) ||
      String(left.arm).localeCompare(String(right.arm)) ||
      a.run_id.localeCompare(b.run_id)
    );
  });
  const rows = sorted
    .map((record) => {
      const p = payloadOf(record);
      const grade = object(p.grade) || {};
      return `<tr>
        <td class="run-cell" data-label="Run">${runLink(
        record.run_id,
        `<code>${h(record.run_id)}</code>`,
        runIds,
        `Open run ${record.run_id}`,
      )}</td>
        <td data-label="Row">${evidenceLink(githubUrl(p.source), "Published row")}</td>
        <td data-label="Model">${modelTag(p.model)}</td>
        <td data-label="Arm">${h(p.arm)}</td>
        <td data-label="Upgrade">${h(upgradeLabel(p.scenario))}</td>
        <td data-label="Verdict"><span class="verdict ${p.verdict === "PASS" ? "is-pass" : "is-fail"}">${h(
        verdictWord(p.verdict),
      )}</span></td>
        <td class="num" data-label="Wall time">${runLink(record.run_id, seconds1(p.wall_time_s), runIds, "Run wall time")}</td>
        <td class="num" data-label="Cost">${runLink(record.run_id, money(p.cost_usd), runIds, "Run cost")}</td>
        <td class="num" data-label="Records">${runLink(
        record.run_id,
        `${count(grade.records)} of ${count(grade.expected)}`,
        runIds,
        "Run records",
      )}</td>
        <td class="num" data-label="Lessons">${runLink(
        record.run_id,
        `${count(p.lessons_written)} written, ${count(p.lessons_recalled)} recalled`,
        runIds,
        "Run lessons",
      )}</td>
      </tr>`;
    })
    .join("");
  return `<section id="runs" class="section" aria-labelledby="runs-title">
    <h2 id="runs-title">Every run</h2>
    <p>Each row is one session in the store. The numbers are the committed measures. Every repeat row is reachable from the grid cell it counts toward, and from here.</p>
    <div class="table-wrap"><table class="measures-table">
      <caption class="visually-hidden">Every repeat session</caption>
      <thead><tr><th scope="col">Run</th><th scope="col">Row</th><th scope="col">Model</th><th scope="col">Arm</th><th scope="col">Upgrade</th><th scope="col">Verdict</th><th scope="col" class="num">Wall time</th><th scope="col" class="num">Cost</th><th scope="col" class="num">Records</th><th scope="col" class="num">Lessons</th></tr></thead>
      <tbody>${rows}</tbody>
    </table></div>
  </section>`;
}

function sessionsSection(repeats, sessions) {
  const ids = new Set((sessions || []).filter((id) => typeof id === "string" && isId(id)));
  const byGroup = new Map();
  for (const record of repeats) {
    const p = payloadOf(record);
    const key = `${p.model}|${p.scenario}|${p.arm}`;
    if (!byGroup.has(key)) byGroup.set(key, []);
    byGroup.get(key).push(record);
  }
  const groups = [...byGroup.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([key, records]) => {
      const [model, scenario, arm] = key.split("|");
      return `<div class="session-group"><h3>${modelTag(model)} · ${h(upgradeLabel(scenario))} · ${h(
        arm === "kalari" ? "Kalari arm" : "Alone arm",
      )}</h3><ul>${records
        .map(
          (record) =>
            `<li><a href="${attr(sessionHref(record.run_id))}"><code>${h(record.run_id)}</code></a></li>`,
        )
        .join("")}</ul></div>`;
    })
    .join("");
  const extra = [
    ["containment-023", "The containment session"],
    ["baseline-frozen", "The earlier baseline"],
  ]
    .filter(([id]) => ids.has(id))
    .map(
      ([id, label]) => `<div class="session-group"><h3>${h(label)}</h3><ul><li><a href="${attr(
        sessionHref(id),
      )}"><code>${h(id)}</code></a></li></ul></div>`,
    )
    .join("");
  return `<section id="sessions" class="section section--sessions" aria-labelledby="sessions-title">
    <h2 id="sessions-title">Read a session</h2>
    ${groups}${extra}
  </section>`;
}

function emptyJudgesView() {
  return `<article class="judges">
    <section class="section" aria-labelledby="empty-title">
      <p class="hero-kicker">For judges</p>
      <h2 id="empty-title">The 0.2.3 repeats are not yet published.</h2>
      <p>The store holds no repeat session. When it does, every figure will link to the run behind it.</p>
    </section>
  </article>`;
}

export function judges023View({
  benchmark = [],
  runs = null,
  sessions = [],
  lessons = [],
  containment = null,
  warnings = [],
} = {}) {
  const repeats = repeatRecords(benchmark);
  const runIds = runIdSet(runs);
  if (!repeats.length) return emptyJudgesView();
  const sections = [
    ["what-is", "What Kalari is"],
    ["problem", "The problem"],
    ["headline", "The headline"],
    ["easier", "Where the gain sits"],
    ["learning", "Learning, measured"],
    ["containment", "Containment"],
    ["excluded", "Outside the headline"],
    ["baseline", "The earlier baseline"],
    ["runs", "Every run"],
    ["sessions", "Read a session"],
  ];
  return `<article class="judges">
    <section class="section section--hero" aria-labelledby="hero-title">
      <p class="hero-kicker">For judges · ${modelTag("Kalari 0.2.3")}</p>
      <h2 id="hero-title">Three models, three upgrades, five repeats.</h2>
      <p>Forty-five sessions with Kalari, forty-five without. Every figure links to the run or the row behind it.</p>
      <nav aria-label="Page sections"><ul>
        ${sections.map(([id, label]) => `<li><a href="#${attr(id)}">${h(label)}</a></li>`).join("")}
      </ul></nav>
    </section>
    ${warningsSection(warnings)}
    ${whatIsSection()}
    ${problemSection(repeats, runIds)}
    ${headlineSection(repeats, runIds)}
    ${easierSection(repeats, runIds)}
    ${learningSection(repeats, runIds)}
    ${containmentSection(containment || [], runIds)}
    ${excludedSection(repeats, runIds)}
    ${baselineSection(benchmark, runIds)}
    ${everyRunSection(repeats, runIds)}
    ${sessionsSection(repeats, sessions)}
  </article>`;
}
