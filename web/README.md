# Chaaya

Chaaya is the Kalari web front end. It is plain HTML, CSS and ES modules.
There is no build step, no npm, no bundler, no framework and no CDN.
Caddy serves `web/site/` and proxies `/api` to the Kalari service.

The app reads the evidence API in the browser. Every link is relative.
No host and no port appear in the app. The only exception is the pinned
GitHub evidence prefix below.

`web/site/` is the published static root. Caddy serves it at `/`. `web/fixture/`
sits outside it and has no HTTP route. The fixture server serves `web/site/` and
`/api/*` only. The docs site is served at `/docs/`; judges links there are
same-origin top-level navigation.

## Pages

| File | Address | What it shows |
|---|---|---|
| `web/site/index.html` | `/` | For judges: start here. The seven 0.2.3 parts: the problem, the headline with the grid, the easier upgrades, learning, containment, Qwen and Muse, and the demoted baseline. Then every run and every session. |
| `web/site/session.html` | `/session.html?id=<id>` | One session: the change list, the blast radius, the recalled checks, each run with logs, the retry loop and the lesson written. |
| `web/site/run.html` | `/run.html?id=<id>` | One run: its verdict, checks, logs, Clef answer and evidence record. |

Deep links work. Reloading a session or a run page fetches that id again.

## Run the fixture

```sh
python3 web/fixture/server.py --port 0
```

Open the loopback address the server prints. It serves `web/site/` and `/api/*`.
It does not serve `web/fixture/` or any rendered snapshot.

The server injects `data-fixture="true"` and a visible fixture banner into every
HTML page it serves. The published files in `web/site/` carry no banner. A
screenshot of a served page shows the banner. A screenshot of a published page
does not. The server sends a strict `Content-Security-Policy` on every response,
including 400, 404 and 413. The policy has `default-src 'self'` and
`connect-src 'self'`. The published shells carry the same policy in a `meta`
tag. The policy blocks every subresource from another origin. It does not block
top-level navigation or `window.open`. The static check rejects both. The browser
check loads each page and fails on any request outside the page origin.

Options:

- `--no-benchmark` answers `GET /api/benchmark` with `[]`.
- `--store PATH` reads another evidence JSONL file.
- A missing store file is an empty store, not an error.

The fixture server answers the same status codes and record shapes as
`Kalari/Http.lean`. A run or session id uses only `A-Z`, `a-z`, `0-9`, dot,
underscore and hyphen. A malformed id is 400. An unknown id is 404. The web
check tests the fixture server. The Lean handler has its own tests.

## Run the check

```sh
./web/check.sh
```

The check is Python standard library only. It starts the fixture server on
loopback and stops it on exit. It reads the rendered snapshots from
`web/fixture/rendered/` on disk, never over HTTP. It checks these things:

1. Every file under `web/site/` is hashed in the manifest, and every rendered
   page has a hash. The snapshot inputs have a hash too.
2. Every served file and snapshot has no external URL, no `meta refresh` and no
   navigation sink. The single exception is the pinned GitHub evidence prefix:
   `https://github.com/nrynss/kalari/` with a `blob/` or `tree/` path pinned
   to `EVIDENCE_REF` in `web/site/app/views.mjs`. Every other external URL
   fails. A `fetch`, `import`, `WebSocket`, `EventSource` or `Worker`
   call must take a relative literal or pass through the `localPath` guard. A
   `window.open`, a `location` assignment, `location.assign`, `location.replace`,
   `eval`, `window.eval`, `document.write` and `document.writeln` fail. Evidence
   links are plain `<a>` navigation with no `target`, so `default-src 'self'`
   does not change. The check verifies `EVIDENCE_REF` is a 40-character hash
   that exists (`git cat-file -e`) and that every linked path exists at it.
   The docs link targets the same-origin path `/docs/`, which the relative-path
   rule already allows.
3. The fixture store and every rendered page have no IP address, email or key
   pattern.
4. The published shells and the rendered pages carry no fixture banner, and
   every print rule for the banner is scoped to fixture mode.
5. Every published shell carries `default-src 'self'` and `connect-src 'self'`.
   Every server response carries the same policy. The check reads a 200, a 400,
   a 404 and a 413.
6. The fixture server serves `web/site/` only. Every fixture path and snapshot
   path answers 404.
7. The live shells and entry modules are present.
8. The API returns 400, 404 and 413 as expected. Every record on every route
   passes the envelope contract. The benchmark records pass the contract
   validator.
9. Every number on the judges page sits inside a working run link, a pinned
   GitHub source link, or a section link for the two derived ratios. Model and
   version names are the exception: they sit inside a `model-tag` marker and
   only name a known model (`OpenCode 2.2.5`, `DeepSeek V4.1 Flash`,
   `GLM 5.3 Flash`, `Qwen3.8 27B`, `Muse Glimmer 30B`, `MiMo V2.6 Flash`,
   `Kalari 0.2.3`). Every anchor whose text contains a digit carries a
   `data-run-link` that equals its href id and a known figure title, or it is
   a pinned GitHub blob link, a ratio section link, or a session link that
   shows its own id. Every distinct run link answers 200 at
   `/api/runs/<id>`.
10. Every run id and every session id in the store appears in a link on the
    judges page. Every repeat row is reachable from the grid cell it counts
    toward.
11. Every every-run table value matches the record named by its run link, and
    every row carries a link to its published row file on GitHub.
12. The check recomputes every figure on the page from the repeat, baseline
    and containment records the snapshot was rendered from: the problem
    counts, the headline means and ratios, the grid cells, the easier-upgrade
    tally, the learning counts, the filmed chain, the excluded tallies, the
    demoted baseline and the containment panel. `bench/check-023.py`
    independently recomputes every video number from the published rows and
    compares them with `bench/rows-0.2.3/results.json`. Model names on every
    page are checked against the known list.
13. Aggregates link the median session of the set they summarise. Per-session
    figures link their own session. The two cost and wall ratios link the
    grid section that breaks them down.
14. Every table has a caption or `aria-labelledby`.
15. A percentage anywhere on the page fails. The 0.2.3 page carries no
    opinion block and no probability. A probability-shaped decimal fails in a
    table, a verdict or a heading.
16. Removed with the retired views.
17. An empty `/api/benchmark` renders the not-yet-published state. The comparison
    heading is `The pilot baseline` with no frozen pair and `The measured before
    and after` with one. The repeat copy comes from both contrast columns.
18. A URL in a store string is redacted before display. The check proves this
    for stdout, stderr and the command. It also covers a check detail, a check
    id, a lesson, a lesson check, the grader log, a grade note and the source.
    It covers a session note, a session summary, a change title and a change
    endpoint. It also covers a call site, a radius note, the workspace and the
    decision question. It covers a full URL and a scheme-relative URL.
19. An empty `/api/benchmark` renders the not-yet-published state.
20. An absent store returns empty arrays and shows a clear state. No session
    card is drawn, and no line claims a session the store does not have.
18. The containment panel matches its record: the cap, the measured wall
    time, the pages, the retry wait, the allowed and refused probes and the
    zero leftovers link the killed run; the failure, the polling note, the
    configuration-only caps, the separate requested, effective and observed
    policy, the second-guest probe and the verified cleanup are all stated,
    and a zero-blast-radius claim appears only as a denial. The record passes
    its contract: `killed_timeout`, `passed=false`, no output-cap claim, no
    breach, verified cleanup, and run and check records with the same wall
    time and cap. The run page shows the creation arguments and the three
    policy views. The committed evidence under
    `tests/live/containment-0.2.3/` is scanned for a path, an IP address, a
    host name and a key pattern, as is every published 0.2.3 row and the
    evidence store.

## Browser check

`web/check.sh` does not start a browser. `python3 web/fixture/browser_check.py`
drives headless Chrome over the DevTools pipe when one is installed. It reads
the network events of the page itself, so the browser's own background traffic
never enters the result. It loads five addresses through the three shells:
`/`, `/session.html?id=kalari-payouts-918666ca`,
`/run.html?id=kalari-payouts-918666ca` and `/run.html?id=run-d963816f7f`.
It fails on any request outside the page origin. It fails on a second page
target outside that origin. It fails on a page that did not render its heading.
It does not load a shell without an id. It cannot load the rendered snapshots,
because the fixture server does not serve them. The static scan and the snapshot
checks cover every other state. The browser check is a development tool, not
part of the gate.

## How the pages render from the fixture

`web/fixture/evidence.jsonl` is the store the fixture server reads. It is a
copy of `bench/evidence-023.jsonl`, written by `web/fixture/build.py`, which
validates every record first. The canonical evidence is built by
`bench/produce-evidence-023.py` from the sanitised rows in
`bench/rows-0.2.3/`. Run the build only when the fixture sources change.

`web/fixture/rendered/` holds snapshots of the view output. The check parses
these snapshots from disk. They are made by the same view code the browser
runs: `judges023View` for the judges pages, `sessionView` and `runView` from
`web/site/app/views.mjs` for the session and run pages. The snapshots cover
the full store, the empty store, one repeat session page and one repeat run
page. `web/fixture/rendered/inputs.json` records the exact records each
snapshot was rendered from, and the check derives its expectations from that
file.

`web/fixture/render.mjs` regenerates the snapshots. It is a development tool.
It uses Node, but the app and the check do not need Node.

`web/fixture/rendered/manifest.json` has a sha256 for every rendered page and
every file under `web/site/`. It also has the fixture evidence hash.
`check.sh` fails when any hash changes. Regenerate with:

```sh
node web/fixture/render.mjs
```

## What is measured

The judges page shows the 0.2.3 repeats in seven parts: the problem, the
headline with the grid, the easier upgrades, learning, containment, Qwen and
Muse, and the demoted baseline. Then every run and every session. Each number
links to the run or row behind it. Each benchmark record carries its source
path in `bench/rows-0.2.3/`.

- The headline covers the 90 headline repeats: three models by three upgrades
  by two arms, five sessions per cell. Every repeat row is reachable from the
  grid cell it counts toward.
- The problem is the filmed GLM disbursements session alone, backed by the
  five GLM disbursements sessions alone, each graded 23 mismatched.
- Learning compares the payouts lessons written with the settlements and
  disbursements lessons recalled, plus the filmed three-step chain, which kept
  one project and one store.
- The containment panel covers the 0.2.3 killed run, not a benchmark row. It
  reads the `containment` records of its own session, `containment-023`: the
  cap, the measured wall time, `killed_timeout`, `passed=false`, the pages
  fetched and the one Retry-After wait; then the boundary (requested, effective
  and observed network policy, kept apart) and the cleanup proof. It links its
  run page, its session page, and the bundle on GitHub. The panel is absent
  when the store has no such session.
- Qwen and Muse ran once per upgrade outside the headline. Their sessions sit
  apart with the reasons.
- The frozen 60-session DeepSeek benchmark stays as an earlier baseline, with
  per-session costs only. The old zero-lesson reading is corrected: the
  repeats wrote and recalled lessons.
- The repeat and baseline counts come from the records. The page hardcodes no
  tally.
- A repeat session page says `Repeat session`. The baseline session page says
  `Earlier baseline`.

## The benchmark record shape

No runtime producer writes frozen benchmark records any more. T5.6 honoured
that shape; the 0.2.3 repeats use two newer schemas on the same envelope and
the same `/api/benchmark` route. Write one record per session. The envelope
is the normal evidence record.

A repeat record (`kalari.repeat.v1`, `provenance: "repeat023"`) carries the
arm, model, scenario, project, repeat index, headline flag and chain name, the
verdict, right-first-time, sandbox runs, wall time, tokens, loss and
duplication counts, cost, grade, lesson counts, tool calls, and the published
row as `source`. A baseline record (`kalari.baseline.v1`,
`provenance: "baseline"`) carries the frozen session count and per-session
costs with `bench/RESULTS.md` as its source. `bench/produce-evidence-023.py`
builds both from `bench/rows-0.2.3/`. The validator compares every repeat
payload field with its published row.

The frozen shape below stays documented for the committed frozen evidence:

```json
{
  "kind": "benchmark",
  "session_id": "pilot-c5-settlements",
  "run_id": "pilot-c5-settlements-r1",
  "change_kinds": ["pagination_changed"],
  "payload": {
    "schema": "kalari.benchmark.v1",
    "provenance": "frozen",
    "status": "valid",
    "arm": "kalari",
    "condition": 5,
    "upgrade": "settlements",
    "repeat": 1,
    "behaviour": null,
    "session_id": "pilot-c5-settlements",
    "session_continued": false,
    "notes_attached": true,
    "session_capped": false,
    "session_cap_s": 1200,
    "verdict": "PASS",
    "right_first_time": true,
    "right_first_time_basis": "snapshot",
    "sandbox_runs": 1,
    "sandbox_runs_against_v1": 0,
    "sandbox_runs_against_v2": 1,
    "wall_time_s": 421.5,
    "time_stuck_s": 0,
    "tokens_input": 120000,
    "tokens_output": 4000,
    "records_lost": 0,
    "records_duplicated": 0,
    "records_extra": 0,
    "records_mismatched": 0,
    "cost_usd": 0.0123,
    "grade": {
      "verdict": "PASS",
      "output_present": true,
      "records": 2431,
      "unique": 2431,
      "expected": 2431,
      "missing": 0,
      "extra": 0,
      "duplicates": 0,
      "mismatched": 0,
      "unreadable_lines": 0
    },
    "first_v2_grade": {
      "verdict": "PASS",
      "output_present": true,
      "records": 2431,
      "unique": 2431,
      "expected": 2431,
      "missing": 0,
      "extra": 0,
      "duplicates": 0,
      "mismatched": 0,
      "unreadable_lines": 0
    },
    "grader_runs": {
      "final": {"status": "EXIT 0", "log_excerpt": "synced 2431 settlements\n"}
    },
    "opencode_exit": 0,
    "process_elapsed_s": 425.0,
    "source": "bench/frozen/results/condition-5-settlements-r1.json",
    "notes": "One frozen comparison run."
  }
}
```

The payload fields:

| Field | Type | Meaning |
|---|---|---|
| `schema` | string | `kalari.benchmark.v1`. Required. |
| `provenance` | string | `pilot` or `frozen`. Required. |
| `status` | string | `valid`, `invalid` or `diagnostic`. Required. |
| `arm` | string | `reference` or `kalari`. Required. |
| `condition` | number | The condition number, 1 to 6. Required. |
| `upgrade` | string | `payouts` or `settlements`. Required. |
| `repeat` | number | The repeat number, 1 to 5. Required. |
| `behaviour` | string or null | `B1` to `B5` for a diagnostic row. Null otherwise. |
| `session_id` | string | The session that produced the run. It must equal the envelope `session_id`. |
| `session_continued` | boolean or null | Whether the session resumed an earlier one. |
| `notes_attached` | boolean or null | Whether the session read the earlier notes. |
| `session_capped` | boolean or null | Whether the session cap fired. |
| `session_cap_s` | number or null | The cap in seconds. Required when `session_capped` is true. |
| `verdict` | string | `PASS` or `FAIL` from the hidden grader. |
| `right_first_time` | boolean or null | Whether the first new-endpoint run passed. |
| `right_first_time_basis` | string | How that first run was graded. |
| `sandbox_runs` | number or null | Consumer sandbox runs in the session. |
| `sandbox_runs_against_v1` | number or null | Runs against the old endpoint. |
| `sandbox_runs_against_v2` | number or null | Runs against the new endpoint. |
| `wall_time_s` | number or null | Session start to final answer, including stuck time. |
| `time_stuck_s` | number or null | Time in runs that ended by a timeout. |
| `tokens_input` | number or null | Input tokens for the session. |
| `tokens_output` | number or null | Output tokens for the session. |
| `records_lost` | number or null | Records missing from a failing consumer. |
| `records_duplicated` | number or null | Duplicate records from a failing consumer. |
| `records_extra` | number or null | Records not in the truth set. |
| `records_mismatched` | number or null | Records whose content differs from the truth. |
| `cost_usd` | number or null | List-price session cost. |
| `grade` | object or null | The hidden grader result. Shape below. |
| `first_v2_grade` | object or null | The first new-endpoint grade. Same shape as `grade`. |
| `grader_runs` | object or null | Stage name to `{status, log_excerpt}`. |
| `opencode_exit` | number or null | The coding agent process exit code. |
| `process_elapsed_s` | number or null | Wall time of the harness process. |
| `source` | string | The committed result file. Required. It is repo-relative and it exists. A synthetic view fixture names a readable JSON file instead. |
| `notes` | string | A short note for the reader. The judges page does not show it. |

The `grade` object has these fields. Each may be null when it is unknown.

| Field | Type |
|---|---|
| `verdict` | `PASS`, `FAIL` or null |
| `output_present` | boolean or null |
| `records`, `unique`, `expected`, `missing`, `extra`, `duplicates`, `mismatched`, `unreadable_lines` | count or null |
| `note` | string or null |

`first_v2_grade` uses the same object shape.

`grader_runs` is an object keyed by stage name, such as `final` or `first`.
Each value is `{"status": string, "log_excerpt": string}`. The run page reads
`grader_runs.final.log_excerpt` and `grader_runs.final.status`.

A run or session id uses only `A-Z`, `a-z`, `0-9`, dot, underscore and hyphen.
It is not empty. The validator and the API route enforce the same rule. The app
hides a run link whose id fails it.

Rules for the producer:

- The envelope `session_id` is authoritative. The payload copy must equal it.
- The envelope is `{kind, session_id, run_id, change_kinds, payload}` for every
  record. `change_kinds` is an array of non-empty strings. `payload` is an
  object. A benchmark-shaped payload without `kind: "benchmark"` is an error.
- `null` means unknown. Never write zero when the measure is unknown.
- `run_id` must exist in `/api/runs`. The app hides a number whose run id is
  not in the run index, so a broken link cannot appear.
- A benchmark `run_id` is unique. Write one record per run.
- `source` is a non-empty path relative to the repository. The file must exist,
  and the payload must match it. The validator compares `condition`, `upgrade`,
  `arm`, the measure fields, the source fields, `grade`, `first_v2_grade` and
  `grader_runs`. A record cannot claim a measure its source file does not hold.
- `synthetic: true` marks a view fixture. The validator treats the record as a
  view test and not as a measurement. It still checks every other field, and it
  still requires a source that is readable JSON. It does not compare the payload
  with that source. A producer never writes this field.
- `condition` and `arm` must agree. Conditions 1, 2, 3 and 6 use
  `reference`. Conditions 4 and 5 use `kalari`.
- `status: "diagnostic"` needs a `behaviour`. Other statuses use `null`.
  A diagnostic row keeps the condition it ran under, for information. The page
  groups diagnostics by upgrade and behaviour. A diagnostic row is a pilot row.
- A frozen record is a valid comparison record. The validator rejects a frozen
  row with status `invalid` or `diagnostic`.
- `verdict` and `grade.verdict` must agree when both are present.
- `records_lost` equals `grade.missing` when both are present.
  `records_duplicated` equals `grade.duplicates` when both are present.
- `sandbox_runs` equals the sum of the against counts when all three are present.
- Use `provenance: "frozen"` for the published comparison. With condition 5 and
  condition 3 present for one upgrade, the judges page shows the frozen before
  and after for that upgrade. One frozen arm alone does not publish the
  comparison. Diagnostic rows do not enter the frozen contrast.
- The page groups records by condition and upgrade.
- Every number on the judges page comes from a record and links to its run.
- Run `python3 web/fixture/validate.py` before writing a store.

## Other record kinds the session view reads

Every record kind uses the same envelope: `{kind, session_id, run_id,
change_kinds, payload}`. The validator checks that envelope on every record it
reads, and the web check checks it on every record every route returns.

| Kind | Shape | Producer |
|---|---|---|
| `showcase` | `kalari.showcase.v1`, built by `bench/showcase/disbursements/produce-showcase.py` from the committed result files | One manufactured disbursement upgrade across models, in session `showcase-disbursements`. Apart from the benchmark records, never in a tally. Carries the model, the label, the verdict, the grader counts, the wall time, the cost, the result and transcript paths, and the Kalari differential sequence with whether the session fixed it. |
| `run` | `Kalari.Model.RunRecord` | The sandbox runner writes it. |
| `check` | `Kalari.Model.CheckResult` | The sandbox runner writes one per check. |
| `lesson` | `Kalari.Model.Lesson` | `record_lesson` writes it. |
| `page-observation` | `Kalari.Tools.Lesson.PageObservation` | The page observer writes it. |
| `verified-behavior` | `Kalari.Tools.Lesson.VerifiedBehavior` | The trusted run writes it. |
| `lesson-policy` | `Kalari.Tools.Lesson.PolicyProvenance` | The policy check writes it. |
| `session` | `{title, summary, arm, illustrative, notes}` | No producer yet. The fixture supplies it. |
| `change` | `{id, kind, severity, title, summary, endpoint, source}` | No producer yet. The fixture supplies it. |
| `containment` | `kalari.containment.v1`, written by `tests/live/containment.sh` | The containment runs's own summary. It shares the run id of the production `run` record. |
| `reference` | `kalari.reference.v1`, written by `web/fixture/build.py` from `bench/reference-paging/README.md` | The reference run that motivates Kalari. It lives in its own session, apart from the benchmark records, and never enters a benchmark tally. |
| `blast-radius` | `Kalari.Model.BlastRadius` | The search tool writes links to Lambo, not the evidence store. |
| `decision` | `{question, question_set, model, answer}` | No producer yet. The fixture supplies it. |

The `decision` answer is `{type, choice, probabilities, confidence}`.
The page always labels its percentages a model's opinion.
It never treats them as a measurement, a grade or a verdict. The view formats
every probability as a one-decimal percentage and marks it with
`data-probability`. The check rejects a percentage in a table cell, a verdict or
a heading. It rejects a percentage in an opinion block with no marker. It
rejects a number inside an opinion block with no marker. It rejects a
probability-shaped decimal in a table, a verdict, a heading or an opinion block.
It allows a percentage or a decimal in prose outside the opinion block, so a
note, a summary or a check detail can show one. It compares the marker value with
the visible Clef label.

## API contract

- `GET /api/sessions` and `GET /api/runs` return arrays of ids.
- `GET /api/lessons` and `GET /api/benchmark` return arrays of evidence records.
- `GET /api/sessions/<id>` and `GET /api/runs/<id>` return arrays of records.
- A record is `{kind, session_id, run_id, change_kinds, payload}`.
- An id uses only `A-Z`, `a-z`, `0-9`, dot, underscore and hyphen.
- A malformed id is 400. An unknown id is 404. A body over 4096 bytes is 413.
- The app handles empty arrays, an absent store and each error status.

## Privacy

The fixture has no IP address, key, account detail or email.
The illustrative command names its endpoint `ENDPOINT`.
The app redacts a full URL and a scheme-relative URL before display.
It does this for stdout, stderr and the command.
It also covers a check detail, a check id, a lesson, a lesson check, the grader
log, a grade note and the source.
It covers a session note, a session summary, a change title and a change
endpoint. It also covers a call site, a radius note, the workspace and the
decision question.
The check counts a redaction on every one of those paths in three snapshots.
The check scans every rendered page for an IP address, an email and a key
pattern, not only the evidence store.
The fixture lives outside the published root.
The fixture server adds a banner to every page it serves.
The published files carry no banner.

## Files

```text
web/
├── site/                                the published static root
│   ├── index.html, session.html, run.html   the page shells
│   ├── app.css                          the whole visual system
│   ├── favicon.svg
│   └── app/
│       ├── api.mjs                      fetch the evidence API
│       ├── boot.mjs                     put a view into the page
│       ├── format.mjs                   numbers, links and escaping
│       ├── labels.mjs                   product language
│       ├── views.mjs                    the judges, session and run views
│       └── judges.mjs, session.mjs, run.mjs the three entry points
├── fixture/                             development files, not published
│   ├── build.py                         write evidence.jsonl from pilot results
│   ├── validate.py                      validate evidence records
│   ├── evidence.jsonl                   the fixture store
│   ├── server.py                        static files plus the evidence API
│   ├── browser_check.py                 load the served pages in a browser
│   ├── render.mjs                       regenerate the rendered snapshots
│   └── rendered/                        committed snapshots, inputs and manifest
└── check.sh, check.py                   the standard-library check
```
