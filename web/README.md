# Chaaya

Chaaya is the Kalari web front end. It is plain HTML, CSS and ES modules.
There is no build step, no npm, no bundler, no framework and no CDN.
Caddy serves the files and proxies `/api` to the Kalari service.

The app reads the evidence API in the browser. Every link is relative.
No host and no port appear in the app.

## Pages

| File | Address | What it shows |
|---|---|---|
| `index.html` | `/` | For judges: start here. The measured comparison, every condition, the containment moment and every run. |
| `session.html` | `/session.html?id=<id>` | One session: the change list, the blast radius, the recalled checks, each run with logs, the retry loop and the lesson written. |
| `run.html` | `/run.html?id=<id>` | One run: its verdict, checks, logs, Clef answer and evidence record. |

Deep links work. Reloading a session or a run page fetches that id again.

## Run the fixture

```sh
python3 web/fixture/server.py --port 0
```

Open the loopback address the server prints. It serves `web/` and `/api/*`.
The API status codes and JSON shapes match `Kalari/Http.lean`.

The server injects `data-fixture="true"` into every HTML page.
That makes a visible fixture banner appear. The real static files never carry it.
A screenshot from this server cannot pass for a published result.

Options:

- `--no-benchmark` answers `GET /api/benchmark` with `[]`.
- `--store PATH` reads another evidence JSONL file.
- A missing store file is an empty store, not an error.

## Run the check

```sh
./web/check.sh
```

The check is Python standard library only. It starts the fixture server on
loopback and stops it on exit. It checks these things:

1. The rendered judges page, session page and run page are served with 200.
2. Every number on the judges page is inside an anchor that points to a run
   present in `/api/runs`.
3. Every run id in the store appears in a link on the judges page.
4. No served page or asset contains an external URL.
5. An empty `/api/benchmark` renders the not-yet-published state.
6. Every Clef probability sits inside a block labelled a model's opinion.
7. The fixture store has no IP address, email, key pattern or URL.
8. The API returns 400, 404 and 413 as the real service does.

## How the pages render from the fixture

`web/fixture/evidence.jsonl` is the append-only store the fixture server reads.
`web/fixture/build.py` writes it from the committed pilot results and the
walkthrough records. Run the build only when the fixture sources change.

`web/fixture/rendered/` holds snapshots of the view output. The check parses
these snapshots. They are made by the same `web/app/views.mjs` the browser runs.

`web/fixture/render.mjs` regenerates the snapshots. It is a development tool.
It uses Node, but the app and the check do not need Node.

`web/fixture/rendered/manifest.json` pins the view code and the fixture evidence.
`check.sh` fails when a snapshot is stale. Regenerate with:

```sh
node web/fixture/render.mjs
```

## What is measured

The judges page shows the committed baseline pilot. The pilot files are in
`bench/pilot/results/`. Each benchmark record carries its source path.

- Conditions 2, 3 and 6 are `valid` pilot rows.
- Condition 1 rows are `invalid`. The session resumed but graded an untouched
  workspace. The repair is T5.1a, so these rows cannot count.
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
- The UI marks every illustrative session and run. The pilot rows say
  `Pilot, reference arm`, `Invalid pilot row` or `Diagnostic session`.

## The benchmark record shape

No producer writes benchmark records yet. T5.6 must honour this shape.
Write one record per run. The envelope is the normal evidence record:

```json
{
  "kind": "benchmark",
  "session_id": "pilot-c5-settlements",
  "run_id": "pilot-c5-settlements-r1",
  "change_kinds": ["pagination_changed"],
  "payload": {}
}
```

The payload fields:

| Field | Type | Meaning |
|---|---|---|
| `schema` | string | `kalari.benchmark.v1`. |
| `provenance` | string | `pilot` or `frozen`. |
| `status` | string | `valid`, `invalid` or `diagnostic`. |
| `arm` | string | `reference` or `kalari`. |
| `condition` | number | The condition number, 1 to 6. |
| `upgrade` | string | `payouts` or `settlements`. |
| `repeat` | number | The repeat number, 1 to 5. |
| `behaviour` | string or null | `B1` to `B5` for a diagnostic row. |
| `session_id` | string | The session that produced the run. |
| `session_continued` | boolean or null | Whether the session resumed an earlier one. |
| `notes_attached` | boolean or null | Whether the session read the earlier notes. |
| `session_capped` | boolean or null | Whether the session cap fired. |
| `session_cap_s` | number or null | The cap in seconds. |
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
| `grade` | object or null | The hidden grader result. |
| `first_v2_grade` | object or null | The first new-endpoint grade. |
| `grader_runs` | object or null | The final grader status and log excerpt. |
| `opencode_exit` | number or null | The coding agent process exit code. |
| `process_elapsed_s` | number or null | Wall time of the harness process. |
| `source` | string | The committed result file. |
| `notes` | string | A short note for the reader. |

The `grade` object has these fields. Each may be null when it is unknown.

`verdict`, `output_present`, `records`, `unique`, `expected`, `missing`,
`extra`, `duplicates`, `mismatched`, `unreadable_lines`, `note`.

Rules for the producer:

- `null` means unknown. Never write zero when the measure is unknown.
- `run_id` must exist in `/api/runs`. The app hides a number whose run id is
  not in the run index, so a broken link cannot appear.
- Use `provenance: "frozen"` for the published comparison. With condition 5 and
  condition 3 present, the judges page shows the frozen before and after.
- Write one record per run. The app groups records by condition and upgrade.
- Every number on the judges page comes from a record and links to its run.

## Other record kinds the session view reads

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
It never treats them as a measurement, a grade or a verdict.

## API contract

- `GET /api/sessions` and `GET /api/runs` return arrays of ids.
- `GET /api/lessons` and `GET /api/benchmark` return arrays of evidence records.
- `GET /api/sessions/<id>` and `GET /api/runs/<id>` return arrays of records.
- A record is `{kind, session_id, run_id, change_kinds, payload}`.
- A malformed id is 400. An unknown id is 404. A body over 4096 bytes is 413.
- The app handles empty arrays, an absent store and each error status.

## Privacy

The fixture has no IP address, key, account detail or email.
The illustrative command names its endpoint `ENDPOINT`.
The app redacts a URL before display.
The fixture banner prevents a fixture screenshot from passing for a result.

## Files

```text
web/
├── index.html, session.html, run.html   the page shells
├── app.css                              the whole visual system
├── favicon.svg
├── app/
│   ├── api.mjs                          fetch the evidence API
│   ├── boot.mjs                         put a view into the page
│   ├── format.mjs                       numbers, links and escaping
│   ├── labels.mjs                       product language
│   ├── views.mjs                        the judges, session and run views
│   └── judges.mjs, session.mjs, run.mjs the three entry points
├── fixture/
│   ├── build.py                         write evidence.jsonl from pilot results
│   ├── evidence.jsonl                   the fixture store
│   ├── server.py                        static files plus the evidence API
│   ├── render.mjs                       regenerate the rendered snapshots
│   └── rendered/                        committed snapshots and manifest
└── check.sh, check.py                   the standard-library check
```
