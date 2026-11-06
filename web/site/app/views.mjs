/* The views that matter to a judge: the evidence index, a session, and a run.
   Every function here returns a string. Nothing touches the DOM, so the same
   view code runs in the browser and in the snapshot generator. */

import {
  attr,
  boolWord,
  capitalise,
  count,
  countWord,
  escapeHtml as h,
  isId,
  measure,
  milliseconds,
  money,
  percent,
  plain,
  redactUrls,
  runHref,
  runLink,
  seconds,
  sessionHref,
  tokens,
  unique,
  verdictWord,
} from "./format.mjs";
import {
  BEHAVIOURS,
  BEHAVIOUR_BLURBS,
  CONDITIONS,
  conditionBlurb,
  conditionLabel,
  changeKindLabel,
  clefLabel,
  observationLabel,
  upgradeFormat,
  upgradeLabel,
} from "./labels.mjs";

const CLEF_OPINION_LABEL = "A model's opinion, not a measurement";

/* Pinned evidence commit. Every "Evidence on GitHub" link points at this
   commit, never at main, so a judge opens the exact files the page cites.
   Set to the evidence commit before publishing. The check verifies the hash
   exists and every linked path exists at it. */
export const EVIDENCE_REF = "788ecda667628352cbf2ae07366981fd0c994a46";

const GITHUB_REPO = "https://github.com/nrynss/kalari";

function githubUrl(path, fragment = "") {
  return `${GITHUB_REPO}/blob/${EVIDENCE_REF}/${path}${fragment ? `#${fragment}` : ""}`;
}

function evidenceLink(url, label) {
  return `<a class="evidence-link" href="${attr(url)}">${h(label)}</a>`;
}

/* A model or tool version string. Versions carry digits, but they are names,
   not figures, so they never link to a run. The check allows only known
   names inside this marker. */
function modelTag(name) {
  return `<span class="model-tag">${h(name)}</span>`;
}

function object(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : null;
}

function payloadOf(record) {
  return object(record?.payload) || {};
}

function ofKind(records, kind) {
  return (records || []).filter((record) => record && record.kind === kind);
}

function isBenchmarkPayload(payload) {
  return Boolean(payload && "condition" in payload && "upgrade" in payload);
}

export function benchmarkRecords(records) {
  return ofKind(records, "benchmark").filter((record) => isBenchmarkPayload(payloadOf(record)));
}

function runIdSet(runs) {
  return Array.isArray(runs) ? new Set(runs) : null;
}

function badge(text, tone = "neutral") {
  return `<span class="badge badge--${attr(tone)}">${h(text)}</span>`;
}

function armLabel(arm) {
  if (arm === "kalari") return "Kalari arm";
  if (arm === "reference") return "reference arm";
  return "arm unknown";
}

function conditionArm(conditionGroup) {
  const firstUpgrade = conditionGroup.upgrades?.[0];
  const firstRecord = firstUpgrade?.records?.[0];
  return payloadOf(firstRecord).arm;
}

function conditionProvenance(conditionGroup) {
  const firstUpgrade = conditionGroup.upgrades?.[0];
  const firstRecord = firstUpgrade?.records?.[0];
  return payloadOf(firstRecord).provenance === "frozen" ? "frozen" : "pilot";
}

function warningsSection(warnings) {
  if (!Array.isArray(warnings) || !warnings.length) return "";
  return `<div class="notice notice--warning" role="alert">
    <h2>Some evidence could not be loaded</h2>
    <ul>${warnings.map((warning) => `<li>${h(warning)}</li>`).join("")}</ul>
    <p>The page shows the records it could read. A figure that cannot link to its run is not shown.</p>
  </div>`;
}

/* ------------------------------------------------------------------ */
/* What Kalari is, and how to use it                                    */
/* ------------------------------------------------------------------ */

const TOOL_JOBS = [
  ["what_changed", "Lists the changes between two API versions, with stable change IDs."],
  ["blast_radius", "Finds the callers and tests each change touches."],
  ["recall_lessons", "Returns lessons for these change kinds as checks that must pass."],
  ["run_in_sandbox", "Runs the new code in a throwaway microVM behind the proved gate. It returns the verdict and logs."],
  ["record_lesson", "Stores what a verified run showed about the API, keyed by change kind."],
];

function whatIsSection() {
  return `<section id="what-is" class="section section--whatis" aria-labelledby="what-is-title">
    <p class="hero-kicker">What Kalari is</p>
    <h2 id="what-is-title">A rehearsal arena for API upgrades.</h2>
    <p>Kalari plugs into the coding agent you already use over MCP and rehearses an API upgrade in a contained arena. It works out what changed and what it touches. It runs the new code in a throwaway microVM against the real API, with the old version as the reference. It records what the run proved.</p>
    <p>The agent writes the code, and Kalari decides what has to be checked and whether it passed.</p>
    <ul class="tools-row" aria-label="The five Kalari tools">
      ${TOOL_JOBS.map(
        ([name, job]) =>
          `<li><code>${h(name)}</code><span>${h(job)}</span></li>`,
      ).join("")}
    </ul>
    <p class="fine-print tools-proof">The five tools live in ${evidenceLink(githubUrl("Kalari/Mcp.lean"), "Kalari/Mcp.lean on GitHub")}. The gate is proved, not just tested. Four theorems cover the workspace, the network, the caps and the secrets: ${evidenceLink(githubUrl("Kalari/Gate.lean", "L189"), "decide_workspace")}, ${evidenceLink(githubUrl("Kalari/Gate.lean", "L201"), "decide_network")}, ${evidenceLink(githubUrl("Kalari/Gate.lean", "L211"), "decide_caps")}, ${evidenceLink(githubUrl("Kalari/Gate.lean", "L222"), "decide_secrets")}.</p>
    <h3>Use it in three steps.</h3>
    <ol class="steps">
      <li>Run <code>kalari serve</code> with a config file and a session file.</li>
      <li>Add Kalari to your agent as an MCP server:
        <pre class="config-snippet"><code>{
  "mcp": {
    "servers": {
      "kalari": {
        "type": "local",
        "command": ["kalari", "serve", "kalari.json", "session.json"]
      }
    }
  }
}</code></pre>
      </li>
      <li>Ask your agent to upgrade the consumer. Kalari checks each run and records the evidence.</li>
    </ol>
    <p><a class="button" href="/docs/">Read the docs</a></p>
  </section>`;
}

function groupBy(records, keyOf) {
  const groups = new Map();
  for (const record of records) {
    const key = keyOf(record);
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(record);
  }
  return groups;
}

function byCondition(records) {
  const groups = groupBy(records, (record) => String(payloadOf(record).condition));
  const result = [];
  for (const [condition, group] of groups) {
    const upgrades = groupBy(group, (record) => String(payloadOf(record).upgrade));
    const upgradesOut = [];
    for (const [upgrade, upgradeRecords] of upgrades) {
      upgradeRecords.sort(
        (a, b) => (Number(payloadOf(a).repeat) || 0) - (Number(payloadOf(b).repeat) || 0),
      );
      upgradesOut.push({ upgrade, records: upgradeRecords });
    }
    upgradesOut.sort((a, b) => a.upgrade.localeCompare(b.upgrade));
    result.push({ condition: Number(condition), upgrades: upgradesOut });
  }
  result.sort((a, b) => a.condition - b.condition);
  return result;
}

function byBehaviour(records) {
  return records
    .slice()
    .sort((a, b) => {
      const left = payloadOf(a);
      const right = payloadOf(b);
      return (
        String(left.upgrade).localeCompare(String(right.upgrade)) ||
        String(left.behaviour).localeCompare(String(right.behaviour)) ||
        (Number(left.repeat) || 0) - (Number(right.repeat) || 0)
      );
    });
}

function passCount(records) {
  return records.filter((record) => payloadOf(record).verdict === "PASS").length;
}

function firstTimeCount(records) {
  return records.filter((record) => payloadOf(record).right_first_time === true).length;
}

function allPassed(records) {
  return records.length > 0 && passCount(records) === records.length;
}

function allFirstTime(records) {
  return records.length > 0 && firstTimeCount(records) === records.length;
}

function repeatCount(records) {
  return unique(
    records.map((record) => Number(payloadOf(record).repeat)).filter((value) => Number.isFinite(value)),
  ).length;
}

function repeatCountPhrase(count) {
  return `${countWord(count)} ${count === 1 ? "repeat" : "repeats"}`;
}

/* The pilot caveat covers two columns, so the phrase must hold for both.
   When the two counts differ, each column gets its own count. */
function repeatSentence(left, leftWhere, right, rightWhere) {
  const leftCount = repeatCount(left);
  const rightCount = repeatCount(right);
  if (!leftCount || !rightCount) return "The repeats";
  if (leftCount === rightCount) return `${capitalise(repeatCountPhrase(leftCount))} each`;
  return `${capitalise(repeatCountPhrase(leftCount))} ${leftWhere}, ${repeatCountPhrase(rightCount)} ${rightWhere}`;
}

function frozenRepeatSentence(before, after) {
  const beforeCount = repeatCount(before);
  const afterCount = repeatCount(after);
  if (beforeCount && afterCount && beforeCount !== afterCount) {
    return `${capitalise(repeatCountPhrase(beforeCount))} for the reference arm, ${repeatCountPhrase(
      afterCount,
    )} for the Kalari arm`;
  }
  const count = beforeCount || afterCount;
  if (!count) return "The repeats";
  return `${capitalise(repeatCountPhrase(count))} per condition`;
}

function tallySentence(records) {
  if (!records.length) return "No sessions recorded.";
  const total = records.length;
  const passed = passCount(records);
  const first = firstTimeCount(records);
  if (passed === total && first === total) {
    return "Every session passed, and every one was right first time.";
  }
  if (passed === total) {
    return `Every session passed. ${capitalise(countWord(first))} of ${countWord(total)} were right first time.`;
  }
  if (passed === 0) {
    return `None of the ${countWord(total)} passed.`;
  }
  return `${capitalise(countWord(passed))} of ${countWord(total)} passed.`;
}

function medianRecord(records, key) {
  const values = records.filter((record) => Number.isFinite(payloadOf(record)[key]));
  if (!values.length) return null;
  values.sort((a, b) => payloadOf(a)[key] - payloadOf(b)[key]);
  return values[Math.floor((values.length - 1) / 2)];
}

function medianLine(records, key, formatter, label, runIds) {
  const middle = medianRecord(records, key);
  if (!middle) return "";
  const value = payloadOf(middle)[key];
  return `<p class="median-line"><span class="median-label">${h(label)}</span><span class="median-value">${measure(
    middle.run_id,
    value,
    formatter,
    label,
    runIds,
  )}</span></p>`;
}

function worstLine(records, key, formatter, label, runIds) {
  const values = records.filter((record) => Number.isFinite(payloadOf(record)[key]));
  if (!values.length) return "";
  values.sort((a, b) => payloadOf(b)[key] - payloadOf(a)[key]);
  const worst = values[0];
  const value = payloadOf(worst)[key];
  if (value === 0) {
    return `<p class="median-line"><span class="median-label">${h(label)}</span><span class="median-value">none</span></p>`;
  }
  return `<p class="median-line"><span class="median-label">${h(label)}</span><span class="median-value">${measure(
    worst.run_id,
    value,
    formatter,
    label,
    runIds,
  )}</span></p>`;
}

function runWord(record) {
  const repeat = Number(payloadOf(record).repeat);
  return Number.isFinite(repeat) ? countWord(repeat) : "one";
}

function runTally(records, runIds) {
  if (!records.length) return `<p class="muted">No sessions recorded.</p>`;
  const items = records
    .map((record) => {
      const payload = payloadOf(record);
      const passed = payload.verdict === "PASS";
      const first = payload.right_first_time === true;
      const description = `${passed ? "passed" : "failed"}, ${
        first ? "right first time" : "not right first time"
      }`;
      const label = `Run ${runWord(record)}: ${description}`;
      if (!runIds || !runIds.has(record.run_id)) {
        return `<li><span class="tally-dot is-missing" aria-hidden="true"></span><span class="visually-hidden">${h(
          label,
        )}. Evidence missing.</span></li>`;
      }
      return `<li><a class="tally-dot ${passed ? "is-pass" : "is-fail"} ${
        first ? "is-first" : ""
      }" href="${attr(runHref(record.run_id))}" data-run-link="${attr(
        record.run_id,
      )}" aria-label="${attr(label)}"><span class="tally-mark" aria-hidden="true"></span><span class="visually-hidden">${h(
        label,
      )}</span></a></li>`;
    })
    .join("");
  return `<ul class="tally" aria-label="The sessions in this group">${items}</ul>`;
}

function runCell(record, runIds) {
  return `<td class="run-cell" data-label="Run">${runLink(
    record.run_id,
    `<code>${h(record.run_id)}</code>`,
    runIds,
    `Open run ${record.run_id}`,
  )}</td>`;
}

function measuresTable(records, runIds, caption) {
  if (!records.length) return `<p class="muted">No sessions recorded.</p>`;
  const rows = records
    .map((record) => {
      const payload = payloadOf(record);
      return `<tr>
        ${runCell(record, runIds)}
        <td data-label="Verdict"><span class="verdict ${payload.verdict === "PASS" ? "is-pass" : "is-fail"}">${h(
          verdictWord(payload.verdict),
        )}</span></td>
        <td data-label="Right first time">${h(boolWord(payload.right_first_time))}</td>
        <td class="num" data-label="Sandbox runs">${measure(
          record.run_id,
          payload.sandbox_runs,
          count,
          "Sandbox runs",
          runIds,
        )}</td>
        <td class="num" data-label="Wall time">${measure(
          record.run_id,
          payload.wall_time_s,
          seconds,
          "Wall time",
          runIds,
        )}</td>
        <td class="num" data-label="Records lost">${measure(
          record.run_id,
          payload.records_lost,
          count,
          "Records lost",
          runIds,
        )}</td>
        <td class="num" data-label="Records duplicated">${measure(
          record.run_id,
          payload.records_duplicated,
          count,
          "Records duplicated",
          runIds,
        )}</td>
      </tr>`;
    })
    .join("");
  return `<div class="table-wrap"><table class="measures-table">
    ${caption ? `<caption class="visually-hidden">${h(caption)}</caption>` : ""}
    <thead><tr><th scope="col">Run</th><th scope="col">Verdict</th><th scope="col">Right first time</th><th scope="col" class="num">Sandbox runs</th><th scope="col" class="num">Wall time</th><th scope="col" class="num">Records lost</th><th scope="col" class="num">Records duplicated</th></tr></thead>
    <tbody>${rows}</tbody>
  </table></div>`;
}

function tokenRows(records, runIds) {
  return records
    .map((record) => {
      const payload = payloadOf(record);
      return `<tr>
        ${runCell(record, runIds)}
        <td class="num" data-label="Tokens in">${measure(
          record.run_id,
          payload.tokens_input,
          tokens,
          "Input tokens",
          runIds,
        )}</td>
        <td class="num" data-label="Tokens out">${measure(
          record.run_id,
          payload.tokens_output,
          tokens,
          "Output tokens",
          runIds,
        )}</td>
        <td class="num" data-label="Time stuck">${measure(
          record.run_id,
          payload.time_stuck_s,
          seconds,
          "Time stuck",
          runIds,
        )}</td>
        <td class="num" data-label="Cost">${measure(
          record.run_id,
          payload.cost_usd,
          money,
          "List-price cost",
          runIds,
        )}</td>
        <td class="num" data-label="Session cap">${measure(
          record.run_id,
          payload.session_cap_s,
          seconds,
          "Session cap",
          runIds,
        )}</td>
      </tr>`;
    })
    .join("");
}

function gradeRows(records, runIds) {
  return records
    .map((record) => {
      const payload = payloadOf(record);
      const grade = object(payload.grade);
      if (!grade) {
        return `<tr>${runCell(record, runIds)}<td colspan="6" class="muted">No grade record.</td></tr>`;
      }
      return `<tr>
        ${runCell(record, runIds)}
        <td data-label="Grade"><span class="verdict ${
          grade.verdict === "PASS" ? "is-pass" : "is-fail"
        }">${h(verdictWord(grade.verdict))}</span></td>
        <td class="num" data-label="Records">${measure(
          record.run_id,
          grade.records,
          count,
          "Graded records",
          runIds,
        )}</td>
        <td class="num" data-label="Missing">${measure(
          record.run_id,
          grade.missing,
          count,
          "Missing records",
          runIds,
        )}</td>
        <td class="num" data-label="Extra">${measure(record.run_id, grade.extra, count, "Extra records", runIds)}</td>
        <td class="num" data-label="Duplicates">${measure(
          record.run_id,
          grade.duplicates,
          count,
          "Duplicate records",
          runIds,
        )}</td>
        <td class="num" data-label="Mismatched">${measure(
          record.run_id,
          grade.mismatched,
          count,
          "Mismatched records",
          runIds,
        )}</td>
      </tr>`;
    })
    .join("");
}

function detailsTables(records, runIds) {
  const graded = records.filter((record) => object(payloadOf(record).grade));
  return `<details class="more">
    <summary>Tokens, time, cost and the grader</summary>
    <div class="more-body">
      <div class="table-wrap"><table class="measures-table">
        <caption class="visually-hidden">Tokens and time, one row per session.</caption>
        <thead><tr><th scope="col">Run</th><th scope="col" class="num">Tokens in</th><th scope="col" class="num">Tokens out</th><th scope="col" class="num">Time stuck</th><th scope="col" class="num">Cost</th><th scope="col" class="num">Session cap</th></tr></thead>
        <tbody>${tokenRows(records, runIds)}</tbody>
      </table></div>
      ${
        graded.length
          ? `<div class="table-wrap"><table class="measures-table">
        <caption class="visually-hidden">The hidden grader, one row per session.</caption>
        <thead><tr><th scope="col">Run</th><th scope="col">Grade</th><th scope="col" class="num">Records</th><th scope="col" class="num">Missing</th><th scope="col" class="num">Extra</th><th scope="col" class="num">Duplicates</th><th scope="col" class="num">Mismatched</th></tr></thead>
        <tbody>${gradeRows(records, runIds)}</tbody>
      </table></div>`
          : ""
      }
    </div>
  </details>`;
}

function conditionSection(conditionGroup, runIds, tone = "valid") {
  const { condition, upgrades } = conditionGroup;
  const arm = conditionArm(conditionGroup);
  const provenance = conditionProvenance(conditionGroup);
  const badgeText =
    tone === "invalid"
      ? `Invalid ${provenance} row`
      : tone === "diagnostic"
        ? "Diagnostic session"
        : tone === "frozen"
          ? `Frozen, ${armLabel(arm)}`
          : `${capitalise(provenance)}, ${armLabel(arm)}`;
  const badgeTone = tone === "invalid" ? "fail" : tone === "diagnostic" ? "pilot" : tone === "frozen" ? "live" : "pilot";
  return `<section class="condition">
    <header class="condition-head">
      <div class="condition-title"><h3>${h(conditionLabel(condition))}</h3>${badge(badgeText, badgeTone)}</div>
      <p>${h(conditionBlurb(condition))}</p>
    </header>
    ${upgrades
      .map(({ upgrade, records }) => {
        return `<div class="upgrade-block">
          <div class="upgrade-head">
            <h4>${h(upgradeLabel(upgrade))} <span class="format">${h(upgradeFormat(upgrade))}</span></h4>
            <p>${h(
              upgrade === "payouts"
                ? "The old endpoint returns every payout in one response. The new one is a windowed export."
                : "The old schema returns a plain list. The new one is a Relay-style connection.",
            )}</p>
          </div>
          ${runTally(records, runIds)}
          <p class="tally-note">${h(tallySentence(records))}</p>
          ${measuresTable(
            records,
            runIds,
            `${conditionLabel(condition)}, ${upgradeLabel(upgrade)}: one row per session.`,
          )}
          ${detailsTables(records, runIds)}
        </div>`;
      })
      .join("")}
  </section>`;
}

function conditionGroupsSection(groups, runIds, tone) {
  if (!groups.length) return "";
  return `<div class="condition-list">${groups
    .map((group) => conditionSection(group, runIds, tone))
    .join("")}</div>`;
}

function contrastColumn({ title, records, runIds, note, condition, upgrade, provenance }) {
  return `<div class="contrast-column" data-condition="${attr(String(condition))}" data-upgrade="${attr(
    upgrade,
  )}" data-provenance="${attr(provenance)}">
    <h4>${h(title)}</h4>
    ${note ? `<p class="contrast-note">${h(note)}</p>` : ""}
    ${runTally(records, runIds)}
    <p class="tally-note">${h(tallySentence(records))}</p>
    ${medianLine(records, "wall_time_s", seconds, "Median wall time", runIds)}
    ${medianLine(records, "sandbox_runs", count, "Median sandbox runs", runIds)}
  </div>`;
}

function pilotContrast(valid, runIds) {
  const fresh = valid.filter(
    (record) => payloadOf(record).condition === 3 && payloadOf(record).upgrade === "settlements",
  );
  const notes = valid.filter(
    (record) => payloadOf(record).condition === 2 && payloadOf(record).upgrade === "settlements",
  );
  if (!fresh.length || !notes.length) {
    return `<div class="notice notice--quiet"><p>The pilot has no comparable notes-handoff pair for settlements yet.</p></div>`;
  }
  const freshPayouts = valid.filter(
    (record) => payloadOf(record).condition === 3 && payloadOf(record).upgrade === "payouts",
  );
  const notesPayouts = valid.filter(
    (record) => payloadOf(record).condition === 2 && payloadOf(record).upgrade === "payouts",
  );
  const payoutsLine =
    allPassed(freshPayouts) && allFirstTime(freshPayouts) && allPassed(notesPayouts) && allFirstTime(notesPayouts)
      ? "On payouts, both conditions passed every session first time."
      : "On payouts, the two conditions did not match. The tables below show each session.";
  return `<div class="contrast" data-contrast="pilot">
    <h3>The pilot baseline: the notes handoff on settlements</h3>
    <p class="caveat">Both columns are the reference setup. ${repeatSentence(
      fresh,
      "on the fresh side",
      notes,
      "on the notes side",
    )}. This is the reference baseline, not Kalari's comparison.</p>
    <div class="contrast-grid">
      ${contrastColumn({
        title: "Fresh session, no notes",
        records: fresh,
        runIds,
        note: "A new session for upgrade two, with no earlier context.",
        condition: 3,
        upgrade: "settlements",
        provenance: "pilot",
      })}
      ${contrastColumn({
        title: "New session with notes",
        records: notes,
        runIds,
        note: "The agent reads the notes it wrote after upgrade one.",
        condition: 2,
        upgrade: "settlements",
        provenance: "pilot",
      })}
    </div>
    <p class="caveat caveat--last">${h(payoutsLine)}</p>
  </div>`;
}

function frozenUpgradeContrast(frozen, upgrade, runIds) {
  const after = frozen.filter(
    (record) => payloadOf(record).condition === 5 && payloadOf(record).upgrade === upgrade,
  );
  const before = frozen.filter(
    (record) => payloadOf(record).condition === 3 && payloadOf(record).upgrade === upgrade,
  );
  if (!after.length || !before.length) return "";
  return `<div class="contrast" data-contrast="frozen" data-upgrade="${attr(upgrade)}">
    <h3>The frozen comparison: ${h(upgradeLabel(upgrade))}</h3>
    <p class="caveat">${frozenRepeatSentence(before, after)}. Counts, never percentages. The tables below show every session, and every figure links to its run.</p>
    <div class="contrast-grid">
      ${contrastColumn({
        title: "Reference, fresh session",
        records: before,
        runIds,
        note: "The reference setup, with no notes.",
        condition: 3,
        upgrade,
        provenance: "frozen",
      })}
      ${contrastColumn({
        title: "Kalari, with the lesson",
        records: after,
        runIds,
        note: "OpenCode with Kalari, and the lesson from upgrade one.",
        condition: 5,
        upgrade,
        provenance: "frozen",
      })}
    </div>
    <div class="loss-grid">
      <div>
        <h4>Reference</h4>
        ${worstLine(before, "records_lost", count, "Worst run: records lost", runIds)}
        ${worstLine(before, "records_duplicated", count, "Worst run: records duplicated", runIds)}
      </div>
      <div>
        <h4>Kalari</h4>
        ${worstLine(after, "records_lost", count, "Worst run: records lost", runIds)}
        ${worstLine(after, "records_duplicated", count, "Worst run: records duplicated", runIds)}
      </div>
    </div>
  </div>`;
}

function frozenContrast(frozen, runIds) {
  const upgrades = unique(frozen.map((record) => payloadOf(record).upgrade));
  const blocks = upgrades.map((upgrade) => frozenUpgradeContrast(frozen, upgrade, runIds)).filter(Boolean);
  if (!blocks.length) {
    return `<div class="notice notice--quiet"><p>The frozen comparison needs condition five and condition three for one upgrade. One of them is not in the store yet.</p></div>`;
  }
  return `${blocks.join("")}
    <p class="caveat caveat--last">The verifier-prompt rows below are the control. If they match Kalari, say so plainly.</p>`;
}

function notPublishedPanel(hasFrozenParts) {
  const lead = hasFrozenParts
    ? "Some frozen rows are in the store. No upgrade has both condition five and condition three yet, so the comparison is not published."
    : "The pilot below is the reference arm. The Kalari arm has not run on the frozen pair.";
  return `<div class="notice notice--pending" role="status">
    <h3>The frozen comparison is not yet published.</h3>
    <p>${lead}</p>
    <p>When it is, this panel will show Kalari with the lesson against the fresh session, the notes handoff and the verifier prompt. It will report verdicts, right first time, sandbox attempts, wall time, time stuck, tokens, and records lost or duplicated. Every figure will link to its run.</p>
    <p><a href="#baseline">The baseline pilot is published below.</a></p>
  </div>`;
}

function comparisonSection(bench, runIds, hasFrozenPair) {
  if (!bench.length) {
    return `<h2>Benchmark results are not yet published.</h2>
      <p>The page is waiting for benchmark records in the evidence store. A producer will write one record per run. No producer exists yet.</p>
      <p>When it does, this page will show the frozen before-and-after, each condition's result, and the containment moment. Every figure will link to the run that produced it.</p>
      <p>The session view is ready now. It shows the shape of the evidence the page will read.</p>`;
  }
  const frozen = bench.filter(
    (record) =>
      payloadOf(record).provenance === "frozen" &&
      payloadOf(record).status !== "invalid" &&
      payloadOf(record).status !== "diagnostic",
  );
  const validPilot = bench.filter(
    (record) => payloadOf(record).provenance !== "frozen" && payloadOf(record).status === "valid",
  );
  const heading = hasFrozenPair ? "The measured before and after" : "The pilot baseline";
  return `<h2>${heading}</h2>
    <p class="comparison-models">Both arms ran ${modelTag("OpenCode 2.2.5")} with ${modelTag(
      "DeepSeek V4.1 Flash",
    )} on Vultr Serverless Inference.</p>
    <p class="evidence-row">Evidence on GitHub: ${evidenceLink(
      githubUrl("bench/RESULTS.md", "2-the-comparison-table"),
      "The comparison table",
    )} · ${evidenceLink(githubUrl("bench/RESULTS.md", "4-the-basis-of-cost-and-token-figures"), "Cost and token basis")} · ${evidenceLink(
      githubUrl("bench/RESULTS.md", "6-containment-configured-policy-versus-observed-outcome"),
      "Containment policy",
    )} · ${evidenceLink(githubUrl("bench/FROZEN.md"), "The frozen pair")}</p>
    ${hasFrozenPair ? frozenContrast(frozen, runIds) : notPublishedPanel(frozen.length > 0)}
    ${validPilot.length ? pilotContrast(validPilot, runIds) : ""}`;
}

/* The containment runs. They are not benchmark sessions: no frozen row was ever
   capped (RESULTS.md section 6). Two ordinary runs through the production
   sandbox path, both constructed for this test, kept in their own session apart
   from the benchmark records. The run the time cap stopped is the main moment.
   The run before it crashed on a 429 and never reached the cap. */
export const CONTAINMENT_SESSION = "containment-runs";

const CONTAINMENT_ATTEMPTS = {
  allowed: "the one API port the allowlist names",
  "other-port-same-host": "a different port on that same host",
  "host-ssh": "the host's own SSH port",
  "metadata-link-local": "the cloud metadata address",
  internet: "a public internet address",
};

function containmentRecords(records) {
  return ofKind(records, "containment").filter(
    (record) => payloadOf(record).schema === "kalari.containment.v1" && isId(record.run_id),
  );
}

/* The run the time cap stopped, or else the first run. */
function containmentOf(records) {
  const all = containmentRecords(records);
  return all.find((record) => object(payloadOf(record).result)?.verdict === "killed_timeout") || all[0];
}

function earlierContainment(records) {
  const main = containmentOf(records);
  return containmentRecords(records).filter((record) => record !== main);
}

function msText(value) {
  return `${count(value)} ms`;
}

function containmentSection(records, runIds) {
  const record = containmentOf(records);
  if (!record) return "";
  const p = payloadOf(record);
  const config = object(p.config) || {};
  const result = object(p.result) || {};
  const outcomes = object(p.outcomes) || {};
  const network = object(p.network) || {};
  const observed = object(network.observed) || {};
  const effective = object(network.effective) || {};
  const cleanup = object(p.cleanup) || {};
  const runId = record.run_id;
  const hasRun = runIds && runIds.has(runId);
  const link = (id, value, label, text = msText) =>
    Number.isFinite(value)
      ? runIds && runIds.has(id)
        ? runLink(id, h(text(value)), runIds, label)
        : h("evidence missing")
      : h("not recorded");
  const attempts = Array.isArray(observed.attempts) ? observed.attempts : [];
  const lines = (expected, good, bad, fallback) =>
    attempts
      .filter((item) => item && item.expected === expected)
      .map(
        (item) =>
          `<li>${h(capitalise(CONTAINMENT_ATTEMPTS[item.label] || fallback))}: ${
            item.observed === expected ? good : `<strong>${bad}</strong>`
          }</li>`,
      )
      .join("");
  const refusedLines = lines("refused", "refused", "answered", "another destination");
  const allowedLines = lines("allowed", "answered, as the rule allows", "did not answer", "the allowed destination");
  const breaches = Number(observed.breaches) || 0;
  const rules = Array.isArray(effective.rules) ? effective.rules : [];
  const created = Array.isArray(cleanup.sandboxes_created) ? cleanup.sandboxes_created : [];
  const stillListed = Array.isArray(cleanup.still_listed) ? cleanup.still_listed : [];
  const children = Array.isArray(cleanup.child_processes_remaining) ? cleanup.child_processes_remaining : [];
  const before = Array.isArray(cleanup.pre_existing_before) ? cleanup.pre_existing_before : [];
  const cleanOk = cleanup.ok === true;
  const earlier = earlierContainment(records).map((item) => {
    const q = payloadOf(item);
    const r = object(q.result) || {};
    const ok = object(object(q.network)?.observed)?.breaches === 0 && object(q.cleanup)?.ok === true;
    return `<div class="containment-earlier">
        <h3 class="containment-step">The run before it</h3>
        <p class="containment-note">The first run used the reference cursor-loop consumer, which has no retry. The payouts API throttles every traversal once, with a rate-limit reply. That consumer did not handle it: the program <strong>exited with a non-zero status</strong> after ${link(
          item.run_id,
          r.wall_ms,
          "Containment run: measured wall time",
        )}, well inside its time cap, and passed is ${h(r.passed === false ? "false" : String(r.passed))}. The cap never came into play. ${
          ok
            ? "Its own boundary probe and cleanup came out the same way."
            : "<strong>Its boundary probe or cleanup did not verify.</strong> See its page."
        }</p>
        <p class="containment-links"><a class="quiet-link quiet-link--light" href="${attr(runHref(item.run_id))}" data-run-link="${attr(
          item.run_id,
        )}">Read the run that crashed on the rate limit</a></p>
      </div>`;
  });
  return `<section id="containment" class="containment" aria-labelledby="containment-title">
    <div class="containment-inner">
      <p class="containment-context">Two runs through the same sandbox path · not benchmark sessions</p>
      <h2 id="containment-title">A consumer that never ends, stopped by its time cap.</h2>
      <p class="containment-lede">A payouts consumer was run in a fresh microVM through the same <code>run_in_sandbox</code> path the agent uses. It waits out a rate-limit reply as <code>Retry-After</code> asks, then follows the page cursor on every response, drained or not, so it never ends. The aashaan killed it at the cap this run was given. This is apart from the benchmark: no session in the frozen comparison was stopped by a cap.</p>
      <p class="containment-note">No model. A fixed consumer ran through <code>run_in_sandbox</code>.</p>
      <p class="evidence-row evidence-row--light">Evidence on GitHub: ${evidenceLink(
        githubUrl("tests/live/containment-transcript.txt"),
        "The containment log",
      )} · ${evidenceLink(
        githubUrl("tests/live/containment-evidence/run-1.jsonl"),
        "The first run record",
      )} · ${evidenceLink(
        githubUrl("tests/live/containment-evidence/run-2.jsonl"),
        "The second run record",
      )} · ${evidenceLink(
        githubUrl("bench/RESULTS.md", "6a-two-sandbox-runs-outside-the-comparison"),
        "The comparison notes",
      )}</p>
      <h3 class="containment-step">The failure</h3>
      <div class="containment-measures">
        <div class="containment-measure">
          <span class="containment-measure-label">Configured time cap</span>
          <span class="containment-measure-value">${link(runId, config.time_cap_ms, "Containment run: configured time cap")}</span>
        </div>
        <div class="containment-measure">
          <span class="containment-measure-label">Measured wall time</span>
          <span class="containment-measure-value">${link(runId, result.wall_ms, "Containment run: measured wall time")}</span>
        </div>
        <div class="containment-measure">
          <span class="containment-measure-label">The verdict</span>
          <span class="containment-measure-value">${h(verdictWord(result.verdict))}</span>
          <span class="containment-measure-sub"><code>${h(String(result.verdict || "unknown"))}</code> · passed is ${h(
            result.passed === false ? "false" : String(result.passed),
          )}</span>
        </div>
      </div>
      <p class="containment-note">${
        Number.isFinite(result.pages_fetched)
          ? `It fetched ${link(runId, result.pages_fetched, "Containment run: pages fetched", (value) => `${count(value)} pages`)} before the kill, one line each in its output, and waited out the rate limit once. `
          : ""
      }The supervisor checks the clock by polling, so the measured time can run past the cap. No fixed overshoot bound is promised. The candidate was killed. The baseline guest was never started, because the candidate wrote no output, and the differential check failed. The run page has the exact detail.</p>
      <p class="containment-note">Output cap ${
        Number.isFinite(config.output_cap_bytes) && hasRun
          ? runLink(runId, h(`${count(config.output_cap_bytes)} bytes`), runIds, "Containment run: configured output cap")
          : h("not recorded")
      } and memory ${
        Number.isFinite(config.memory_mib) && hasRun
          ? runLink(runId, h(`${count(config.memory_mib)} MiB`), runIds, "Containment run: configured memory")
          : h("not recorded")
      } are configuration only. Neither fired in this run.</p>
      <h3 class="containment-step">The boundary</h3>
      <p class="containment-note">Requested: no network, plus ${h(countWord(rules.length))} allow rule for the one API port. Effective, read back from <code>msb inspect</code> right after create: default egress ${h(
        String(effective.default_egress || "unknown"),
      )}, default ingress ${h(String(effective.default_ingress || "unknown"))}, ${h(countWord(rules.length))} rule. Observed: a probe in a second guest created with the same arguments and the same allowlist asked for these.</p>
      <ul class="containment-list">${refusedLines}${allowedLines}</ul>
      <p class="containment-note">${
        breaches === 0
          ? `Every request the allowlist does not name was refused (${h(countWord(Number(observed.denied_and_refused) || 0))} of ${h(
              countWord(Number(observed.denied_attempts) || 0),
            )}).`
          : "<strong>At least one request outside the allowlist was answered.</strong> See the run page."
      } The probe is a separate guest, so this is evidence about the configuration, not about the guest that ran the consumer.</p>
      <h3 class="containment-step">The cleanup</h3>
      <p class="containment-note">${
        cleanOk
          ? `This test created ${h(countWord(created.length))} sandboxes. After the run, ${h(
              stillListed.length ? countWord(stillListed.length) : "none",
            )} of them were still listed, no child process of the run remained (${h(
              children.length ? countWord(children.length) : "none",
            )}), and the ${h(countWord(before.length))} sandboxes that existed before were present and unchanged.`
          : "<strong>The cleanup did not verify.</strong> See the run page."
      }</p>
      <p class="containment-note containment-caveat">These are observed restrictions for the listed requests, from one guest configuration. This is not a claim of zero blast radius.</p>
      ${earlier.join("")}
      <div class="containment-links">
        ${
          hasRun
            ? `<a class="button button--light" href="${attr(runHref(runId))}" data-run-link="${attr(
                runId,
              )}">Read the run and its evidence</a>`
            : ""
        }
        <a class="quiet-link quiet-link--light" href="${attr(sessionHref(CONTAINMENT_SESSION))}">Open the session</a>
      </div>
    </div>
  </section>`;
}

/* ------------------------------------------------------------------ */
/* Across models: the showcase disbursements                            */
/* ------------------------------------------------------------------ */

export const SHOWCASE_SESSION = "showcase-disbursements";
export const LEAD_SHOWCASE_RUN = "showcase-kalari-glm-r3";

const SHOWCASE_MODELS = ["GLM 5.3 Flash", "Qwen3.8 27B", "Muse Glimmer 30B", "MiMo V2.6 Flash", "DeepSeek V4.1 Flash"];

function showcaseRecords(records) {
  return ofKind(records, "showcase").filter(
    (record) => object(record?.payload)?.schema === "kalari.showcase.v1" && isId(record.run_id),
  );
}

function showcaseRunText(record) {
  const p = payloadOf(record);
  const label = p.label || record.run_id;
  const verdict = p.verdict === "PASS" ? "Passed" : p.verdict === "FAIL" ? "Failed" : "Unknown";
  const extras = [];
  if (Number.isFinite(p.records_lost) && p.records_lost > 0) extras.push(`${count(p.records_lost)} lost`);
  if (Number.isFinite(p.records_duplicated) && p.records_duplicated > 0) extras.push(`${count(p.records_duplicated)} duplicated`);
  if (Number.isFinite(p.records_changed) && p.records_changed > 0) extras.push(`${count(p.records_changed)} changed`);
  if (p.fixed === true && Array.isArray(p.differential) && p.differential.length) {
    extras.push(`fixed after ${p.differential[0]}`);
  } else if (p.flagged === true && p.verdict === "FAIL") {
    extras.push("flagged");
  }
  return `${label}: ${verdict}${extras.length ? `, ${extras.join(", ")}` : ""}`;
}

function showcaseCell(list, runIds) {
  if (!list.length) return `<p class="muted">No session for this model.</p>`;
  return `<ul class="models-runs">${list
    .map(
      (record) =>
        `<li>${runLink(record.run_id, h(showcaseRunText(record)), runIds, "Showcase run")}</li>`,
    )
    .join("")}</ul>`;
}

function modelsSection(records, runIds) {
  const all = showcaseRecords(records);
  if (!all.length) return "";
  const rows = SHOWCASE_MODELS.map((model) => {
    const ref = all.filter((record) => payloadOf(record).model === model && payloadOf(record).arm === "reference");
    const kal = all.filter((record) => payloadOf(record).model === model && payloadOf(record).arm === "kalari");
    return `<div class="models-row">
      <div class="models-model"><h3>${modelTag(model)}</h3></div>
      <div class="models-cell models-cell--reference"><h4>OpenCode alone</h4>${showcaseCell(ref, runIds)}</div>
      <div class="models-cell models-cell--kalari"><h4>OpenCode with Kalari</h4>${showcaseCell(kal, runIds)}</div>
    </div>`;
  }).join("");
  return `<section id="models" class="section section--models" aria-labelledby="models-title">
    <p class="hero-kicker">Across models</p>
    <h2 id="models-title">Without Kalari, the corruption shipped silently. With Kalari, every session that had it was flagged with the evidence.</h2>
    <p class="models-lede">One manufactured upgrade, five models, fourteen sessions. Each cell names its runs and links each run page. Counts come from the hidden grader.</p>
    <div class="models-grid">
      <div class="models-row models-head" aria-hidden="true"><div></div><div>OpenCode alone</div><div>OpenCode with Kalari</div></div>
      ${rows}
    </div>
    <p>GLM alone shipped twenty-three wrong records in two of three sessions. Kalari flagged both GLM sessions that had the fault and fixed one. Qwen and Muse alone shipped the fault, and Kalari flagged both without fixing them. MiMo failed loudly. DeepSeek alone passed all three sessions.</p>
    <p>This scenario is manufactured. It is not part of the frozen comparison.</p>
    <p class="evidence-row">Evidence on GitHub: ${evidenceLink(
      githubUrl("bench/showcase/disbursements/README.md"),
      "The showcase readme",
    )} · ${evidenceLink(githubUrl("bench/showcase/disbursements/QUIRKS.md"), "The quirks file")}</p>
  </section>`;
}

function diagnosticsSection(diagnostic, runIds) {
  if (!diagnostic.length) return "";
  const byGroup = groupBy(diagnostic, (record) =>
    JSON.stringify([payloadOf(record).upgrade, payloadOf(record).behaviour]),
  );
  const sizes = unique([...byGroup.values()].map((group) => group.length));
  const perBehaviour = sizes.length === 1 ? sizes[0] : 0;
  const sessionsText = perBehaviour
    ? `${capitalise(countWord(perBehaviour))} sessions for each behaviour`
    : "Several sessions for each behaviour";
  const rows = byBehaviour(diagnostic)
    .map((record) => {
      const payload = payloadOf(record);
      const behaviour = payload.behaviour || "Behaviour";
      return `<tr>
        <td data-label="Behaviour"><span class="behaviour-code">${h(behaviour)}</span> ${h(
          BEHAVIOURS[behaviour] || "A behaviour",
        )}<span class="behaviour-upgrade">${h(upgradeLabel(payload.upgrade))}</span></td>
        ${runCell(record, runIds)}
        <td data-label="Verdict"><span class="verdict ${
          payload.verdict === "PASS" ? "is-pass" : "is-fail"
        }">${h(verdictWord(payload.verdict))}</span></td>
        <td data-label="Right first time">${h(boolWord(payload.right_first_time))}</td>
        <td class="num" data-label="Sandbox runs">${measure(
          record.run_id,
          payload.sandbox_runs,
          count,
          "Sandbox runs",
          runIds,
        )}</td>
        <td class="num" data-label="Wall time">${measure(
          record.run_id,
          payload.wall_time_s,
          seconds,
          "Wall time",
          runIds,
        )}</td>
        <td class="num" data-label="Records lost">${measure(
          record.run_id,
          payload.records_lost,
          count,
          "Records lost",
          runIds,
        )}</td>
        <td class="num" data-label="Records duplicated">${measure(
          record.run_id,
          payload.records_duplicated,
          count,
          "Records duplicated",
          runIds,
        )}</td>
      </tr>`;
    })
    .join("");
  return `<section class="subsection">
    <h3>Single-behaviour diagnostics</h3>
    <p>${sessionsText}, on the isolated pilot adapter. It restricted the tool surface and network more than the condition rows. These sessions diagnose one behaviour alone and are not compared with the condition rows.</p>
    <div class="table-wrap"><table class="measures-table diagnostics-table">
      <caption class="visually-hidden">Single-behaviour diagnostics.</caption>
      <thead><tr><th scope="col">Behaviour</th><th scope="col">Run</th><th scope="col">Verdict</th><th scope="col">Right first time</th><th scope="col" class="num">Sandbox runs</th><th scope="col" class="num">Wall time</th><th scope="col" class="num">Records lost</th><th scope="col" class="num">Records duplicated</th></tr></thead>
      <tbody>${rows}</tbody>
    </table></div>
  </section>`;
}

function everyRunGroup(records, runIds) {
  const items = records
    .map((record) => {
      const payload = payloadOf(record);
      return `<li>${runLink(
        record.run_id,
        `<code>${h(record.run_id)}</code>`,
        runIds,
        `Open run ${record.run_id}`,
      )}<span class="run-index-verdict ${payload.verdict === "PASS" ? "is-pass" : "is-fail"}">${h(
        verdictWord(payload.verdict),
      )}</span></li>`;
    })
    .join("");
  return `<ul class="run-index-list">${items}</ul>`;
}

function otherRunsGroup(runs, bench, runDetails, runIds) {
  const known = new Set(bench.map((record) => record.run_id));
  const other = (Array.isArray(runs) ? runs : []).filter((runId) => !known.has(runId));
  if (!other.length) return "";
  const items = other
    .slice()
    .sort()
    .map((runId) => {
      const detail = Array.isArray(runDetails?.[runId]) ? runDetails[runId] : [];
      const runRecord = ofKind(detail, "run")[0];
      const payload = payloadOf(runRecord);
      const verdict = payload.verdict?.verdict;
      const contained = containmentOf(detail);
      const label = contained
        ? payloadOf(contained).result?.verdict === "killed_timeout"
          ? "Containment · time cap enforced"
          : "Containment · consumer failure"
        : runId;
      const illustrative = payload.illustrative === true;
      const checkState = runRecord ? runCheckState(runRecord, ofKind(detail, "check")) : "none";
      const checkText =
        checkState === "passed" ? "Checks passed" : checkState === "failed" ? "Checks failed" : "No checks";
      return `<li>${runLink(
        runId,
        `${h(label)}`,
        runIds,
        contained ? "Open containment run" : `Open run ${runId}`,
      )}${illustrative ? badge("Illustrative", "draft") : ""}<span class="run-index-verdict ${
        checkState === "passed" ? "is-pass" : checkState === "failed" ? "is-fail" : ""
      }">${h(verdict ? `${verdictWord(verdict)}. ${checkText}` : "Run record not loaded")}</span></li>`;
    })
    .join("");
  return `<div class="run-group">
    <h3>Sandbox runs</h3>
    <ul class="run-index-list">${items}</ul>
  </div>`;
}

function everyRunSection(bench, runs, runDetails, runIds) {
  const conditions = groupBy(
    bench.filter((record) => "condition" in payloadOf(record) && !payloadOf(record).behaviour),
    (record) => JSON.stringify([payloadOf(record).condition, payloadOf(record).upgrade]),
  );
  const diagnostics = groupBy(
    bench.filter((record) => payloadOf(record).behaviour),
    (record) => JSON.stringify([payloadOf(record).upgrade, payloadOf(record).behaviour]),
  );
  const groups = [];
  for (const [, records] of conditions) {
    const payload = payloadOf(records[0]);
    groups.push({
      title: `${conditionLabel(payload.condition)} · ${upgradeLabel(payload.upgrade)}`,
      records,
    });
  }
  for (const [, records] of diagnostics) {
    const payload = payloadOf(records[0]);
    groups.push({
      title: `${BEHAVIOURS[payload.behaviour] || "A behaviour"} · ${upgradeLabel(payload.upgrade)}`,
      records,
    });
  }
  groups.sort((a, b) => a.title.localeCompare(b.title));
  return `<h2>Every run</h2>
    <p>Every run id in the run index is listed here. Benchmark runs are grouped by condition. Other runs are listed at the end.</p>
    <div class="run-groups">${groups
      .map(
        (group) => `<div class="run-group">
          <h3>${h(group.title)}</h3>
          ${everyRunGroup(group.records, runIds)}
        </div>`,
      )
      .join("")}${otherRunsGroup(runs, bench, runDetails, runIds)}</div>`;
}

function sessionLinksSection(sessions, showcase, runIds) {
  const ids = Array.isArray(sessions) ? sessions : [];
  const cards = [];
  if (ids.includes(SHOWCASE_SESSION)) {
    const lead = (showcase || []).find((record) => record.run_id === LEAD_SHOWCASE_RUN);
    cards.push(`<div class="session-card session-card--lead">
      <span class="badge badge--live">Showcase session</span>
      <h3>Showcase disbursements</h3>
      <p>Fourteen sessions across five models on one manufactured upgrade. Lead run: ${modelTag(
        "GLM 5.3 Flash",
      )}, ${
        lead
          ? runLink(lead.run_id, h(showcaseRunText(lead)), runIds, "Showcase run")
          : "the fix after the flag"
      }.</p>
      <p class="session-card-cta"><a href="${attr(sessionHref(SHOWCASE_SESSION))}">Open the showcase session</a></p>
    </div>`);
  }
  if (ids.includes(CONTAINMENT_SESSION)) {
    cards.push(`<div class="session-card">
      <span class="badge badge--live">Contained runs</span>
      <h3>Containment runs</h3>
      <p>Two fixed consumers through run_in_sandbox. The time cap stopped one.</p>
      <p class="session-card-cta"><a href="${attr(sessionHref(CONTAINMENT_SESSION))}">Open the containment session</a></p>
    </div>`);
  }
  if (ids.includes("frozen-c4-payouts")) {
    cards.push(`<div class="session-card">
      <span class="badge badge--live">Frozen benchmark session</span>
      <h3>Frozen payouts, Kalari arm</h3>
      <p>Five sessions with the lesson from upgrade one.</p>
      <p class="session-card-cta"><a href="${attr(sessionHref("frozen-c4-payouts"))}">Open the frozen session</a></p>
    </div>`);
  }
  if (ids.includes("payouts-upgrade")) {
    cards.push(`<div class="session-card">
      <span class="badge badge--draft">Illustrative walkthrough</span>
      <h3>Upgrading the payout ledger</h3>
      <p>Follow the change facts, the call site, the recalled check, three attempts and the lesson. The change facts and the Clef answer are recorded. The run timings and log excerpts are illustrative.</p>
      <p class="session-card-cta"><a href="${attr(sessionHref("payouts-upgrade"))}">Open the walkthrough</a></p>
    </div>`);
  }
  if (!cards.length) return "";
  return `<h2>Read a full session</h2>
    <p>The run pages show one measurement each. A session page shows the whole trail. It has the change list, the blast radius, the recalled check, each attempt with its logs, and the lesson written.</p>
    <div class="session-cards">${cards.join("")}</div>`;
}

function frozenPairUpgrades(frozen) {
  const byUpgrade = groupBy(frozen, (record) => String(payloadOf(record).upgrade));
  const pairs = [];
  for (const [upgrade, records] of byUpgrade) {
    const hasAfter = records.some((record) => payloadOf(record).condition === 5);
    const hasBefore = records.some((record) => payloadOf(record).condition === 3);
    if (hasAfter && hasBefore) pairs.push(upgrade);
  }
  return pairs.sort();
}

/* ------------------------------------------------------------------ */
/* What Kalari changed: the hero comparison                             */
/* ------------------------------------------------------------------ */

/* Sums over the frozen benchmark rows only. Kalari is conditions 4 and 5.
   Reference is conditions 1, 2, 3 and 6. Cost and wall time compare
   per-session means. Stuck time compares totals. Token columns never enter:
   the arms count tokens differently. */
export const REFERENCE_SESSION = "reference-paging";
export const REFERENCE_RUN = "reference-paging-fix";

function heroSets(bench) {
  const frozen = bench.filter(
    (record) => payloadOf(record).provenance === "frozen" && payloadOf(record).status === "valid",
  );
  return {
    kalari: frozen.filter((record) => payloadOf(record).arm === "kalari"),
    reference: frozen.filter((record) => payloadOf(record).arm === "reference"),
  };
}

function heroSums(records) {
  if (!records.length) return null;
  const sums = {};
  for (const key of ["cost_usd", "wall_time_s", "time_stuck_s"]) {
    const values = records.map((record) => payloadOf(record)[key]);
    if (!values.every((value) => typeof value === "number" && Number.isFinite(value))) return null;
    sums[key] = values.reduce((left, right) => left + right, 0);
  }
  return {
    n: records.length,
    stuckTotal: sums.time_stuck_s,
    costMean: sums.cost_usd / records.length,
    wallMean: sums.wall_time_s / records.length,
  };
}

function heroNumbers(bench) {
  const { kalari, reference } = heroSets(bench);
  const kal = heroSums(kalari);
  const ref = heroSums(reference);
  if (!kal || !ref || kal.costMean <= 0 || ref.costMean <= 0 || kal.wallMean <= 0 || ref.wallMean <= 0) {
    return null;
  }
  return { kalari, reference, kal, ref };
}

function ratioBadge(ratio, winWord, loseWord) {
  if (ratio >= 1) return `${ratio.toFixed(1)}x ${winWord}`;
  return `${(1 / ratio).toFixed(1)}x ${loseWord}`;
}

function stuckBadge(kalTotal, refTotal) {
  if (kalTotal === 0 && refTotal === 0) return "No stuck time on either side";
  if (kalTotal === 0) return "Every hung run was on the reference side";
  if (refTotal === 0) return "Every hung run was on the Kalari side";
  if (refTotal >= kalTotal) return `${(refTotal / kalTotal).toFixed(1)}x less stuck on the Kalari side`;
  return `${(kalTotal / refTotal).toFixed(1)}x more stuck on the Kalari side`;
}

function barWidths(kalValue, refValue) {
  if (!(kalValue > 0) && !(refValue > 0)) return { kal: "0.0%", ref: "0.0%" };
  const large = Math.max(kalValue, refValue);
  return { kal: `${((100 * kalValue) / large).toFixed(1)}%`, ref: `${((100 * refValue) / large).toFixed(1)}%` };
}

function dollars2(value) {
  return `$${Number(value).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

function heroArm({ name, valueText, title, runId, runIds, sessionsText, sessionsTitle, barWidth, tone, worse = false }) {
  return `<div class="hero-arm hero-arm--${attr(tone)}${worse ? " is-worse" : ""}">
    <span class="hero-arm-name">${h(name)}</span>
    <span class="hero-value">${runLink(runId, h(valueText), runIds, title)}</span>
    <span class="hero-sub">${runLink(runId, h(sessionsText), runIds, sessionsTitle)}</span>
    <span class="hero-bar hero-bar--${attr(tone)}" aria-hidden="true"><span style="width: ${attr(barWidth)}"></span></span>
  </div>`;
}

function heroChangedSection(bench, runIds, containment) {
  const numbers = heroNumbers(bench);
  if (!numbers) return "";
  const { kalari, reference, kal, ref } = numbers;
  const kalCostRun = medianRecord(kalari, "cost_usd");
  const refCostRun = medianRecord(reference, "cost_usd");
  const kalWallRun = medianRecord(kalari, "wall_time_s");
  const refWallRun = medianRecord(reference, "wall_time_s");
  const kalStuckWorst = [...kalari].sort((a, b) => payloadOf(b).time_stuck_s - payloadOf(a).time_stuck_s)[0];
  const refStuckWorst = [...reference].sort((a, b) => payloadOf(b).time_stuck_s - payloadOf(a).time_stuck_s)[0];
  const costRatio = ref.costMean / kal.costMean;
  const wallRatio = ref.wallMean / kal.wallMean;
  const costWidths = barWidths(kal.costMean, ref.costMean);
  const wallWidths = barWidths(kal.wallMean, ref.wallMean);
  const stuckWidths = barWidths(kal.stuckTotal, ref.stuckTotal);
  const refStuckRuns = reference.filter((record) => payloadOf(record).time_stuck_s > 0).length;
  const stuckNote =
    refStuckRuns === 0 && kal.stuckTotal === 0
      ? "No session ended in a hung run."
      : `${capitalise(countWord(refStuckRuns))} reference ${
          refStuckRuns === 1 ? "session" : "sessions"
        } recovered from a hung run. ${
          kal.stuckTotal === 0 ? "No Kalari session ended in a hung run." : "Kalari sessions ended in hung runs too."
        }`;
  const kalPass = passCount(kalari);
  const refPass = passCount(reference);
  const verdicts =
    kalPass === kal.n && refPass === ref.n
      ? `<p class="hero-verdicts">Both arms passed the hidden grader in every session. Kalari: ${runLink(
          kalCostRun.run_id,
          `${count(kal.n)}/${count(kal.n)}`,
          runIds,
          "Kalari pass tally",
        )} Reference: ${runLink(refCostRun.run_id, `${count(ref.n)}/${count(ref.n)}`, runIds, "Reference pass tally")}</p>`
      : `<p class="hero-verdicts">Kalari passed ${runLink(
          kalCostRun.run_id,
          `${count(kalPass)} of ${count(kal.n)}`,
          runIds,
          "Kalari pass tally",
        )} sessions. Reference passed ${runLink(
          refCostRun.run_id,
          `${count(refPass)} of ${count(ref.n)}`,
          runIds,
          "Reference pass tally",
        )} sessions.</p>`;
  const main = containmentOf(containment);
  let capKill = "";
  if (main) {
    const p = payloadOf(main);
    const wallMs = object(p.result)?.wall_ms;
    const capMs = object(p.config)?.time_cap_ms;
    if (Number.isFinite(wallMs) && Number.isFinite(capMs)) {
      capKill = `<p class="hero-capkill">One consumer never ends. The aashaan stopped it at the cap: <code>${h(
        object(p.result)?.verdict || "killed_timeout",
      )}</code>, ${runLink(
        main.run_id,
        `${count(wallMs)} ms`,
        runIds,
        "Hero cap-kill wall time",
      )} measured against a ${runLink(main.run_id, `${count(capMs)} ms`, runIds, "Hero cap-kill cap")} cap. <a href="${attr(
        runHref(main.run_id),
      )}" data-run-link="${attr(main.run_id)}">See the cap-kill run</a></p>`;
    }
  }
  const row = ({ heading, kalValue, refValue, kalRun, refRun, kalTitle, refTitle, badgeText, badgeTitle, widths, note, refWorse }) =>
    `<div class="hero-row">
      <h3>${h(heading)}</h3>
      <div class="hero-pair">
        ${heroArm({
          name: "Kalari",
          valueText: kalValue,
          title: kalTitle,
          runId: kalRun.run_id,
          runIds,
          sessionsText: `${count(kal.n)} sessions`,
          sessionsTitle: "Kalari sessions",
          barWidth: widths.kal,
          tone: "kalari",
        })}
        <span class="hero-ratio">${runLink(kalRun.run_id, h(badgeText), runIds, badgeTitle)}</span>
        ${heroArm({
          name: "Reference",
          valueText: refValue,
          title: refTitle,
          runId: refRun.run_id,
          runIds,
          sessionsText: `${count(ref.n)} sessions`,
          sessionsTitle: "Reference sessions",
          barWidth: widths.ref,
          tone: "reference",
          worse: refWorse,
        })}
      </div>
      ${note ? `<p class="hero-note">${h(note)}</p>` : ""}
    </div>`;
  return `<section id="changed" class="section section--changed" aria-labelledby="changed-title">
    <p class="hero-kicker">What Kalari changed</p>
    <h2 id="changed-title">Cheaper is good. Faster is good. Both at once is the headline.</h2>
    <p class="hero-lede">OpenCode alone against OpenCode with Kalari, on the frozen pair. Both arms passed the hidden grader in every session. Kalari cost less and finished sooner, inside a boundary the agent cannot switch off.</p>
    <p class="hero-models">Both arms: ${modelTag("OpenCode 2.2.5")} with ${modelTag("DeepSeek V4.1 Flash")} on Vultr Serverless Inference. The only difference is Kalari.</p>
    <p class="evidence-row">Evidence on GitHub: ${evidenceLink(
      githubUrl("bench/RESULTS.md", "2-the-comparison-table"),
      "The comparison table",
    )} · ${evidenceLink(githubUrl("bench/RESULTS.md", "4-the-basis-of-cost-and-token-figures"), "Cost and token basis")} · ${evidenceLink(
      githubUrl("bench/RESULTS.md", "6-containment-configured-policy-versus-observed-outcome"),
      "Containment policy",
    )} · ${evidenceLink(githubUrl("bench/FROZEN.md"), "The frozen pair")}</p>
    <div class="hero-grid">
      ${row({
        heading: "Cost per session",
        kalValue: money(kal.costMean),
        refValue: money(ref.costMean),
        kalRun: kalCostRun,
        refRun: refCostRun,
        kalTitle: "Kalari mean cost",
        refTitle: "Reference mean cost",
        badgeText: ratioBadge(costRatio, "cheaper", "costlier"),
        badgeTitle: "Cost ratio",
        widths: costWidths,
        note: "",
        refWorse: ref.costMean >= kal.costMean,
      })}
      ${row({
        heading: "Wall time per session",
        kalValue: seconds(kal.wallMean),
        refValue: seconds(ref.wallMean),
        kalRun: kalWallRun,
        refRun: refWallRun,
        kalTitle: "Kalari mean wall time",
        refTitle: "Reference mean wall time",
        badgeText: ratioBadge(wallRatio, "faster", "slower"),
        badgeTitle: "Wall time ratio",
        widths: wallWidths,
        note: "",
        refWorse: ref.wallMean >= kal.wallMean,
      })}
      ${row({
        heading: "Time stuck in hung runs",
        kalValue: seconds(kal.stuckTotal),
        refValue: seconds(ref.stuckTotal),
        kalRun: kalStuckWorst,
        refRun: refStuckWorst,
        kalTitle: "Kalari total stuck",
        refTitle: "Reference total stuck",
        badgeText: stuckBadge(kal.stuckTotal, ref.stuckTotal),
        badgeTitle: "Stuck note",
        widths: stuckWidths,
        note: stuckNote,
        refWorse: ref.stuckTotal >= kal.stuckTotal,
      })}
      <div class="hero-row">
        <h3>What the sandbox could reach</h3>
        <div class="hero-pair hero-pair--text">
          <div class="hero-arm hero-arm--kalari">
            <span class="hero-arm-name">Kalari</span>
            <p class="hero-boundary">One fresh guest per run. No network except one allow rule. Caps on time, memory and output.</p>
          </div>
          <div class="hero-arm hero-arm--reference is-worse">
            <span class="hero-arm-name">Reference</span>
            <p class="hero-boundary hero-boundary--open">The agent chose its own sandbox. The default network reached the internet and the virtual machine's own SSH.</p>
          </div>
        </div>
        <p class="hero-note">The agent cannot switch the Kalari boundary off.</p>
      </div>
    </div>
    ${verdicts}
    ${capKill}
  </section>`;
}

/* ------------------------------------------------------------------ */
/* The problem: the reference run that motivates Kalari                 */
/* ------------------------------------------------------------------ */

function referenceRecords(records) {
  return ofKind(records, "reference").filter(
    (record) => object(record?.payload)?.schema === "kalari.reference.v1" && isId(record.run_id),
  );
}

function referenceOf(records) {
  return referenceRecords(records)[0];
}

function problemSection(records, runIds) {
  const record = referenceOf(records);
  if (!record) return "";
  const p = payloadOf(record);
  const before = object(p.before) || {};
  const after = object(p.after) || {};
  const runId = record.run_id;
  return `<section id="problem" class="section section--problem" aria-labelledby="problem-title">
    <p class="hero-kicker">The problem</p>
    <h2 id="problem-title">The export looked fine and lost ${runLink(
      runId,
      h(count(before.missing)),
      runIds,
      "Reference loss: missing records",
    )} records.</h2>
    <p class="hero-lede">The v1 consumer exits clean and prints a neat total. The hidden grader counts what arrived. This silent loss is why Kalari rehearses each upgrade in a contained arena.</p>
    <p class="hero-models">The reference setup ran ${modelTag("OpenCode 2.2.5")} with ${modelTag("DeepSeek V4.1 Flash")} on Vultr Serverless Inference.</p>
    <p class="evidence-row">Evidence on GitHub: ${evidenceLink(
      githubUrl("bench/reference-paging/README.md"),
      "The reference notes",
    )}</p>
    <div class="problem-grid">
      <div class="problem-card problem-card--loss">
        <h3>The silent loss</h3>
        <p><code>${h(p.consumer || "import_items.py")}</code> exits ${measure(
          runId,
          before.exit_code,
          count,
          "Reference loss: exit code",
          runIds,
        )}. It prints "imported ${measure(
          runId,
          before.records,
          count,
          "Reference loss: printed records",
          runIds,
        )} items". The hidden grader finds ${measure(
          runId,
          before.records,
          count,
          "Reference loss: graded records",
          runIds,
        )} of ${measure(runId, before.expected, count, "Reference loss: expected records", runIds)} records. ${measure(
          runId,
          before.missing,
          count,
          "Reference loss: missing records",
          runIds,
        )} records never arrive. The grade is <span class="verdict is-fail">${h(verdictWord(before.verdict))}</span>.</p>
      </div>
      <div class="problem-card problem-card--fix">
        <h3>The fix</h3>
        <p>${runLink(
          runId,
          h(after.setup || "OpenCode with microsandbox-mcp and DeepSeek V4.1 Flash"),
          runIds,
          "Reference fix: setup",
        )} rewrites the consumer. It passes on the first attempt: ${measure(
          runId,
          after.records,
          count,
          "Reference fix: records",
          runIds,
        )} of ${measure(runId, after.expected, count, "Reference fix: expected records", runIds)} records. The grade is <span class="verdict is-pass">${h(
          verdictWord(after.verdict),
        )}</span>.</p>
        <dl class="problem-facts">
          <div><dt>Wall time</dt><dd>${measure(runId, after.wall_time_s, seconds, "Reference fix: wall time", runIds)}</dd></div>
          <div><dt>Input tokens</dt><dd>${measure(runId, after.tokens_input, tokens, "Reference fix: input tokens", runIds)}</dd></div>
          <div><dt>Output tokens</dt><dd>${measure(runId, after.tokens_output, tokens, "Reference fix: output tokens", runIds)}</dd></div>
          <div><dt>List-price cost</dt><dd>${measure(runId, after.cost_usd, dollars2, "Reference fix: cost", runIds)}</dd></div>
        </dl>
      </div>
    </div>
    <p class="fine-print">Figures from <code>${h(p.source || "bench/reference-paging/README.md")}</code>. This run is not a benchmark session. It never enters the tallies below.</p>
    <p class="quiet-line"><a href="${attr(sessionHref(REFERENCE_SESSION))}">Open the session</a></p>
  </section>`;
}

function heroSection({ hasBenchmark, hasFrozen, hasFrozenRows, sections }) {
  const status = !hasBenchmark
    ? `<p class="status-line"><span class="status-dot" aria-hidden="true"></span>Waiting for published results</p>`
    : hasFrozen
      ? `<p class="status-line"><span class="status-dot is-live" aria-hidden="true"></span>Frozen comparison published</p>`
      : hasFrozenRows
        ? `<p class="status-line"><span class="status-dot is-pilot" aria-hidden="true"></span>Some frozen rows are published. The comparison needs condition five and condition three in one upgrade.</p>`
        : `<p class="status-line"><span class="status-dot is-pilot" aria-hidden="true"></span>Pilot results published. The frozen comparison is not yet published.</p>`;
  return `<header class="judges-hero">
    <h1>For judges: start here.</h1>
    <p class="deck">Kalari rehearses an API upgrade in a contained arena. A proved gate checks each sandbox call. A hidden grader decides whether the upgrade works. Kalari writes a lesson from what the verified run showed.</p>
    <p class="hero-copy">This page is the evidence index. Every figure comes from an evidence record, and every benchmark figure links to the run that produced it.</p>
    ${status}
    <nav class="reading-path" aria-label="On this page">
      <ul>${sections
        .map(
          (section) =>
            `<li><a href="#${attr(section.id)}">${h(section.label)}</a></li>`,
        )
        .join("")}</ul>
    </nav>
  </header>`;
}

function notRunSection(bench) {
  const present = new Set(bench.map((record) => Number(payloadOf(record).condition)));
  const missing = Object.keys(CONDITIONS)
    .map(Number)
    .filter((condition) => !present.has(condition))
    .sort((left, right) => left - right);
  if (!missing.length) return "";
  return `<div class="not-run">
    <h3>Conditions not run in this fixture</h3>
    <ul>${missing
      .map(
        (condition) =>
          `<li data-not-run="${condition}"><strong>${h(conditionLabel(condition))}</strong> (condition ${h(
            countWord(condition),
          )}). Not run. No record for this condition is in the store.</li>`,
      )
      .join("")}</ul>
  </div>`;
}

export function judgesView({
  benchmark = [],
  runs = null,
  sessions = [],
  lessons = [],
  runDetails = {},
  containment = null,
  reference = null,
  showcase = null,
  warnings = [],
} = {}) {
  const bench = benchmarkRecords(benchmark);
  const runIds = runIdSet(runs);
  const frozen = bench.filter(
    (record) =>
      payloadOf(record).provenance === "frozen" &&
      payloadOf(record).status !== "invalid" &&
      payloadOf(record).status !== "diagnostic",
  );
  const validPilot = bench.filter(
    (record) => payloadOf(record).provenance !== "frozen" && payloadOf(record).status === "valid",
  );
  const invalid = bench.filter((record) => payloadOf(record).status === "invalid");
  const diagnostic = bench.filter((record) => payloadOf(record).status === "diagnostic");
  const hasBenchmark = bench.length > 0;
  const frozenPairs = frozenPairUpgrades(frozen);
  const hasFrozen = frozenPairs.length > 0;
  const comparisonHeading = hasFrozen ? "The measured before and after" : "The pilot baseline";
  const hasChanged = heroNumbers(bench) !== null;
  const hasProblem = referenceOf(reference || []) !== undefined;

  const sections = [];
  sections.push({ id: "what-is", label: "What Kalari is" });
  if (hasChanged) {
    sections.push({ id: "changed", label: "What Kalari changed" });
  }
  if (hasProblem) {
    sections.push({ id: "problem", label: "The problem" });
  }
  if (containmentOf(containment)) {
    sections.push({ id: "containment", label: "The containment runs" });
  }
  if (showcaseRecords(showcase || []).length) {
    sections.push({ id: "models", label: "Across models" });
  }
  sections.push({ id: "comparison", label: comparisonHeading });
  if (hasBenchmark) {
    sections.push({ id: "baseline", label: "Every condition in this fixture" });
  }
  if (hasBenchmark) {
    sections.push({ id: "runs", label: "Every run" });
  }
  sections.push({ id: "sessions", label: "Read a session" });

  const validGroups = byCondition(validPilot);
  const invalidGroups = byCondition(invalid);
  const frozenGroups = byCondition(frozen);

  const baseline = `${conditionGroupsSection(validGroups, runIds, "valid")}
    ${frozenGroups.length ? `<h2>Frozen sessions</h2>${conditionGroupsSection(frozenGroups, runIds, "frozen")}` : ""}
    ${
      invalidGroups.length
        ? `<section class="subsection subsection--invalid">
            <h3>Invalid rows, kept for the record</h3>
            <p>These rows cannot count. The run pages carry the note for each row.</p>
            ${conditionGroupsSection(invalidGroups, runIds, "invalid")}
          </section>`
        : ""
    }
    ${diagnosticsSection(diagnostic, runIds)}
    ${notRunSection(bench)}`;

  return `<article class="judges">
    ${heroSection({ hasBenchmark, hasFrozen, hasFrozenRows: frozen.length > 0, sections })}
    ${warningsSection(warnings)}
    ${whatIsSection()}
    ${heroChangedSection(bench, runIds, containment)}
    ${problemSection(reference, runIds)}
    ${containmentSection(containment, runIds)}
    ${modelsSection(showcase || [], runIds)}
    <section id="comparison" class="section section--comparison">
      ${comparisonSection(bench, runIds, hasFrozen)}
    </section>
    ${
      hasBenchmark
        ? `<section id="baseline" class="section">
            <h2>Every condition in this fixture</h2>
            <p>Each row is one session in the store. The numbers are the committed measures. Right first time means the first run against the new endpoint passed. Sandbox runs count consumer runs, time stuck counts runs ended by a timeout, and lost or duplicated records come from the hidden grade. Invalid rows stay visible for an open record, and they enter no totals.</p>
            ${baseline}
          </section>`
        : ""
    }
    ${hasBenchmark ? `<section id="runs" class="section">${everyRunSection(bench, runs, runDetails, runIds)}</section>` : ""}
    <section id="sessions" class="section section--sessions">
      ${sessionLinksSection(sessions, showcase || [], runIds)}
    </section>
  </article>`;
}

/* ------------------------------------------------------------------ */
/* Session view                                                        */
/* ------------------------------------------------------------------ */

function sessionMeta(records) {
  return object(ofKind(records, "session")[0]?.payload);
}

function intersects(left, right) {
  const rightSet = new Set(right || []);
  return (left || []).some((value) => rightSet.has(value));
}

function sessionChangeKinds(records) {
  return unique((records || []).flatMap((record) => (Array.isArray(record.change_kinds) ? record.change_kinds : [])));
}

function checkResultsFor(record, checkRecords) {
  const payload = payloadOf(record);
  const fromPayload = Array.isArray(payload.check_results) ? payload.check_results : [];
  const fromRecords = (checkRecords || [])
    .filter((check) => check.run_id === record.run_id)
    .map((check) => payloadOf(check));
  return fromPayload.length ? fromPayload : fromRecords;
}

function runCheckState(record, checkRecords) {
  const results = checkResultsFor(record, checkRecords);
  if (!results.length) return "none";
  return results.every((result) => result.passed === true) ? "passed" : "failed";
}

function runAttemptSummary(records, checkRecords) {
  if (!records.length) return "No sandbox runs were recorded in this session.";
  const states = records.map((record) => runCheckState(record, checkRecords));
  const passed = states.filter((state) => state === "passed").length;
  const failed = states.filter((state) => state === "failed").length;
  const none = states.filter((state) => state === "none").length;
  if (records.length === 1) {
    if (passed) return "One attempt. It passed its checks.";
    if (failed) return "One attempt. It failed its checks.";
    return "One attempt. It had no checks.";
  }
  const clauses = [];
  if (passed) clauses.push(`${capitalise(countWord(passed))} passed.`);
  if (failed) clauses.push(`${capitalise(countWord(failed))} failed.`);
  if (none) clauses.push(`${capitalise(countWord(none))} had no checks.`);
  return `${capitalise(countWord(records.length))} attempts. ${clauses.join(" ")}`;
}

function changeBlock(changeRecord, radii) {
  const change = payloadOf(changeRecord);
  const matching = radii.filter((record) => payloadOf(record).change_id === change.id);
  const sites = matching.flatMap((record) => {
    const payload = payloadOf(record);
    return Array.isArray(payload.call_sites) ? payload.call_sites : [];
  });
  const notes = matching.map((record) => payloadOf(record).note).filter(Boolean);
  return `<li class="change">
    <div class="change-head">
      ${badge(changeKindLabel(change.kind), "kind")}
      ${change.severity ? `<span class="severity severity--${attr(change.severity)}">${h(change.severity)}</span>` : ""}
    </div>
    <h3>${h(redactUrls(change.title || changeKindLabel(change.kind)))}</h3>
    <p>${h(redactUrls(change.summary || ""))}</p>
    <p class="endpoint">${change.endpoint ? `<code>${h(redactUrls(change.endpoint))}</code>` : ""}</p>
    <p class="change-id"><span>Change id</span> <code>${h(change.id || changeRecord.run_id)}</code></p>
    <div class="call-sites">
      <h4>What it touches</h4>
      ${
        sites.length
          ? `<ul>${sites
              .map(
                (site) =>
                  `<li><code>${h(site.path || "")}</code><pre>${h(redactUrls(site.detail || ""))}</pre></li>`,
              )
              .join("")}</ul>`
          : `<p class="muted">No call sites were found for this change.</p>`
      }
      ${notes.map((note) => `<p class="fine-print">${h(redactUrls(note))}</p>`).join("")}
    </div>
  </li>`;
}

function checkList(record, checkRecords) {
  const payload = payloadOf(record);
  const fromPayload = Array.isArray(payload.check_results) ? payload.check_results : [];
  const fromRecords = checkRecords
    .filter((check) => check.run_id === record.run_id)
    .map((check) => payloadOf(check));
  const results = fromPayload.length ? fromPayload : fromRecords;
  if (!results.length) return `<p class="muted">No check results were recorded.</p>`;
  return `<ul class="check-list">${results
    .map(
      (result) => `<li class="check ${result.passed === true ? "is-pass" : "is-fail"}">
        <div class="check-head"><strong>${h(redactUrls(result.check_id || "check"))}</strong><span>${h(
          result.passed === true ? "passed" : "failed",
        )}</span></div>
        ${result.detail ? `<p>${h(redactUrls(result.detail))}</p>` : ""}
      </li>`,
    )
    .join("")}</ul>`;
}

function opinionBlock(decision) {
  const payload = payloadOf(decision);
  const answer = object(payload.answer) || {};
  const probabilities = object(answer.probabilities) || {};
  const entries = Object.entries(probabilities)
    .filter(([, value]) => Number.isFinite(value))
    .sort((left, right) => right[1] - left[1]);
  const chosen = answer.choice ? clefLabel(answer.choice) : "an answer";
  return `<section class="opinion" data-opinion="clef" data-opinion-label="${attr(CLEF_OPINION_LABEL)}">
    <div class="opinion-head">
      ${badge("Model's opinion", "opinion")}
      <h4>${h(redactUrls(payload.question || "A Clef question"))}</h4>
    </div>
    <p class="opinion-lede"><strong>This is a model's opinion, not a measurement and not a verdict.</strong> The hidden grader and the sandbox checks decide whether the upgrade works.</p>
    <p class="opinion-choice">The model leaned toward <strong>${h(chosen)}</strong>.</p>
    <ul class="probabilities">
      ${entries
        .map(
          ([label, value]) => `<li data-probability="${attr(label)}">
            <span class="prob-label">${h(clefLabel(label))}</span>
            <span class="prob-bar" aria-hidden="true"><span style="width: ${value * 100}%"></span></span>
            <span class="prob-value">${h(percent(value))}</span>
          </li>`,
        )
        .join("")}
    </ul>
    <p class="opinion-meta">Clef, a decision model. The percentages are the model's own scores. They are not counts, not a grade, and not evidence that the code works.</p>
  </section>`;
}

function runCard(record, index, checks, decisions, runIds) {
  const payload = payloadOf(record);
  const verdict = object(payload.verdict) || {};
  const state = runCheckState(record, checks);
  const results = checkResultsFor(record, checks);
  const passed = state === "passed";
  const stateText = state === "passed" ? "Checks passed" : state === "failed" ? "Checks failed" : "No checks";
  const stateTone = state === "passed" ? "pass" : state === "failed" ? "fail" : "neutral";
  const decision = decisions.find((item) => item.run_id === record.run_id);
  const logs = `<details class="logs"><summary>Standard output</summary><pre>${h(
    redactUrls(verdict.stdout || ""),
  )}</pre></details>
    <details class="logs"><summary>Standard error</summary><pre>${h(
      redactUrls(verdict.stderr || ""),
    )}</pre></details>`;
  return `<article class="run-card ${passed ? "is-pass" : state === "failed" ? "is-fail" : "is-none"}">
    <header class="run-head">
      <p class="run-eyebrow">Attempt ${countWord(index + 1)}</p>
      <div class="run-title"><h3>${h(
        verdict.verdict ? verdictWord(verdict.verdict) : "Sandbox run",
      )}</h3>${badge(stateText, stateTone)}${
        payload.illustrative ? badge("Illustrative", "draft") : ""
      }</div>
      <p class="run-id">${runLink(
        record.run_id,
        `<code>${h(record.run_id)}</code>`,
        runIds,
        `Open run ${record.run_id}`,
      )}</p>
    </header>
    <dl class="facts">
      <div><dt>Verdict</dt><dd>${h(verdictWord(verdict.verdict))}</dd></div>
      <div><dt>Exit code</dt><dd>${Number.isFinite(verdict.exit_code) ? h(String(verdict.exit_code)) : h("none")}</dd></div>
      <div><dt>Wall time</dt><dd>${h(milliseconds(verdict.wall_ms))}</dd></div>
      <div><dt>Checks</dt><dd>${h(
        results.length
          ? `${results.filter((result) => result.passed).length} of ${results.length} passed`
          : "not recorded",
      )}</dd></div>
    </dl>
    <div class="run-body">
      <h4>Checks</h4>
      ${checkList(record, checks)}
      <h4>Logs</h4>
      <div class="log-list">${logs}</div>
      ${decision ? `<h4>What Clef thought</h4>${opinionBlock(decision)}` : ""}
      <details class="more"><summary>Request</summary><div class="more-body">
        <p><strong>Workspace</strong> <code>${h(redactUrls(payload.request?.workspace || "not recorded"))}</code></p>
        <p><strong>Command</strong></p>
        <pre>${h(redactUrls((payload.request?.command || []).join(" ") || "not recorded"))}</pre>
        <p><strong>Caps</strong> time ${h(
          Number.isFinite(payload.request?.caps?.timeout_ms)
            ? milliseconds(payload.request.caps.timeout_ms)
            : "not recorded",
        )}, output ${h(
          Number.isFinite(payload.request?.caps?.output_cap_bytes)
            ? `${count(payload.request.caps.output_cap_bytes)} bytes`
            : "not recorded",
        )}, memory ${h(
          Number.isFinite(payload.request?.caps?.memory_mib)
            ? `${count(payload.request.caps.memory_mib)} MiB`
            : "not recorded",
        )}</p>
      </div></details>
    </div>
    <footer class="run-foot">
      ${
        isId(record.run_id) && (!runIds || runIds.has(record.run_id))
          ? `<a class="quiet-link" href="${attr(runHref(record.run_id))}" data-run-link="${attr(
              record.run_id,
            )}">Open this run</a>`
          : `<span class="measure-missing">evidence missing</span>`
      }
    </footer>
  </article>`;
}

function lessonList(records, { runIds, title, empty, observations, verified }) {
  if (!records.length) {
    return `<section class="subsection"><h2>${h(title)}</h2><p class="muted">${h(empty)}</p></section>`;
  }
  return `<section class="subsection">
    <h2>${h(title)}</h2>
    <ul class="lesson-list">
      ${records
        .map((record) => {
          const lesson = payloadOf(record);
          const check = object(lesson.check) || {};
          const observed = verified.find((item) => item.run_id === lesson.run_id);
          const pageObservation = observations.find((item) => item.run_id === lesson.run_id);
          const observedPayload = object(payloadOf(observed));
          const pagePayload = object(payloadOf(pageObservation));
          const behaviors = [
            ...(Array.isArray(observedPayload?.behaviors) ? observedPayload.behaviors : []),
            ...(Array.isArray(pagePayload?.behaviors) ? pagePayload.behaviors : []),
          ];
          const uniqueBehaviors = unique(behaviors);
          return `<li class="lesson">
            <h3>${h(changeKindLabel(lesson.change_kind))}</h3>
            <p>${h(redactUrls(lesson.observation || "No observation was recorded."))}</p>
            <div class="lesson-check">
              <p><strong>Check:</strong> ${h(redactUrls(check.assertion || "No check was recorded."))}</p>
              ${check.command ? `<pre>${h(redactUrls(check.command.join(" ")))}</pre>` : ""}
            </div>
            <p class="lesson-run">${
              lesson.run_id
                ? `Shown by ${runLink(
                    lesson.run_id,
                    `<code>${h(lesson.run_id)}</code>`,
                    runIds,
                    `Open run ${lesson.run_id}`,
                  )}`
                : ""
            }</p>
            ${
              observedPayload?.failed_run_id
                ? `<p class="lesson-run">Followed the failed run ${runLink(
                    observedPayload.failed_run_id,
                    `<code>${h(observedPayload.failed_run_id)}</code>`,
                    runIds,
                    `Open run ${observedPayload.failed_run_id}`,
                  )}</p>`
                : ""
            }
            ${
              lesson.memory_concept_id
                ? `<p class="lesson-memory"><span>Stored in memory as</span> <code>${h(
                    lesson.memory_concept_id,
                  )}</code></p>`
                : ""
            }
            ${
              uniqueBehaviors.length
                ? `<div class="observed"><h4>What the passing run observed</h4><ul>${uniqueBehaviors
                    .map((behavior) => `<li>${h(observationLabel(behavior))}</li>`)
                    .join("")}</ul></div>`
                : ""
            }
          </li>`;
        })
        .join("")}
    </ul>
  </section>`;
}

function sessionModelLine(bench) {
  const models = unique(
    bench.map((record) => payloadOf(record).model).filter((value) => typeof value === "string" && value),
  );
  if (models.length !== 1) return "";
  return `<p class="session-model">Model: ${modelTag(models[0])}</p>`;
}

function showcaseSection(records, runIds) {
  const list = showcaseRecords(records);
  if (!list.length) return "";
  return `<section class="subsection">
    <h2>Showcase runs</h2>
    <p>One manufactured upgrade across five models. Each run links its run page. Counts come from the hidden grader. Not part of the frozen comparison.</p>
    <ul class="showcase-list">
      ${list
        .map((record) => {
          const p = payloadOf(record);
          const sequence = Array.isArray(p.differential) ? p.differential : [];
          return `<li class="showcase-item">
          <h3>${h(p.label || record.run_id)}</h3>
          <p>${modelTag(p.model || "unknown")} · <span class="verdict ${
            p.verdict === "PASS" ? "is-pass" : "is-fail"
          }">${h(verdictWord(p.verdict))}</span> · ${h(p.arm === "kalari" ? "Kalari arm" : "reference arm")}</p>
          <p>Lost ${plain(p.records_lost, count)}, duplicated ${plain(
            p.records_duplicated,
            count,
          )}, changed ${plain(p.records_changed, count)}. Wall time ${plain(p.wall_time_s, seconds)}, cost ${plain(
            p.cost_usd,
            money,
          )}.</p>
          ${
            p.arm === "kalari"
              ? `<p>Differential: ${h(sequence.length ? sequence.join(" → ") : "not recorded")}. Fixed: ${h(
                  p.fixed === true ? "Yes" : p.fixed === false ? "No" : "not recorded",
                )}.</p>`
              : ""
          }
          <p>${runLink(
            record.run_id,
            `<code>${h(record.run_id)}</code>`,
            runIds,
            `Open run ${record.run_id}`,
          )}</p>
        </li>`;
        })
        .join("")}
    </ul>
  </section>`;
}

function benchmarkTable(records, runIds) {
  const allFrozen = records.every((record) => payloadOf(record).provenance === "frozen");
  const anyFrozen = records.some((record) => payloadOf(record).provenance === "frozen");
  const provenance = allFrozen ? "frozen" : anyFrozen ? "mixed" : "pilot";
  const lead =
    provenance === "mixed"
      ? "This benchmark session holds records from more than one provenance."
      : `This is a ${provenance} benchmark session. The measures are from the committed ${provenance} results.`;
  return `<div class="panel panel--pilot">
    <h2>Benchmark measures</h2>
    <p>${lead} ${
      records.some((record) => payloadOf(record).status === "invalid")
        ? "The condition-one rows are invalid for the comparison."
        : records.some((record) => payloadOf(record).status === "diagnostic")
          ? "The isolated adapter makes these diagnostic rows not comparable with the condition rows."
          : ""
    }</p>
    ${measuresTable(records, runIds, `${capitalise(provenance)} benchmark sessions.`)}
    ${detailsTables(records, runIds)}
  </div>`;
}

function evidenceIndex(records, runIds) {
  const rows = records
    .map(
      (record) => `<tr>
        <td data-label="Kind"><code>${h(record.kind)}</code></td>
        <td data-label="Run">${runLink(
          record.run_id,
          `<code>${h(record.run_id)}</code>`,
          runIds,
          `Open run ${record.run_id}`,
        )}</td>
        <td data-label="Change kinds">${h((record.change_kinds || []).map(changeKindLabel).join(", ") || "none")}</td>
      </tr>`,
    )
    .join("");
  return `<section class="subsection">
    <h2>Every evidence record</h2>
    <p>This is the append-only trail the page read. The page shows the records by kind and run. The run page has the full payload.</p>
    <div class="table-wrap"><table class="measures-table">
      <caption class="visually-hidden">Every evidence record in this session.</caption>
      <thead><tr><th scope="col">Kind</th><th scope="col">Run</th><th scope="col">Change kinds</th></tr></thead>
      <tbody>${rows}</tbody>
    </table></div>
  </section>`;
}

export function sessionView({ sessionId = "", records = [], lessons = [], runs = null, warnings = [] } = {}) {
  const runIds = runIdSet(runs);
  const meta = sessionMeta(records);
  const bench = benchmarkRecords(records);
  const changes = ofKind(records, "change");
  const radii = ofKind(records, "blast-radius");
  const runRecords = ofKind(records, "run");
  const checks = ofKind(records, "check");
  const decisions = ofKind(records, "decision");
  const written = ofKind(records, "lesson");
  const observations = ofKind(records, "page-observation");
  const verified = ofKind(records, "verified-behavior");
  const changeKinds = sessionChangeKinds(records);
  const isPilotOnly = bench.length > 0 && changes.length === 0;
  const recalled = isPilotOnly
    ? []
    : (lessons || []).filter(
        (record) =>
          record.kind === "lesson" && record.session_id !== sessionId && intersects(record.change_kinds, changeKinds),
      );
  const title = meta?.title || "Session evidence";
  const frozenBench = bench.filter((record) => payloadOf(record).provenance === "frozen");
  const pilotBench = bench.filter((record) => payloadOf(record).provenance !== "frozen");
  const provenanceWord =
    bench.length && frozenBench.length === bench.length
      ? "frozen"
      : bench.length && pilotBench.length === bench.length
        ? "pilot"
        : "benchmark";
  const provenanceLabel = provenanceWord === "benchmark" ? "Mixed" : capitalise(provenanceWord);
  const sessionKindLabel = provenanceWord === "benchmark" ? "benchmark" : `${provenanceWord} benchmark`;
  const badges = [];
  if (meta?.illustrative) badges.push(badge("Illustrative walkthrough", "draft"));
  if (frozenBench.length === bench.length && bench.length) {
    badges.push(badge("Frozen benchmark session", "live"));
  } else if (pilotBench.length === bench.length && bench.length) {
    badges.push(badge("Pilot benchmark session", "pilot"));
  } else if (bench.length) {
    badges.push(badge("Mixed benchmark session", "pilot"));
  }
  if (bench.some((record) => payloadOf(record).status === "invalid")) {
    badges.push(badge(provenanceWord === "frozen" ? "Invalid frozen row" : "Invalid pilot row", "fail"));
  }
  if (bench.some((record) => payloadOf(record).status === "diagnostic")) badges.push(badge("Diagnostic session", "pilot"));
  const summary =
    meta?.summary ||
    (bench.length
      ? provenanceWord === "benchmark"
        ? "This session holds benchmark measures from more than one provenance."
        : `This session holds the ${provenanceWord} benchmark measures for one condition.`
      : "This session holds the evidence records the service wrote.");

  return `<article class="session-page">
    <header class="page-head">
      <p class="breadcrumb"><a href="index.html">For judges</a> <span aria-hidden="true">/</span> Session</p>
      <div class="page-title"><h1>${h(redactUrls(title))}</h1>${badges.join("")}</div>
      <p class="page-summary">${h(redactUrls(summary))}</p>
      <p class="session-id">Session <code>${h(sessionId)}</code></p>
      ${sessionModelLine(bench)}
      ${meta?.notes ? `<p class="caveat">${h(redactUrls(meta.notes))}</p>` : ""}
      <p class="quiet-line"><a href="index.html">Back to the evidence index</a></p>
    </header>

    ${warningsSection(warnings)}
    ${bench.length ? benchmarkTable(bench, runIds) : ""}
    ${showcaseSection(records, runIds)}

    ${
      changes.length
        ? `<section class="subsection">
            <h2>What changed</h2>
            <p>Vimanam reports the change facts. The blast radius shows what each change touches in the consumer.</p>
            <ul class="change-list">${changes
              .map((record) => changeBlock(record, radii))
              .join("")}</ul>
          </section>`
        : bench.length
          ? `<section class="subsection"><h2>What changed</h2><p class="muted">${provenanceLabel} benchmark sessions record benchmark measures only. The walkthrough session shows the change list, the blast radius and the lesson written.</p><p><a href="${attr(
              sessionHref("payouts-upgrade"),
            )}">Open the walkthrough</a></p></section>`
          : `<section class="subsection"><h2>What changed</h2><p class="muted">This session did not record its change list.</p></section>`
    }

    ${
      isPilotOnly
        ? `<section class="subsection"><h2>Recalled checks</h2><p class="muted">This ${sessionKindLabel} session records benchmark measures only. It does not record recalled checks.</p></section>`
        : recalled.length
        ? `<section class="subsection">
            <h2>Recalled checks</h2>
            <p>These lessons came from earlier sessions. Kalari returns a lesson as a check that must pass. It never decides the verdict.</p>
            <ul class="lesson-list">${recalled
              .map((record) => {
                const lesson = payloadOf(record);
                const check = object(lesson.check) || {};
                return `<li class="lesson">
                  <h3>${h(changeKindLabel(lesson.change_kind))}</h3>
                  <p>${h(redactUrls(lesson.observation || ""))}</p>
                  <div class="lesson-check"><p><strong>Check:</strong> ${h(
                    redactUrls(check.assertion || "No check was recorded."),
                  )}</p>${check.command ? `<pre>${h(redactUrls(check.command.join(" ")))}</pre>` : ""}</div>
                  <p class="lesson-run">Shown by ${runLink(
                    lesson.run_id,
                    `<code>${h(lesson.run_id)}</code>`,
                    runIds,
                    `Open run ${lesson.run_id}`,
                  )}</p>
                  ${
                    isId(record.session_id)
                      ? `<p class="fine-print">From <a href="${attr(
                          sessionHref(record.session_id),
                        )}">an earlier session</a>.</p>`
                      : ""
                  }
                </li>`;
              })
              .join("")}</ul>
          </section>`
        : `<section class="subsection"><h2>Recalled checks</h2><p class="muted">No earlier lesson matched these change kinds.</p></section>`
    }

    ${
      runRecords.length
        ? `<section class="subsection">
            <h2>The runs</h2>
            <p class="run-summary">${h(runAttemptSummary(runRecords, checks))}</p>
            <div class="timeline">${runRecords
              .map(
                (record, index) =>
                  `${runCard(record, index, checks, decisions, runIds)}${
                    index < runRecords.length - 1 && runCheckState(record, checks) === "failed"
                      ? `<p class="retry">The checks failed. The agent changed the loop and ran again.</p>`
                      : ""
                  }`,
              )
              .join("")}</div>
          </section>`
        : `<section class="subsection"><h2>The runs</h2><p class="muted">${
            bench.length
              ? "This " + sessionKindLabel + " session records benchmark measures, not sandbox run records."
              : "No sandbox runs were recorded in this session."
          }</p></section>`
    }

    ${lessonList(written, {
      runIds,
      title: "The lesson written",
      empty: isPilotOnly
        ? "This " + sessionKindLabel + " session records benchmark measures only. It does not record a lesson."
        : "No new lesson was written in this session.",
      observations,
      verified,
    })}

    ${evidenceIndex(records, runIds)}
  </article>`;
}

/* ------------------------------------------------------------------ */
/* Run view                                                            */
/* ------------------------------------------------------------------ */

function fact(label, value) {
  return `<div><dt>${h(label)}</dt><dd>${value}</dd></div>`;
}

function benchmarkRunDetail(payload, sessionId) {
  const grade = object(payload.grade);
  const firstGrade = object(payload.first_v2_grade);
  const provenance = payload.provenance === "frozen" ? "frozen" : "pilot";
  const provenanceTitle = provenance === "frozen" ? "Frozen comparison" : "Pilot";
  const statusTone = payload.status === "invalid" ? "fail" : payload.status === "diagnostic" ? "pilot" : "live";
  const statusText =
    payload.status === "invalid"
      ? `Invalid ${provenance} row`
      : payload.status === "diagnostic"
        ? "Diagnostic session"
        : provenance === "frozen"
          ? "Frozen comparison run"
          : "Measured pilot run";
  const gradeRowsHtml = grade
    ? [
        ["Records", grade.records, count],
        ["Unique", grade.unique, count],
        ["Expected", grade.expected, count],
        ["Missing", grade.missing, count],
        ["Extra", grade.extra, count],
        ["Duplicates", grade.duplicates, count],
        ["Mismatched", grade.mismatched, count],
        ["Unreadable lines", grade.unreadable_lines, count],
      ]
        .map(([label, value, formatter]) => fact(label, plain(value, formatter)))
        .join("")
    : `<p class="muted">No grade record.</p>`;
  const firstRows = firstGrade
    ? [
        ["Records", firstGrade.records, count],
        ["Missing", firstGrade.missing, count],
        ["Extra", firstGrade.extra, count],
        ["Duplicates", firstGrade.duplicates, count],
        ["Mismatched", firstGrade.mismatched, count],
      ]
        .map(([label, value, formatter]) => fact(label, plain(value, formatter)))
        .join("")
    : "";
  const log = payload.grader_runs?.final?.log_excerpt;
  return `<section class="panel">
    <div class="panel-head">
      <div>
        <h2>${provenanceTitle} run: ${h(upgradeLabel(payload.upgrade))}</h2>
        <p class="run-id"><code>${h(sessionId || "")}</code></p>
      </div>
      <div class="badge-row">${badge(statusText, statusTone)} ${badge(
        conditionLabel(payload.condition),
        "neutral",
      )} ${badge(armLabel(payload.arm), "neutral")} ${badge(
        `Repeat ${countWord(payload.repeat)}`,
        "neutral",
      )}</div>
    </div>
    <p>${h(redactUrls(payload.notes || `A committed ${provenance} result.`))}</p>
    <dl class="facts facts--wide">
      ${fact("Verdict", h(verdictWord(payload.verdict)))}
      ${fact("Right first time", h(boolWord(payload.right_first_time)))}
      ${fact("Basis", h(payload.right_first_time_basis || "not recorded"))}
      ${payload.model ? fact("Model", modelTag(payload.model)) : ""}
      ${fact("Sandbox runs", plain(payload.sandbox_runs, count))}
      ${fact("Against the old endpoint", plain(payload.sandbox_runs_against_v1, count))}
      ${fact("Against the new endpoint", plain(payload.sandbox_runs_against_v2, count))}
      ${fact("Wall time", plain(payload.wall_time_s, seconds))}
      ${fact("Time stuck", plain(payload.time_stuck_s, seconds))}
      ${fact("Tokens in", plain(payload.tokens_input, tokens))}
      ${fact("Tokens out", plain(payload.tokens_output, tokens))}
      ${fact("Records lost", plain(payload.records_lost, count))}
      ${fact("Records duplicated", plain(payload.records_duplicated, count))}
      ${fact("Records extra", plain(payload.records_extra, count))}
      ${fact("Records mismatched", plain(payload.records_mismatched, count))}
      ${fact("List-price cost", plain(payload.cost_usd, money))}
      ${fact("Session cap", plain(payload.session_cap_s, seconds))}
      ${fact("Process elapsed", plain(payload.process_elapsed_s, seconds))}
      ${fact("OpenCode exit", plain(payload.opencode_exit, count))}
      ${fact("Session continued", h(boolWord(payload.session_continued)))}
      ${fact("Session capped", h(boolWord(payload.session_capped)))}
    </dl>
    <h3>The grade</h3>
    <dl class="facts">${gradeRowsHtml}</dl>
    ${grade?.note ? `<p class="fine-print">${h(redactUrls(grade.note))}</p>` : ""}
    ${log ? `<h3>The grader log</h3><pre class="log">${h(redactUrls(log))}</pre>` : ""}
    ${
      firstRows
        ? `<details class="more"><summary>First run against the new endpoint</summary><div class="more-body"><dl class="facts">${firstRows}</dl></div></details>`
        : ""
    }
    <p class="source-line">Source: <code>${h(redactUrls(payload.source || "not recorded"))}</code></p>
    ${benchmarkEvidenceLinks(payload)}
  </section>`;
}

function isRepoPath(value) {
  return typeof value === "string" && value && !value.includes("://") && !value.startsWith("/");
}

function benchmarkEvidenceLinks(payload) {
  if (!isRepoPath(payload.source)) return "";
  const links = [evidenceLink(githubUrl(payload.source), "The row file")];
  if (isRepoPath(payload.transcript)) {
    links.push(evidenceLink(githubUrl(payload.transcript), "The transcript"));
  }
  return `<p class="evidence-row">Evidence on GitHub: ${links.join(" · ")}</p>`;
}

function sandboxRunDetail(record, records, runIds) {
  const payload = payloadOf(record);
  const verdict = object(payload.verdict) || {};
  const checks = ofKind(records, "check");
  const state = runCheckState(record, checks);
  const results = checkResultsFor(record, checks);
  const stateText = state === "passed" ? "Checks passed" : state === "failed" ? "Checks failed" : "No checks";
  const stateTone = state === "passed" ? "pass" : state === "failed" ? "fail" : "neutral";
  const decision = ofKind(records, "decision").find((item) => item.run_id === record.run_id);
  const lesson = ofKind(records, "lesson").find((item) => item.run_id === record.run_id);
  const observation = ofKind(records, "page-observation").find((item) => item.run_id === record.run_id);
  return `<section class="panel">
    <div class="panel-head">
      <div><h2>Sandbox run</h2><p class="run-id"><code>${h(record.run_id)}</code></p></div>
      <div class="badge-row">${badge(
        verdictWord(verdict.verdict),
        verdict.verdict === "exited" ? "neutral" : "fail",
      )} ${badge(stateText, stateTone)}${
        payload.illustrative ? badge("Illustrative", "draft") : ""
      }</div>
    </div>
    ${
      payload.illustrative
        ? `<p class="caveat">Illustrative. This run shows the shape of the evidence. Its timing and log lines are not benchmark measurements.</p>`
        : ""
    }
    <dl class="facts facts--wide">
      ${fact("Verdict", h(verdictWord(verdict.verdict)))}
      ${fact("Exit code", Number.isFinite(verdict.exit_code) ? h(String(verdict.exit_code)) : h("none"))}
      ${fact("Wall time", plain(verdict.wall_ms, milliseconds))}
      ${fact("Stdout truncated", h(boolWord(verdict.stdout_truncated)))}
      ${fact("Pipe held open", h(boolWord(verdict.pipe_held_open)))}
      ${fact("Supervisor peak RSS", Number.isFinite(verdict.supervisor_peak_rss_kb) ? `${count(verdict.supervisor_peak_rss_kb)} kB` : h("unknown"))}
      ${fact("Cgroup memory limit", Number.isFinite(verdict.cgroup_memory_limit) ? `${count(verdict.cgroup_memory_limit)} bytes` : h("unknown"))}
    </dl>
    <h3>Request</h3>
    <p><strong>Workspace</strong> <code>${h(redactUrls(payload.request?.workspace || "not recorded"))}</code></p>
    <pre class="log">${h(redactUrls((payload.request?.command || []).join(" ") || "not recorded"))}</pre>
    <dl class="facts">
      ${fact("Timeout", plain(payload.request?.caps?.timeout_ms, milliseconds))}
      ${fact(
        "Output cap",
        Number.isFinite(payload.request?.caps?.output_cap_bytes)
          ? `${count(payload.request.caps.output_cap_bytes)} bytes`
          : h("unknown"),
      )}
      ${fact(
        "Memory cap",
        Number.isFinite(payload.request?.caps?.memory_mib)
          ? `${count(payload.request.caps.memory_mib)} MiB`
          : h("unknown"),
      )}
    </dl>
    <h3>Checks</h3>
    ${
      results.length
        ? `<ul class="check-list">${results
            .map(
              (result) => `<li class="check ${result.passed ? "is-pass" : "is-fail"}">
                <div class="check-head"><strong>${h(redactUrls(result.check_id || "check"))}</strong><span>${h(
                  result.passed ? "passed" : "failed",
                )}</span></div>
                ${result.detail ? `<p>${h(redactUrls(result.detail))}</p>` : ""}
              </li>`,
            )
            .join("")}</ul>`
        : `<p class="muted">No check results were recorded.</p>`
    }
    <h3>Logs</h3>
    <details class="logs" open><summary>Standard output</summary><pre>${h(
      redactUrls(verdict.stdout || ""),
    )}</pre></details>
    <details class="logs"><summary>Standard error</summary><pre>${h(
      redactUrls(verdict.stderr || ""),
    )}</pre></details>
    ${decision ? `<h3>What Clef thought</h3>${opinionBlock(decision)}` : ""}
    ${lesson ? `<h3>The lesson from this run</h3><p>${h(redactUrls(payloadOf(lesson).observation || ""))}</p>` : ""}
    ${
      observation
        ? `<h3>What the run observed</h3><ul>${(payloadOf(observation).behaviors || [])
            .map((behavior) => `<li>${h(observationLabel(behavior))}</li>`)
            .join("")}</ul>`
        : ""
    }
  </section>`;
}

function recordsTable(records) {
  const rows = records
    .map(
      (record) => `<tr><td><code>${h(record.kind)}</code></td><td><code>${h(record.run_id)}</code></td><td>${h(
        (record.change_kinds || []).map(changeKindLabel).join(", ") || "none",
      )}</td></tr>`,
    )
    .join("");
  return `<section class="subsection"><h2>Every record in this run</h2><div class="table-wrap"><table class="measures-table">
    <caption class="visually-hidden">Every evidence record in this run.</caption>
    <thead><tr><th scope="col">Kind</th><th scope="col">Run</th><th scope="col">Change kinds</th></tr></thead>
    <tbody>${rows}</tbody>
  </table></div></section>`;
}

function listOf(items, empty = "none") {
  const values = (items || []).filter((item) => item !== null && item !== undefined);
  return values.length
    ? `<ul class="plain-list">${values.map((item) => `<li>${item}</li>`).join("")}</ul>`
    : `<p class="muted">${h(empty)}</p>`;
}

/* The evidence behind the containment panel. Lists and definition lists only:
   the run page's only table is the record index. */
function containmentRunDetail(record) {
  const p = payloadOf(record);
  const config = object(p.config) || {};
  const result = object(p.result) || {};
  const outcomes = object(p.outcomes) || {};
  const creation = object(p.creation) || {};
  const network = object(p.network) || {};
  const requested = object(network.requested) || {};
  const effective = object(network.effective) || {};
  const observed = object(network.observed) || {};
  const cleanup = object(p.cleanup) || {};
  const differential = object(outcomes.differential) || {};
  const baseline = object(outcomes.baseline) || {};
  const attempts = Array.isArray(observed.attempts) ? observed.attempts : [];
  const rules = Array.isArray(effective.rules) ? effective.rules : [];
  const text = (value) => h(redactUrls(String(value ?? "not recorded")));
  const portsOf = (rule) =>
    (Array.isArray(rule.ports) ? rule.ports : [])
      .map((port) => (port.start === port.end ? String(port.start) : `${port.start}-${port.end}`))
      .join(", ");
  return `<section class="panel" id="containment-evidence" aria-labelledby="containment-evidence-title">
    <div class="panel-head">
      <div><h2 id="containment-evidence-title">Containment evidence</h2>
      <p class="quiet-line">A run constructed for this test, apart from the benchmark records. No benchmark row is involved.</p></div>
      <div class="badge-row">${badge("Not a benchmark run", "neutral")}${p.synthetic ? badge("Synthetic fixture", "draft") : ""}</div>
    </div>
    <p class="caveat">${text(p.case)}</p>
    <h3>The failure</h3>
    <dl class="facts facts--wide">
      ${fact("Configured time cap", plain(config.time_cap_ms, msText))}
      ${fact("Configured time ceiling", plain(config.time_ceiling_ms, msText))}
      ${fact("Measured wall time (supervisor clock)", plain(result.wall_ms, msText))}
      ${fact("Whole call on the host", plain(result.call_ms, msText))}
      ${fact("Verdict", text(result.verdict))}
      ${fact("Exit code", Number.isFinite(result.exit_code) ? h(String(result.exit_code)) : h("none"))}
      ${fact("Passed", h(boolWord(result.passed)))}
      ${fact("Stdout truncated", h(boolWord(result.stdout_truncated)))}
      ${fact("Pipe held open", h(boolWord(result.pipe_held_open)))}
      ${fact("Pages fetched before the end", plain(result.pages_fetched, count, "not applicable"))}
      ${fact("Waits for Retry-After", plain(result.waits_for_retry_after, count))}
    </dl>
    ${result.stderr_tail ? `<p class="muted">Last of its standard error:</p><pre class="log">${text(result.stderr_tail)}</pre>` : ""}
    <p class="muted">${text(result.enforcement_note)}</p>
    <ul class="plain-list">
      <li><strong>Candidate</strong>: ${text(object(outcomes.candidate)?.verdict)}, passed is ${h(
        boolWord(object(outcomes.candidate)?.passed).toLowerCase(),
      )}.</li>
      <li><strong>Baseline (v1)</strong>: ${baseline.executed ? "executed" : "not executed"}. ${text(baseline.note)}</li>
      <li><strong>Differential</strong> (<code>${text(differential.check_id)}</code>): passed is ${h(
        boolWord(differential.passed).toLowerCase(),
      )}. ${text(differential.detail)}</li>
    </ul>
    <h3>Caps recorded as configuration</h3>
    <dl class="facts">
      ${fact("Output cap", plain(config.output_cap_bytes, (value) => `${count(value)} bytes`))}
      ${fact("Memory", plain(config.memory_mib, (value) => `${count(value)} MiB`))}
    </dl>
    <p class="muted">${text(config.note)}</p>
    <h3>How the sandbox was created</h3>
    <pre class="log">${text(Array.isArray(creation.argv) ? creation.argv.join(" ") : "not recorded")}</pre>
    <dl class="facts">
      ${fact("Image", text(creation.image))}
      ${fact("CPUs", plain(creation.cpus, count))}
      ${fact("Memory", plain(creation.memory_mib, (value) => `${count(value)} MiB`))}
    </dl>
    <p class="muted">${text(creation.source)}</p>
    <h3>Network policy: requested, effective, observed</h3>
    <h4>Requested</h4>
    <p>${text(requested.mode)}</p>
    ${listOf((requested.rules || []).map((rule) => `<code>${text(rule)}</code>`), "no rules recorded")}
    <h4>Effective</h4>
    <p class="muted">${text(effective.source)}</p>
    <dl class="facts">
      ${fact("Network enabled", h(boolWord(effective.enabled)))}
      ${fact("Default egress", text(effective.default_egress))}
      ${fact("Default ingress", text(effective.default_ingress))}
    </dl>
    ${listOf(
      rules.map(
        (rule) =>
          `${text(rule.action)} ${text(rule.direction)} ${text((rule.protocols || []).join(","))} to <code>${text(
            object(rule.destination)?.cidr,
          )}</code> port ${h(portsOf(rule))}`,
      ),
      "no allow rules recorded",
    )}
    <h4>Observed</h4>
    <p class="muted">${text(observed.source)}</p>
    <dl class="facts">
      ${fact("Probe run", `<code>${text(observed.probe_run_id)}</code>`)}
      ${fact("Same guest as the consumer", h(boolWord(observed.same_guest)))}
      ${fact("Same creation arguments and allowlist", h(boolWord(observed.same_configuration)))}
      ${fact("Probe policy equals candidate policy", h(boolWord(observed.probe_policy_matches_candidate)))}
      ${fact("Requests outside the allowlist", plain(observed.denied_attempts, count))}
      ${fact("Of those, refused", plain(observed.denied_and_refused, count))}
      ${fact("Requests inside the allowlist answered", plain(observed.allowed_and_answered, count))}
      ${fact("Breaches", plain(observed.breaches, count))}
    </dl>
    ${listOf(
      attempts.map(
        (item) =>
          `<strong>${text(item.label)}</strong> (port ${h(String(item.port ?? "?"))}): expected ${text(item.expected)}, observed ${text(
            item.observed,
          )}, ${text(item.detail)}`,
      ),
      "no probe attempts recorded",
    )}
    <h3>Cleanup</h3>
    <dl class="facts">
      ${fact("Verified", h(boolWord(cleanup.ok)))}
      ${fact("Sandboxes this test created", plain((cleanup.sandboxes_created || []).length, count))}
      ${fact("Still listed afterwards", plain((cleanup.still_listed || []).length, count))}
      ${fact("Child processes remaining", plain((cleanup.child_processes_remaining || []).length, count))}
      ${fact("Sandboxes from before, unchanged", h(boolWord(cleanup.pre_existing_unchanged)))}
      ${fact("Service exited", h(boolWord(cleanup.service_exited)))}
    </dl>
    ${listOf((cleanup.sandboxes_created || []).map((name) => `<code>${text(name)}</code>`), "none created")}
    <p class="muted">Removed by <code>run_in_sandbox</code> itself: ${h(
      String((cleanup.removed_by_run_in_sandbox || []).length),
    )}. Needed forced cleanup by the test: ${h(String((cleanup.removed_by_forced_cleanup || []).length))}.</p>
    <h3>What this does not show</h3>
    ${listOf((p.limits || []).map((item) => text(item)))}
    ${
      object(p.versions)
        ? `<p class="muted">Tools: ${text(Object.values(p.versions).join(", "))}</p>`
        : ""
    }
    <p class="evidence-row">Evidence on GitHub: ${evidenceLink(
      githubUrl("tests/live/containment-transcript.txt"),
      "The containment log",
    )} · ${evidenceLink(
      githubUrl("tests/live/containment-evidence/run-1.jsonl"),
      "The first run record",
    )} · ${evidenceLink(
      githubUrl("tests/live/containment-evidence/run-2.jsonl"),
      "The second run record",
    )} · ${evidenceLink(
      githubUrl("bench/RESULTS.md", "6a-two-sandbox-runs-outside-the-comparison"),
      "The comparison notes",
    )}</p>
  </section>`;
}

/* The evidence behind The problem panel. Lists and definition lists only:
   the run page's only table is the record index. */
function referenceRunDetail(record) {
  const p = payloadOf(record);
  const before = object(p.before) || {};
  const after = object(p.after) || {};
  return `<section class="panel" id="reference-evidence" aria-labelledby="reference-evidence-title">
    <div class="panel-head">
      <div><h2 id="reference-evidence-title">Reference run: the paging fix</h2>
      <p class="quiet-line">Committed figures from ${h(p.source || "bench/reference-paging/README.md")}. Not a benchmark run.</p></div>
      <div class="badge-row">${badge("Not a benchmark run", "neutral")}</div>
    </div>
    <p class="caveat">${h(p.case || "The v1 consumer meets a paging API.")}</p>
    <h3>The silent loss</h3>
    <dl class="facts facts--wide">
      ${fact("Consumer", `<code>${h(p.consumer || "import_items.py")}</code>`)}
      ${fact("Exit code", plain(before.exit_code, count))}
      ${fact("Printed", before.stdout ? `<code>${h(before.stdout)}</code>` : h("not recorded"))}
      ${fact("Graded records", plain(before.records, count))}
      ${fact("Expected records", plain(before.expected, count))}
      ${fact("Missing records", plain(before.missing, count))}
      ${fact("Grade", h(verdictWord(before.verdict)))}
    </dl>
    <h3>The fix</h3>
    <p>${h(after.setup || "OpenCode with microsandbox-mcp and DeepSeek V4.1 Flash")} rewrote the consumer. It passed on the first attempt.</p>
    <dl class="facts facts--wide">
      ${fact("Grade", h(verdictWord(after.verdict)))}
      ${fact("Graded records", plain(after.records, count))}
      ${fact("Expected records", plain(after.expected, count))}
      ${fact("First attempt", h(after.attempt === 1 ? "Passed on attempt one" : "not recorded"))}
      ${fact("Wall time", plain(after.wall_time_s, seconds))}
      ${fact("Input tokens", plain(after.tokens_input, tokens))}
      ${fact("Output tokens", plain(after.tokens_output, tokens))}
      ${fact("List-price cost", plain(after.cost_usd, dollars2))}
    </dl>
    <h3>What this run is not</h3>
    <p class="muted">This run is not a benchmark session. It never enters the frozen tallies, the medians, or the hero sums. It shows the silent loss that motivates the comparison.</p>
    <p class="evidence-row">Evidence on GitHub: ${evidenceLink(
      githubUrl(typeof p.source === "string" && p.source ? p.source : "bench/reference-paging/README.md"),
      "The reference notes",
    )}</p>
  </section>`;
}

/* One showcase run: the model, the verdict, the grader counts and, for the
   Kalari arm, the differential sequence. Lists and definition lists only:
   the run page's only table is the record index. */
function showcaseRunDetail(record) {
  const p = payloadOf(record);
  const grade = object(p.grade);
  const sequence = Array.isArray(p.differential) ? p.differential : [];
  return `<section class="panel" id="showcase-evidence" aria-labelledby="showcase-evidence-title">
    <div class="panel-head">
      <div><h2 id="showcase-evidence-title">Showcase run: ${h(p.label || record.run_id)}</h2>
      <p class="quiet-line">A manufactured disbursement session. Not part of the frozen comparison.</p></div>
      <div class="badge-row">${badge("Showcase run", "pilot")}${badge(
        p.arm === "kalari" ? "Kalari arm" : "reference arm",
        "neutral",
      )}</div>
    </div>
    <dl class="facts facts--wide">
      ${fact("Model", modelTag(p.model || "unknown"))}
      ${fact("Verdict", h(verdictWord(p.verdict)))}
      ${fact("Graded records", plain(p.records, count))}
      ${fact("Records lost", plain(p.records_lost, count))}
      ${fact("Records duplicated", plain(p.records_duplicated, count))}
      ${fact("Records changed", plain(p.records_changed, count))}
      ${fact("Wall time", plain(p.wall_time_s, seconds))}
      ${fact("List-price cost", plain(p.cost_usd, money))}
      ${p.arm === "kalari" ? fact("Differential", h(sequence.length ? sequence.join(" → ") : "not recorded")) : ""}
      ${p.arm === "kalari" ? fact("Fixed", h(p.fixed === true ? "Yes" : p.fixed === false ? "No" : "not recorded")) : ""}
    </dl>
    <p class="source-line">Result: <code>${h(redactUrls(p.source || "not recorded"))}</code></p>
    <p class="source-line">Transcript: <code>${h(redactUrls(p.transcript || "not recorded"))}</code></p>
    <p class="evidence-row">Evidence on GitHub: ${evidenceLink(
      githubUrl("bench/showcase/disbursements/README.md"),
      "The showcase readme",
    )} · ${evidenceLink(githubUrl("bench/showcase/disbursements/QUIRKS.md"), "The quirks file")}${
      isRepoPath(p.source) ? ` · ${evidenceLink(githubUrl(p.source), "The row file")}` : ""
    }${
      isRepoPath(p.transcript)
        ? ` · ${evidenceLink(githubUrl(p.transcript), "The transcript")}`
        : ""
    }</p>
  </section>`;
}

export function runView({ runId = "", records = [], runs = null, warnings = [] } = {}) {
  const runIds = runIdSet(runs);
  const bench = benchmarkRecords(records);
  const runRecords = ofKind(records, "run");
  const shown = containmentOf(records);
  const reference = referenceOf(records);
  const showcase = showcaseRecords(records);
  const sessionId = records[0]?.session_id || "";
  const firstPayload = bench.length ? payloadOf(bench[0]) : {};
  const provenance = firstPayload.provenance === "frozen" ? "frozen" : "pilot";
  const provenanceTitle = provenance === "frozen" ? "Frozen comparison" : "Pilot";
  const title = bench.length
    ? `${provenanceTitle} run: ${upgradeLabel(firstPayload.upgrade)}`
    : shown
      ? payloadOf(shown).result?.verdict === "killed_timeout"
        ? "Containment · time cap enforced"
        : "Containment · consumer failure"
      : reference
        ? "Reference evidence"
        : showcase.length
          ? `Showcase run: ${payloadOf(showcase[0]).label || runId}`
          : runRecords.length
            ? "Sandbox run"
            : "Run evidence";
  const benchStatus = bench.length ? firstPayload.status : "";
  const benchBadge =
    benchStatus === "invalid"
      ? badge(`Invalid ${provenance} row`, "fail")
      : benchStatus === "diagnostic"
        ? badge("Diagnostic session", "pilot")
        : badge(provenance === "frozen" ? "Frozen comparison run" : "Measured pilot run", "live");
  const illustrativeBadge = runRecords.some((record) => payloadOf(record).illustrative === true)
    ? badge("Illustrative", "draft")
    : "";
  return `<article class="run-page">
    <header class="page-head">
      <p class="breadcrumb"><a href="index.html">For judges</a> <span aria-hidden="true">/</span> Run</p>
      <div class="page-title"><h1>${h(title)}</h1>${bench.length ? benchBadge : ""}${illustrativeBadge}</div>
      <p class="run-id"><code>${h(runId)}</code></p>
      ${
        sessionId
          ? isId(sessionId)
            ? `<p class="quiet-line">From <a href="${attr(sessionHref(sessionId))}">${h(sessionId)}</a></p>`
            : `<p class="quiet-line">Session <code>${h(sessionId)}</code></p>`
          : ""
      }
      <p class="quiet-line"><a href="index.html">Back to the evidence index</a></p>
    </header>
    ${warningsSection(warnings)}
    ${bench.map((record) => benchmarkRunDetail(payloadOf(record), sessionId)).join("")}
    ${shown ? containmentRunDetail(shown) : ""}
    ${reference ? referenceRunDetail(reference) : ""}
    ${showcase.map((record) => showcaseRunDetail(record)).join("")}
    ${runRecords.map((record) => sandboxRunDetail(record, records, runIds)).join("")}
    ${!bench.length && !runRecords.length && !reference && !showcase.length ? `<div class="notice notice--quiet"><h2>No readable run record</h2><p>The store returned records for this run, but none is a run or benchmark record.</p></div>` : ""}
    ${recordsTable(records)}
  </article>`;
}

export function errorView({ title = "Something went wrong", message = "", detail = "", backHref = "index.html", backLabel = "For judges" } = {}) {
  return `<article class="error-page">
    <p class="breadcrumb"><a href="${attr(backHref)}">${h(backLabel)}</a></p>
    <h1>${h(title)}</h1>
    <p>${h(message)}</p>
    ${detail ? `<p class="caveat">${h(detail)}</p>` : ""}
    <p><a class="button" href="${attr(backHref)}">${h(backLabel)}</a></p>
  </article>`;
}
