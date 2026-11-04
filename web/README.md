# Chaaya

Chaaya is the Kalari web front end. It is plain HTML, CSS and ES modules.
There is no build step, no npm, no bundler, no framework and no CDN.
Caddy serves `web/site/` and proxies `/api` to the Kalari service.

The app reads the evidence API in the browser. Every link is relative.
No host and no port appear in the app.

`web/site/` is the published static root. Caddy serves it at `/`. `web/fixture/`
sits outside it and has no HTTP route. The fixture server serves `web/site/` and
`/api/*` only.

## Pages

| File | Address | What it shows |
|---|---|---|
| `web/site/index.html` | `/` | For judges: start here. The pilot baseline, every condition in the fixture, the containment moment and every run. |
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
does not. The server also sends a strict `Content-Security-Policy` on every
response: `default-src 'self'` and `connect-src 'self'`. The published shells
carry the same policy in a `meta` tag, so a deployed page makes no request to
another origin.

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
   page has a hash.
2. Every served file and snapshot has no external URL. A `fetch`, `import`,
   `WebSocket`, `EventSource` or `Worker` call must take a relative literal or
   pass through the `localPath` guard.
3. The fixture store and every rendered page have no IP address, email or key
   pattern.
4. The published shells and the rendered pages carry no fixture banner, and
   every print rule for the banner is scoped to fixture mode.
5. Every published shell and every server response carries
   `default-src 'self'` and `connect-src 'self'`.
6. The fixture server serves `web/site/` only. Every fixture path and snapshot
   path answers 404.
7. The live shells and entry modules are present.
8. The API returns 400, 404 and 413 as expected. Every record on every route
   passes the envelope contract. The benchmark records pass the contract
   validator.
9. Every number on the judges page is inside a working run link. Every anchor
   whose text contains a digit carries a `data-run-link` that equals its href
   id and a known title. Every distinct run link answers 200 at
   `/api/runs/<id>`.
10. Every run id in `/api/runs` appears in a link on the judges page.
11. Every table value matches the record named by its run link. Every table
    cell with a number is a known measure.
12. Each page carries an exact count of measure links, number anchors and
    table cells. A new number needs a new measure and a new count.
13. Every median is computed from the benchmark records and compared with the
    displayed text.
14. Every table has a caption or `aria-labelledby`.
15. Every percent on every page sits in visible text inside a block labelled a
    model's opinion. A percent in a table cell, a verdict or a heading fails.
    The `data-probability` marker is a second assertion.
16. One frozen row in each upgrade does not say the comparison is published. A
    complete pair does. Frozen run and session pages carry frozen labels.
17. Conditions four and five without a record show explicit `not run` rows. The
    pilot contrast says `The pilot baseline`, and the repeat counts come from
    the records.
18. A URL in a run log is redacted before display.
19. An empty `/api/benchmark` renders the not-yet-published state.
20. An absent store returns empty arrays and shows a clear state.

## Browser check

`web/check.sh` does not start a browser. `python3 web/fixture/browser_check.py`
loads the three published pages in headless Chrome when one is installed. It
subtracts the browser's own background hosts, then fails if a page requests any
other host. It also checks that each page rendered its heading. It is a
development tool, not part of the gate.

## How the pages render from the fixture

`web/fixture/evidence.jsonl` is the append-only store the fixture server reads.
`web/fixture/build.py` writes it from the committed pilot results and the
walkthrough records. Run the build only when the fixture sources change.

`web/fixture/rendered/` holds snapshots of the view output. The check parses
these snapshots from disk. They are made by the same `web/site/app/views.mjs`
the browser runs. Five of the snapshots exercise states the committed pilot
store cannot show: a partial frozen pair, a complete frozen pair, a frozen run,
a frozen session, and a log with a URL. They are test fixtures, not served
pages.

`web/fixture/render.mjs` regenerates the snapshots. It is a development tool.
It uses Node, but the app and the check do not need Node.

`web/fixture/rendered/manifest.json` has a sha256 for every rendered page and
every file under `web/site/`. It also has the fixture evidence hash.
`check.sh` fails when any hash changes. Regenerate with:

```sh
node web/fixture/render.mjs
```

## What is measured

The judges page starts with `The pilot baseline`. That heading becomes `The
measured before and after` when one upgrade has a complete frozen pair:
condition five and condition three in the same upgrade. The pilot files are in
`bench/pilot/results/`. Each benchmark record carries its source path.

- Conditions 2, 3 and 6 are `valid` pilot rows.
- Condition 1 rows are `invalid`. The session resumed but graded an untouched
  workspace. The repair is T5.1a, so these rows cannot count.
- Conditions 4 and 5 have no record in this fixture. The page lists them under
  `Conditions not run in this fixture` with an explicit not-run row. The heading
  says `Every condition in this fixture`, and the baseline is labelled a pilot
  baseline until the frozen pair exists.
- The single-behaviour rows are `diagnostic`. They used a narrower isolated
  adapter, so the page does not compare them with the condition rows.
- The containment moment is `condition-3-payouts-r5.json`. Its record has
  `session_capped` true, wall time 1202.0 s, verdict `PASS`, and 2,431 graded
  records. The page links that run like every other figure.
- The walkthrough session is illustrative. The change facts and IDs come from
  `testdata/vimanam/2.1.0/payouts.json`. The call site comes from
  `bench/workspaces/payout-sync/payout_sync.py`. The Clef answer comes from
  `testdata/clef/failure-api-change-truncated.response.json`. The run timings and
  log lines are illustrative.
- The repeat counts come from the records. The page does not hardcode five.
- The UI marks every illustrative session and run. The pilot rows say
  `Pilot, reference arm`, `Pilot, Kalari arm`, `Invalid pilot row` or
  `Diagnostic session`. A frozen row says `Frozen, reference arm` or
  `Frozen, Kalari arm`, and a frozen run or session says `Frozen comparison
  run` or `Frozen benchmark session`.

## The benchmark record shape

No runtime producer writes benchmark records yet. T5.6 must honour this shape.
Write one record per run. The envelope is the normal evidence record:

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
| `source` | string | The committed result file. Required. It is repo-relative and it exists. |
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
| `run` | `Kalari.Model.RunRecord` | The sandbox runner writes it. |
| `check` | `Kalari.Model.CheckResult` | The sandbox runner writes one per check. |
| `lesson` | `Kalari.Model.Lesson` | `record_lesson` writes it. |
| `page-observation` | `Kalari.Tools.Lesson.PageObservation` | The page observer writes it. |
| `verified-behavior` | `Kalari.Tools.Lesson.VerifiedBehavior` | The trusted run writes it. |
| `lesson-policy` | `Kalari.Tools.Lesson.PolicyProvenance` | The policy check writes it. |
| `session` | `{title, summary, arm, illustrative, notes}` | No producer yet. The fixture supplies it. |
| `change` | `{id, kind, severity, title, summary, endpoint, source}` | No producer yet. The fixture supplies it. |
| `blast-radius` | `Kalari.Model.BlastRadius` | The search tool writes links to Lambo, not the evidence store. |
| `decision` | `{question, question_set, model, answer}` | No producer yet. The fixture supplies it. |

The `decision` answer is `{type, choice, probabilities, confidence}`.
The page always labels its percentages a model's opinion.
It never treats them as a measurement, a grade or a verdict. The check reads
every percent in visible text and rejects one in a table cell, a verdict or a
heading.

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
The app redacts a URL in every command, log, check detail and lesson text
before display.
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
│   └── rendered/                        committed snapshots and manifest
└── check.sh, check.py                   the standard-library check
```
