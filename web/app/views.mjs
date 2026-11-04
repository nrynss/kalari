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

function warningsSection(warnings) {
  if (!Array.isArray(warnings) || !warnings.length) return "";
  return `<div class="notice notice--warning" role="alert">
    <h2>Some evidence could not be loaded</h2>
    <ul>${warnings.map((warning) => `<li>${h(warning)}</li>`).join("")}</ul>
    <p>The page shows the records it could read. A figure that cannot link to its run is not shown.</p>
  </div>`;
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
      <h5>Tokens and time</h5>
      <div class="table-wrap"><table class="measures-table">
        <thead><tr><th scope="col">Run</th><th scope="col" class="num">Tokens in</th><th scope="col" class="num">Tokens out</th><th scope="col" class="num">Time stuck</th><th scope="col" class="num">Cost</th><th scope="col" class="num">Session cap</th></tr></thead>
        <tbody>${tokenRows(records, runIds)}</tbody>
      </table></div>
      ${
        graded.length
          ? `<h5>The hidden grader</h5>
      <div class="table-wrap"><table class="measures-table">
        <thead><tr><th scope="col">Run</th><th scope="col">Grade</th><th scope="col" class="num">Records</th><th scope="col" class="num">Missing</th><th scope="col" class="num">Extra</th><th scope="col" class="num">Duplicates</th><th scope="col" class="num">Mismatched</th></tr></thead>
        <tbody>${gradeRows(records, runIds)}</tbody>
      </table></div>`
          : ""
      }
      ${graded
        .map((record) => {
          const note = payloadOf(record).grade?.note;
          return note
            ? `<p class="fine-print">${runLink(
                record.run_id,
                `<code>${h(record.run_id)}</code>`,
                runIds,
                `Open run ${record.run_id}`,
              )} ${h(note)}</p>`
            : "";
        })
        .join("")}
    </div>
  </details>`;
}

function conditionSection(conditionGroup, runIds, tone = "valid") {
  const { condition, upgrades } = conditionGroup;
  const badgeText =
    tone === "invalid"
      ? "Invalid pilot row"
      : tone === "diagnostic"
        ? "Diagnostic session"
        : tone === "frozen"
          ? "Frozen comparison"
          : "Pilot, reference arm";
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
                ? "The REST ledger. The old endpoint returns every payout in one response. The new one is a windowed export."
                : "The GraphQL batches. The old schema returns a plain list. The new one is a Relay-style connection.",
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

function contrastColumn({ title, records, runIds, note }) {
  return `<div class="contrast-column">
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
  return `<div class="contrast">
    <h3>The measured baseline: the notes handoff on settlements</h3>
    <p class="caveat">Both columns are the reference setup. Five repeats each. This is the baseline's notes handoff, not Kalari's comparison.</p>
    <div class="contrast-grid">
      ${contrastColumn({
        title: "Fresh session, no notes",
        records: fresh,
        runIds,
        note: "A new session for upgrade two, with no earlier context.",
      })}
      ${contrastColumn({
        title: "New session with notes",
        records: notes,
        runIds,
        note: "The agent reads the notes it wrote after upgrade one.",
      })}
    </div>
    <p class="caveat caveat--last">${h(payoutsLine)}</p>
  </div>`;
}

function frozenContrast(frozen, runIds) {
  const after = frozen.filter((record) => payloadOf(record).condition === 5);
  const before = frozen.filter((record) => payloadOf(record).condition === 3);
  if (!after.length || !before.length) {
    return `<div class="notice notice--quiet"><p>The frozen comparison needs condition five and condition three. One of them is not in the store yet.</p></div>`;
  }
  return `<div class="contrast">
    <h3>The frozen comparison</h3>
    <p class="caveat">Five repeats per condition. Counts, never percentages. The tables below show every session, and every figure links to its run.</p>
    <div class="contrast-grid">
      ${contrastColumn({
        title: "Reference, fresh session",
        records: before,
        runIds,
        note: "The reference setup, with no notes.",
      })}
      ${contrastColumn({
        title: "Kalari, with the lesson",
        records: after,
        runIds,
        note: "OpenCode with Kalari, and the lesson from upgrade one.",
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
    <p class="caveat caveat--last">The verifier-prompt rows below are the control. If they match Kalari, say so plainly.</p>
  </div>`;
}

function notPublishedPanel() {
  return `<div class="notice notice--pending" role="status">
    <h3>The frozen comparison is not yet published.</h3>
    <p>The pilot below is the reference arm. The Kalari arm has not run on the frozen pair.</p>
    <p>When it does, this panel will show Kalari with the lesson against the fresh session, the notes handoff and the verifier prompt. It will report verdicts, right first time, sandbox attempts, wall time, time stuck, tokens, and records lost or duplicated. Every figure will link to its run.</p>
    <p><a href="#baseline">The baseline pilot is published below.</a></p>
  </div>`;
}

function comparisonSection(bench, runIds) {
  if (!bench.length) {
    return `<h2>Benchmark results are not yet published.</h2>
      <p>The page is waiting for benchmark records in the evidence store. A producer will write one record per run. No producer exists yet.</p>
      <p>When it does, this page will show the frozen before-and-after, each condition's result, and the containment moment. Every figure will link to the run that produced it.</p>
      <p>The session view is ready now. It shows the shape of the evidence the page will read.</p>`;
  }
  const frozen = bench.filter((record) => payloadOf(record).provenance === "frozen" && payloadOf(record).status !== "invalid");
  const validPilot = bench.filter(
    (record) => payloadOf(record).provenance !== "frozen" && payloadOf(record).status === "valid",
  );
  return `<h2>The measured before and after</h2>
    ${frozen.length ? "" : notPublishedPanel()}
    ${frozen.length ? frozenContrast(frozen, runIds) : ""}
    ${validPilot.length ? pilotContrast(validPilot, runIds) : ""}`;
}

function containmentSection(bench, runIds) {
  const capped = bench.find((record) => payloadOf(record).session_capped === true);
  if (!capped) {
    return `<section id="containment" class="section containment-wrap">
      <div class="notice notice--quiet"><h2>The containment moment</h2><p>No capped session is published yet.</p></div>
    </section>`;
  }
  const payload = payloadOf(capped);
  const records = object(payload.grade)?.records;
  const cap = Number(payload.session_cap_s);
  const capText = cap === 1200 ? "twenty-minute" : cap === 600 ? "ten-minute" : "";
  const capPhrase = capText ? `the ${capText} session cap` : "the session cap";
  const hasRun = runIds && runIds.has(capped.run_id);
  return `<section id="containment" class="containment" aria-labelledby="containment-title">
    <div class="containment-inner">
      <h2 id="containment-title">The cap fired. The evidence survived.</h2>
      <p class="containment-context">The containment moment</p>
      <p class="containment-lede">A reference session ran to ${capPhrase}. The harness stopped it. The hidden grader still ran, and the consumer still passed.</p>
      <div class="containment-measures">
        <div class="containment-measure">
          <span class="containment-measure-label">Wall time before the stop</span>
          <span class="containment-measure-value">${
            hasRun ? measure(capped.run_id, payload.wall_time_s, seconds, "Wall time", runIds) : h("evidence missing")
          }</span>
        </div>
        <div class="containment-measure">
          <span class="containment-measure-label">Records graded after it</span>
          <span class="containment-measure-value">${
            hasRun ? measure(capped.run_id, records, count, "Graded records", runIds) : h("evidence missing")
          }</span>
        </div>
        <div class="containment-measure">
          <span class="containment-measure-label">The verdict</span>
          <span class="containment-measure-value">${h(verdictWord(payload.verdict))}</span>
        </div>
      </div>
      <p class="containment-note">This is the harness session cap, not a staged failure. The aashaan also enforces a time cap on every sandbox run.</p>
      <div class="containment-links">
        ${
          hasRun
            ? `<a class="button button--light" href="${attr(runHref(capped.run_id))}">Read the capped run</a>`
            : ""
        }
        <a class="quiet-link quiet-link--light" href="${attr(sessionHref(capped.session_id))}">Open its session</a>
      </div>
    </div>
  </section>`;
}

function diagnosticsSection(diagnostic, runIds) {
  if (!diagnostic.length) return "";
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
    <p>Five sessions for each behaviour, on the isolated pilot adapter. It restricted the tool surface and network more than the condition rows. These sessions diagnose one behaviour alone and are not compared with the condition rows.</p>
    <div class="table-wrap"><table class="measures-table diagnostics-table">
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

function everyRunSection(bench, runIds) {
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
    <p>Every benchmark record in the store is listed here. The tables above link the same runs with their measures.</p>
    <div class="run-groups">${groups
      .map(
        (group) => `<div class="run-group">
          <h3>${h(group.title)}</h3>
          ${everyRunGroup(group.records, runIds)}
        </div>`,
      )
      .join("")}</div>`;
}

function sessionLinksSection(sessions, runIds) {
  const ids = Array.isArray(sessions) ? sessions : [];
  const hasWalkthrough = ids.includes("payouts-upgrade");
  const hasEarlier = ids.includes("payouts-earlier");
  const walkthroughRuns = ["payouts-attempt-1", "payouts-attempt-2", "payouts-attempt-3"];
  const walkthroughLinks = hasWalkthrough
    ? walkthroughRuns
        .map((runId) =>
          runLink(runId, `<code>${h(runId)}</code>`, runIds, `Open illustrative run ${runId}`),
        )
        .join(" ")
    : "";
  return `<h2>Read a full session</h2>
    <p>The run pages show one measurement each. A session page shows the whole trail. It has the change list, the blast radius, the recalled check, each attempt with its logs, and the lesson written.</p>
    ${
      hasWalkthrough
        ? `<a class="session-card" href="${attr(sessionHref("payouts-upgrade"))}">
      <span class="badge badge--draft">Illustrative walkthrough</span>
      <h3>Upgrading the payout ledger</h3>
      <p>Follow the change facts, the call site, the recalled check, three attempts and the lesson. The change facts and the Clef answer are recorded. The run timings and log excerpts are illustrative.</p>
      <span class="session-card-cta">Open the walkthrough</span>
    </a>
    <p class="quiet-line">Illustrative runs: ${walkthroughLinks}</p>`
        : `<p class="muted">The walkthrough session is not in the current evidence store.</p>`
    }
    ${
      hasEarlier
        ? `<p class="quiet-line"><a href="${attr(
            sessionHref("payouts-earlier"),
          )}">The earlier session that left the recalled lesson</a> ${runLink(
            "payouts-earlier-pass",
            `<code>payouts-earlier-pass</code>`,
            runIds,
            "Open the earlier illustrative run",
          )}</p>`
        : ""
    }`;
}

function heroSection({ hasBenchmark, hasFrozen, sections }) {
  const status = !hasBenchmark
    ? `<p class="status-line"><span class="status-dot" aria-hidden="true"></span>Waiting for published results</p>`
    : hasFrozen
      ? `<p class="status-line"><span class="status-dot is-live" aria-hidden="true"></span>Frozen comparison published</p>`
      : `<p class="status-line"><span class="status-dot is-pilot" aria-hidden="true"></span>Pilot results published. The frozen comparison is pending.</p>`;
  return `<header class="judges-hero">
    <h1>For judges: start here.</h1>
    <p class="deck">Kalari rehearses an API upgrade in a contained arena. A proved gate checks each sandbox call. A hidden grader decides whether the upgrade works. A lesson is written from what the verified run showed.</p>
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

function footerSection() {
  return `<footer class="judges-footer">
    <p><strong>Chaaya</strong> is the Kalari front end. The evidence store is append-only. It keeps the run, the checks, the Clef answers and the lessons.</p>
    <p class="fine-print">Clef answers are a model's opinion, never a measurement and never a verdict. The hidden grader and the sandbox checks decide the result.</p>
  </footer>`;
}

export function judgesView({ benchmark = [], runs = null, sessions = [], lessons = [], warnings = [] } = {}) {
  const bench = benchmarkRecords(benchmark);
  const runIds = runIdSet(runs);
  const frozen = bench.filter(
    (record) => payloadOf(record).provenance === "frozen" && payloadOf(record).status !== "invalid",
  );
  const validPilot = bench.filter(
    (record) => payloadOf(record).provenance !== "frozen" && payloadOf(record).status === "valid",
  );
  const invalid = bench.filter((record) => payloadOf(record).status === "invalid");
  const diagnostic = bench.filter((record) => payloadOf(record).status === "diagnostic");
  const hasBenchmark = bench.length > 0;
  const hasFrozen = frozen.length > 0;

  const sections = [{ id: "comparison", label: "The measured before and after" }];
  if (hasBenchmark) {
    sections.push({ id: "baseline", label: "Every condition, run by run" });
    sections.push({ id: "containment", label: "The containment moment" });
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
            <h3>Invalid pilot rows, kept for the record</h3>
            <p>${h(payloadOf(invalid[0]).notes || "These rows cannot count.")}</p>
            ${conditionGroupsSection(invalidGroups, runIds, "invalid")}
          </section>`
        : ""
    }
    ${diagnosticsSection(diagnostic, runIds)}`;

  return `<article class="judges">
    ${heroSection({ hasBenchmark, hasFrozen, sections })}
    ${warningsSection(warnings)}
    <section id="comparison" class="section section--comparison">
      ${comparisonSection(bench, runIds)}
    </section>
    ${
      hasBenchmark
        ? `<section id="baseline" class="section">
            <h2>Every condition, run by run</h2>
            <p>Each row is one pilot session. The numbers are the committed measures. The invalid rows stay for the record and cannot count.</p>
            ${baseline}
          </section>`
        : ""
    }
    ${hasBenchmark ? containmentSection(bench, runIds) : ""}
    ${hasBenchmark ? `<section id="runs" class="section">${everyRunSection(bench, runIds)}</section>` : ""}
    <section id="sessions" class="section section--sessions">
      ${sessionLinksSection(sessions, runIds)}
    </section>
    ${footerSection()}
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

function runPassed(record) {
  const payload = payloadOf(record);
  const verdict = object(payload.verdict) || {};
  const ok = verdict.verdict === "exited" && verdict.exit_code === 0;
  const results = Array.isArray(payload.check_results) ? payload.check_results : [];
  return ok && results.length > 0 && results.every((result) => result.passed === true);
}

function runAttemptSummary(records) {
  if (!records.length) return "No sandbox runs were recorded in this session.";
  const passed = records.filter(runPassed).length;
  const failed = records.length - passed;
  if (records.length === 1) {
    return passed ? "One attempt. It passed its checks." : "One attempt. It failed its checks.";
  }
  return `${capitalise(countWord(records.length))} attempts. ${capitalise(countWord(passed))} passed. ${capitalise(
    countWord(failed),
  )} failed.`;
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
    <h3>${h(change.title || changeKindLabel(change.kind))}</h3>
    <p>${h(change.summary || "")}</p>
    <p class="endpoint">${change.endpoint ? `<code>${h(change.endpoint)}</code>` : ""}</p>
    <p class="change-id"><span>Change id</span> <code>${h(change.id || changeRecord.run_id)}</code></p>
    <div class="call-sites">
      <h4>What it touches</h4>
      ${
        sites.length
          ? `<ul>${sites
              .map(
                (site) => `<li><code>${h(site.path || "")}</code><pre>${h(site.detail || "")}</pre></li>`,
              )
              .join("")}</ul>`
          : `<p class="muted">No call sites were found for this change.</p>`
      }
      ${notes.map((note) => `<p class="fine-print">${h(note)}</p>`).join("")}
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
        <div class="check-head"><strong>${h(result.check_id || "check")}</strong><span>${h(
          result.passed === true ? "passed" : "failed",
        )}</span></div>
        ${result.detail ? `<p>${h(result.detail)}</p>` : ""}
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
      <h4>${h(payload.question || "A Clef question")}</h4>
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

function runCard(record, index, total, checks, decisions, runIds) {
  const payload = payloadOf(record);
  const verdict = object(payload.verdict) || {};
  const passed = runPassed(record);
  const decision = decisions.find((item) => item.run_id === record.run_id);
  const logs = `<details class="logs"><summary>Standard output</summary><pre>${h(
    verdict.stdout || "",
  )}</pre></details>
    <details class="logs"><summary>Standard error</summary><pre>${h(verdict.stderr || "")}</pre></details>`;
  return `<article class="run-card ${passed ? "is-pass" : "is-fail"}">
    <header class="run-head">
      <p class="run-eyebrow">Attempt ${countWord(index + 1)}</p>
      <div class="run-title"><h3>${h(
        verdict.verdict ? verdictWord(verdict.verdict) : "Sandbox run",
      )}</h3>${badge(passed ? "Checks passed" : "Checks failed", passed ? "pass" : "fail")}${
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
        Array.isArray(payload.check_results)
          ? `${payload.check_results.filter((result) => result.passed).length} of ${payload.check_results.length} passed`
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
        <p><strong>Workspace</strong> <code>${h(payload.request?.workspace || "not recorded")}</code></p>
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
      <a class="quiet-link" href="${attr(runHref(record.run_id))}">Open this run</a>
      ${index < total - 1 ? "" : ""}
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
            <p>${h(lesson.observation || "No observation was recorded.")}</p>
            <div class="lesson-check">
              <p><strong>Check:</strong> ${h(check.assertion || "No check was recorded.")}</p>
              ${check.command ? `<pre>${h(check.command.join(" "))}</pre>` : ""}
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

function benchmarkTable(records, runIds) {
  return `<div class="panel panel--pilot">
    <h2>Benchmark measures</h2>
    <p>This is a pilot benchmark session. The measures are from the committed pilot results. ${
      records.some((record) => payloadOf(record).status === "invalid")
        ? "The condition-one rows are invalid for the comparison."
        : records.some((record) => payloadOf(record).status === "diagnostic")
          ? "The isolated adapter makes these diagnostic rows not comparable with the condition rows."
          : ""
    }</p>
    ${measuresTable(records, runIds, "Pilot benchmark sessions.")}
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
    <p>This is the append-only trail the page read. The records are shown by kind and run; the run page has the full payload.</p>
    <div class="table-wrap"><table class="measures-table">
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
  const badges = [];
  if (meta?.illustrative) badges.push(badge("Illustrative walkthrough", "draft"));
  if (bench.length) badges.push(badge("Pilot benchmark session", "pilot"));
  if (bench.some((record) => payloadOf(record).status === "invalid")) badges.push(badge("Invalid pilot row", "fail"));
  if (bench.some((record) => payloadOf(record).status === "diagnostic")) badges.push(badge("Diagnostic session", "pilot"));
  const summary =
    meta?.summary ||
    (bench.length
      ? "This session holds the pilot benchmark measures for one condition."
      : "This session holds the evidence records the service wrote.");

  return `<article class="session-page">
    <header class="page-head">
      <p class="breadcrumb"><a href="index.html">For judges</a> <span aria-hidden="true">/</span> Session</p>
      <div class="page-title"><h1>${h(title)}</h1>${badges.join("")}</div>
      <p class="page-summary">${h(summary)}</p>
      <p class="session-id">Session <code>${h(sessionId)}</code></p>
      ${meta?.notes ? `<p class="caveat">${h(meta.notes)}</p>` : ""}
      <p class="quiet-line"><a href="index.html">Back to the evidence index</a></p>
    </header>

    ${warningsSection(warnings)}
    ${bench.length ? benchmarkTable(bench, runIds) : ""}

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
          ? `<section class="subsection"><h2>What changed</h2><p class="muted">Pilot sessions record benchmark measures only. The walkthrough session shows the change list, the blast radius and the lesson written.</p><p><a href="${attr(
              sessionHref("payouts-upgrade"),
            )}">Open the walkthrough</a></p></section>`
          : `<section class="subsection"><h2>What changed</h2><p class="muted">This session did not record its change list.</p></section>`
    }

    ${
      isPilotOnly
        ? `<section class="subsection"><h2>Recalled checks</h2><p class="muted">This pilot session records benchmark measures only. It does not record recalled checks.</p></section>`
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
                  <p>${h(lesson.observation || "")}</p>
                  <div class="lesson-check"><p><strong>Check:</strong> ${h(
                    check.assertion || "No check was recorded.",
                  )}</p>${check.command ? `<pre>${h(check.command.join(" "))}</pre>` : ""}</div>
                  <p class="lesson-run">Shown by ${runLink(
                    lesson.run_id,
                    `<code>${h(lesson.run_id)}</code>`,
                    runIds,
                    `Open run ${lesson.run_id}`,
                  )}</p>
                  <p class="fine-print">From <a href="${attr(
                    sessionHref(record.session_id),
                  )}">an earlier session</a>.</p>
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
            <p class="run-summary">${h(runAttemptSummary(runRecords))}</p>
            <div class="timeline">${runRecords
              .map(
                (record, index) =>
                  `${runCard(record, index, runRecords.length, checks, decisions, runIds)}${
                    index < runRecords.length - 1 && !runPassed(record)
                      ? `<p class="retry">The checks failed. The agent changed the loop and ran again.</p>`
                      : ""
                  }`,
              )
              .join("")}</div>
          </section>`
        : `<section class="subsection"><h2>The runs</h2><p class="muted">${
            bench.length
              ? "This pilot session records benchmark measures, not sandbox run records."
              : "No sandbox runs were recorded in this session."
          }</p></section>`
    }

    ${lessonList(written, {
      runIds,
      title: "The lesson written",
      empty: isPilotOnly
        ? "This pilot session records benchmark measures only. It does not record a lesson."
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
  const statusTone = payload.status === "invalid" ? "fail" : payload.status === "diagnostic" ? "pilot" : "live";
  const statusText =
    payload.status === "invalid"
      ? "Invalid pilot row"
      : payload.status === "diagnostic"
        ? "Diagnostic session"
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
        <h2>Pilot run: ${h(upgradeLabel(payload.upgrade))}</h2>
        <p class="run-id"><code>${h(sessionId || "")}</code></p>
      </div>
      <div class="badge-row">${badge(statusText, statusTone)} ${badge(conditionLabel(payload.condition), "neutral")} ${badge(
        `Repeat ${countWord(payload.repeat)}`,
        "neutral",
      )}</div>
    </div>
    <p>${h(payload.notes || "A committed pilot result.")}</p>
    <dl class="facts facts--wide">
      ${fact("Verdict", h(verdictWord(payload.verdict)))}
      ${fact("Right first time", h(boolWord(payload.right_first_time)))}
      ${fact("Basis", h(payload.right_first_time_basis || "not recorded"))}
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
    ${grade?.note ? `<p class="fine-print">${h(grade.note)}</p>` : ""}
    ${log ? `<h3>The grader log</h3><pre class="log">${h(log)}</pre>` : ""}
    ${
      firstRows
        ? `<details class="more"><summary>First run against the new endpoint</summary><div class="more-body"><dl class="facts">${firstRows}</dl></div></details>`
        : ""
    }
    <p class="source-line">Source: <code>${h(payload.source || "not recorded")}</code></p>
  </section>`;
}

function sandboxRunDetail(record, records, runIds) {
  const payload = payloadOf(record);
  const verdict = object(payload.verdict) || {};
  const results = Array.isArray(payload.check_results) ? payload.check_results : [];
  const decision = ofKind(records, "decision").find((item) => item.run_id === record.run_id);
  const lesson = ofKind(records, "lesson").find((item) => item.run_id === record.run_id);
  const observation = ofKind(records, "page-observation").find((item) => item.run_id === record.run_id);
  const passed = runPassed(record);
  return `<section class="panel">
    <div class="panel-head">
      <div><h2>Sandbox run</h2><p class="run-id"><code>${h(record.run_id)}</code></p></div>
      <div class="badge-row">${badge(
        verdictWord(verdict.verdict),
        verdict.verdict === "exited" ? "neutral" : "fail",
      )} ${badge(passed ? "Checks passed" : "Checks failed", passed ? "pass" : "fail")}${
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
    <p><strong>Workspace</strong> <code>${h(payload.request?.workspace || "not recorded")}</code></p>
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
                <div class="check-head"><strong>${h(result.check_id || "check")}</strong><span>${h(
                  result.passed ? "passed" : "failed",
                )}</span></div>
                ${result.detail ? `<p>${h(result.detail)}</p>` : ""}
              </li>`,
            )
            .join("")}</ul>`
        : `<p class="muted">No check results were recorded.</p>`
    }
    <h3>Logs</h3>
    <details class="logs" open><summary>Standard output</summary><pre>${h(verdict.stdout || "")}</pre></details>
    <details class="logs"><summary>Standard error</summary><pre>${h(verdict.stderr || "")}</pre></details>
    ${decision ? `<h3>What Clef thought</h3>${opinionBlock(decision)}` : ""}
    ${lesson ? `<h3>The lesson from this run</h3><p>${h(payloadOf(lesson).observation || "")}</p>` : ""}
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
    <thead><tr><th scope="col">Kind</th><th scope="col">Run</th><th scope="col">Change kinds</th></tr></thead>
    <tbody>${rows}</tbody>
  </table></div></section>`;
}

export function runView({ runId = "", records = [], runs = null, warnings = [] } = {}) {
  const runIds = runIdSet(runs);
  const bench = benchmarkRecords(records);
  const runRecords = ofKind(records, "run");
  const sessionId = records[0]?.session_id || "";
  const title = bench.length
    ? `Pilot run: ${upgradeLabel(payloadOf(bench[0]).upgrade)}`
    : runRecords.length
      ? "Sandbox run"
      : "Run evidence";
  const benchStatus = bench.length ? payloadOf(bench[0]).status : "";
  const benchBadge =
    benchStatus === "invalid"
      ? badge("Invalid pilot row", "fail")
      : benchStatus === "diagnostic"
        ? badge("Diagnostic session", "pilot")
        : badge("Measured pilot run", "live");
  const illustrativeBadge = runRecords.some((record) => payloadOf(record).illustrative === true)
    ? badge("Illustrative", "draft")
    : "";
  return `<article class="run-page">
    <header class="page-head">
      <p class="breadcrumb"><a href="index.html">For judges</a> <span aria-hidden="true">/</span> Run</p>
      <div class="page-title"><h1>${h(title)}</h1>${bench.length ? benchBadge : ""}${illustrativeBadge}</div>
      <p class="run-id"><code>${h(runId)}</code></p>
      ${sessionId ? `<p class="quiet-line">From <a href="${attr(sessionHref(sessionId))}">${h(
        sessionId,
      )}</a></p>` : ""}
      <p class="quiet-line"><a href="index.html">Back to the evidence index</a></p>
    </header>
    ${warningsSection(warnings)}
    ${bench.map((record) => benchmarkRunDetail(payloadOf(record), sessionId)).join("")}
    ${runRecords.map((record) => sandboxRunDetail(record, records, runIds)).join("")}
    ${!bench.length && !runRecords.length ? `<div class="notice notice--quiet"><h2>No readable run record</h2><p>The store returned records for this run, but none is a run or benchmark record.</p></div>` : ""}
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
