# P4: The tools

`kalari serve` as the agent sees it: an MCP server with five tools, and the evidence behind every answer. This is the product.

Read first: [`../product.md`](../product.md) (The product, Three kinds of judgement), [`../bench/README.md`](../bench/README.md) (Where Kalari's edge comes from, Where lessons come from), `testdata/opencode/` (T0.5: what OpenCode sends), `Examples/JsonRpc.lean`.

---

### T4.1: MCP server ★
```yaml
requires:   [T1.5, T0.5]
fixture-ok: yes
size:       M · frontier
owns:       Kalari/Mcp.lean
status:     done
```
JSON-RPC 2.0 over stdio, meeting what OpenCode 2.2.5 actually sends (T0.5): `initialize`, `notifications/initialized`, `tools/list`, `tools/call`, shutdown. Tool results as MCP content with `isError` for tool failures. Logs to stderr only. Each tool's input schema is small and exact: the agent reads it every step, so its size is a cost.

**Done when:** OpenCode's recorded session replays against it; `tools/list` returns the five tools; an unknown tool, bad arguments and a tool that throws each return the right error without killing the server.

**Notes (in review):** `Kalari.Mcp.serve` runs a newline JSON-RPC loop over supplied streams and an injected handler; it emits only protocol replies, flushing each one, and exits at EOF. T0.5 records shutdown through closing the stdio input stream; it contains no shutdown RPC message. `handle` returns no response for a valid notification, including `notifications/initialized`. Malformed envelopes without an ID receive an invalid-request error with `id: null`; request IDs are limited to strings and integers, and unsupported JSON-RPC versions are rejected. Initialization negotiates the server's supported MCP version (`2025-11-25`) instead of echoing an unsupported client version. The five compact schemas validate their own calls, including nested sandbox fields and extra-key rejection. Tool failures and exceptions return MCP text with `isError: true`; unknown tools and bad arguments return JSON-RPC -32602. Both recorded OpenCode sessions replay through the loop in build-time checks, followed by bad arguments, unknown tool, a thrown handler exception, a successful call proving recovery, and malformed-envelope, ID, version-negotiation, and notification cases. The schemas for the four tools beyond `what_changed` are inferred from their phase descriptions and the current model; downstream implementations must use or reconcile them. Wiring `serve` into the executable is outside this task's owned path.

---

### T4.2: Evidence store ★
```yaml
requires:   [T1.5]
fixture-ok: yes
size:       S · mid
owns:       Kalari/Evidence.lean
status:     done
```
Every run, every check result, every Clef answer and every lesson written, as JSON Lines in `.kalari/` (append-only, a truncated last line skipped with a warning). The source for the web app and the judges' page: every claim links to a record here.

**Done when:** append and reload; queries by run, by change kind and by session; a truncated last line; `.kalari/` gitignored.

**Notes (in review):** `Kalari.Evidence` appends JSONL records carrying a complete JSON payload, kind, session ID, run ID, and change-kind list. `load` returns records and warnings and also emits warnings to stderr without log contents. Queries preserve append order. Newline commits a record; decoding bytes line by line also handles a truncated UTF-8 character. Before appending after an unterminated tail, the writer appends `!` and a newline to make that tail invalid, then writes the next complete line. Existing bytes are never rewritten. Any invalid line is skipped with a warning. A mutex serializes all operations through a shared `Store` value. Independent store instances or processes writing the same path are unsupported; the service must share one value. Build-time tests exercise append/reload, all three queries, malformed and valid-looking unterminated tails, partial UTF-8, appending after each tail, 24 concurrent appends, and the existing `.kalari/` ignore rule.

---

### T4.3: `what_changed` and `blast_radius`
```yaml
requires:   [T4.1, T3.1, T3.4, T3.2]
fixture-ok: yes
size:       S · mid
owns:       Kalari/Tools/Changes.lean, Kalari/Lambo.lean (scoped-write prerequisite only)
status:     done
```
`what_changed`: two spec versions in, change facts and Vimanam's focused context out. `blast_radius`: change IDs in, call sites out (confirmed and uncertain apart), with the links written to Lambo as `resource`s with `repo_scope`.

**Done when:** on both benchmark workspaces, the agent-facing output names `pagination_changed` and the v1 call sites; the output stays under a stated token budget.

**Notes (in review):** The session keeps the full Vimanam diff to associate change IDs with searchable operations while the MCP arguments remain unchanged. REST paths are mapped through `operation_moved.details.old_path`; GraphQL uses the field in `native.coordinate`. `whatChanged` returns compact facts and, for GraphQL, Vimanam focused context; OpenAPI returns facts because Vimanam does not provide focused context for it. Both outputs reject JSON above 16,000 UTF-8 bytes, a conservative 16,000-token budget for byte-based tokenizers, excluding MCP envelope overhead; the GraphQL context request uses 2,000 tokens. `blastRadius` separates certain and uncertain sites and submits change and site resource links through an injected scoped writer, waiting on the writer for each applied ID. The typed Lambo client now accepts an optional top-level `repo_scope` on derive/write; the production resource writer waits for the applied concept ID. Its recorded child replay asserts scoped arguments and omission on existing calls.

The build-time check replays both Vimanam 2.1.0 diffs and GraphQL context, searches both real benchmark workspaces with `rg`, and checks pagination, caller paths, output byte caps and the scope/dependency arguments supplied to the fake writer. The task does not modify the MCP schema or make a live Lambo write.

---

### T4.4: `recall_lessons` ★
```yaml
requires:   [T4.1, T3.2, T3.3]
fixture-ok: yes
size:       S · frontier
owns:       Kalari/Tools/Recall.lean
status:     done
```
Change kinds in, the lessons for them out **as checks that must pass**, not as advice: each with its check ID, what it asserts, and the run that taught it. Lessons linked to the change kind always apply. One found only by meaning becomes a required check only if Clef's `lessonApplies` is confident; otherwise it's returned as advice and labelled so.

**Done when:** with the payouts lesson stored, recall on the settlements change returns it as a required check; an unrelated lesson found by meaning comes back as advice.

**Notes (in review):** Linked constraints take precedence over semantic hits; semantic candidates require a Clef probability of at least 0.9 to become required. Errors and lower scores yield advice. Incoming contradictions mark lessons stale rather than required. The tool expects constraint content to be a JSON-encoded `Model.Lesson`, including the check and run ID. The measured Lambo transcript stores a free-text constraint with a check ID alone, so it cannot provide the full model; the fixture uses a complete encoded payouts lesson. The fixture exercises the shared pagination kind, a low-scoring unrelated semantic lesson, duplicate suppression and stale status. Integration with the future lesson writer must use the same encoding.

---

### T4.5: `run_in_sandbox` ★
```yaml
requires:   [T4.1, T4.2, T2.1, T2.3, T2.6]
fixture-ok: yes
size:       L · frontier
owns:       Kalari/Tools/Run.lean
status:     done
```
The agent's code, run safely and checked: the gate; the Microsandbox backend with caps and an allowlist of the API hosts; the aashaan's verdict; then **the checks**: every recalled lesson's check, and the **differential check against v1** (bench/README.md): run the consumer's v1 version against the v1 API and its new version against v2 on the same data, compare the record sets (none missing, none extra, each exactly once, **each equal to v1's version**: an ID check alone passes a consumer that keeps the first, stale copy of an amended settlement), and report the difference in plain numbers. The result back to the agent: the verdict, each check's result, and logs, capped.

A run that hangs is killed by the aashaan, and the agent is told so in one line. That's the containment moment.

**Done when:** against fakes, each payouts reference consumer (T0.2) gets the right verdict and check results: `cursor_loop` killed by the cap, `no_dedupe` failing exactly-once with 24 duplicates, `correct` passing; a refused request never reaches the backend.

**Notes (in review):** `Kalari.Tools.Run.call` accepts the existing MCP `RunRequest` shape. Its trusted session context provides the prepared consumer workspace, separate pristine v1 workspace and command, expected JSONL filename, recalled checks, caps, allowed endpoints, key values to exclude, and evidence indexes. The gate runs on the candidate, baseline and each check before DNS or backend calls. The implementation uses the Microsandbox backend with a resolved IPv4 allowlist, configured image, guest overcommit setup, and forced removal. The aashaan's timeout and output cap are distinct from the bounded host transport budget so the supervisor can return its final verdict. After a successful consumer exit, the backend reads a bounded regular-file artifact through guest exec before running lesson checks. A hung consumer skips the artifact and checks and returns the aashaan verdict with a one-line explanation. The differential comparison uses full JSON records and reports counts of missing IDs, extra IDs, duplicate deliveries and changed records. The v1 and v2 consumers run in separate microVMs. Wiring the adapter and trusted session context into the service is T4.7.

The build-time fake replay uses the three payouts consumer commands with 2,431 IDs and the 24 boundary overlaps. It verifies the exact network and supervisor arguments, that a timed-out consumer skips checks and artifact collection, forced cleanup, the recalled check and differential outcomes, run and check evidence, and zero backend or DNS effects for a refusal. Comparator guards exercise changed content under the same ID, missing and extra IDs, and JSON object field ordering. The standard gate also runs the actual reference consumers against the benchmark API fixtures. This task performed no live sandbox run.

---

### T4.5b: `run_in_sandbox`, live
```yaml
requires:   [T4.5, T2.3b]
fixture-ok: no
size:       S · mid
owns:       tests/live/run.sh
status:     not-started
```
The reference consumers (six for payouts, seven for settlements), through `kalari serve`'s `run_in_sandbox` on the VM against the live APIs.

**Done when:** the transcript is in the report; outcomes as in T4.5; no sandbox left.

---

### T4.6a: Trusted payouts page observations ★
```yaml
requires:   [T4.5]
fixture-ok: yes
size:       M · frontier
owns:       bench/apis/payouts/server.py, bench/tests/quirks.sh, Kalari/Tools/Run.lean (observer seam)
status:     done
```
Capture bounded, host-owned page-response metadata from a dedicated payouts API instance for a verified candidate run. Bind observations to the run and derive boundary overlap and final-page token presence from a cursor-linked trace. Record only what the API sent. A passing result on identical payout overlaps does not establish last-delivery-wins behavior.

**Done when:** the real payouts reference consumer and grader produce a passing result and a trace showing one-record overlap and a token on the drained page. The run pipeline associates observations with a passing run and rejects missing, truncated, or ambiguous traces. The offline gate requires no live service or microVM.

**Notes (in review):** The optional `--trace` server argument exclusively creates a mode-0600 host file; it records up to 256 serialized successfully sent v2 pages, cursor digests, record IDs and terminal status, with an overflow marker. A dedicated server instance is required. The offline gate starts that instance separately, runs the actual payouts `correct.py`, grades its output, and validates the recorded chain: 25 pages, one-ID overlap at every boundary and a cursor on the drained page. That host run is not a microVM run; payouts keeps the first copy and establishes no last-wins policy.

`Run.Context.observer` is an optional host-owned observer. `payoutsObserver` launches a dedicated process on an explicitly configured IPv4 endpoint, creates its trace in the run-private host directory, and restricts requests to the configured guest source IPv4; startup waits for the bound listener. The candidate allowlist must contain exactly that endpoint. Run stops the observer even after sandbox execution failure. The trusted session must reserve the endpoint and supply a source IPv4 exclusive to that guest; an implementation unable to establish that property must not enable the observer. Only a passing run with all checks and differential comparison passing may emit `page-observation` evidence indexed by that exact run and session, with `{source: "payouts-api", behaviors: [...]}`. Parsing rejects missing, nonterminated, oversized, malformed, branched, repeated-cursor or nonterminal traces and verifies each observed one-record boundary intersection from complete page IDs. Offline fake-backend tests cover association, failing-run suppression and malformed traces. The service must configure this observer and establish an exclusive guest source address before use; unrelated external APIs do not produce this evidence. A build-time localhost test uses the concrete launcher with the real reference consumer and grader; the run-pipeline lifecycle remains verified with its sandbox backend fake, not a live microVM.

---

### T4.6: `record_lesson` ★
```yaml
requires:   [T4.5, T3.2, T3.3, T4.6a]
fixture-ok: yes
size:       M · frontier
owns:       Kalari/Tools/Lesson.lean, Kalari/Tools/Run.lean (trusted truth artifact only)
status:     in-review
```
Lessons from **what verified runs showed**, not only from failures (bench/README.md, Where lessons come from). Three sources: a failure Clef attributes to `api_change`, and the fix that passed; a behaviour the differential check observed on a pass (boundary duplicates, a token on the final page); a behaviour the passing code had to handle (a short page mid-stream). Each written to Lambo with its change kind, observation, run and check. A failure Clef calls `flaky`, `test_setup` or `unrelated_bug` is never a lesson. Kalari decides what is recorded; the agent can propose, never write directly.

**Done when:** from the payouts reference runs, the expected lesson is written (with the one-payout overlap and the final-page token as observations); its rule says to key records by ID with **the last delivery winning**, never "keep the first" or a bare "dedupe", even though payouts' identical overlaps can't tell them apart (settlements' amended repeats can: bench/README.md); a `flaky` failure writes nothing; a pass with no observed behaviour writes nothing.

**Notes (in review):** `record` takes a run ID and reads the service-owned Evidence store. The T4.6a producer writes `page-observation` with envelope `session_id`, `run_id`, and `change_kinds`, and payload `{source, behaviors}`; it emits only after the candidate and all configured checks, including `differential-v1`, pass. This payload carries observations only, never policy or a check assertion. `Lesson.attachAmendedPolicyCheck(ctx)` provisions a small executable and controlled amended-record fixture in the trusted `ctx.checkWorkspace`, then adds the full runnable check to `ctx.checks`. Its fixture contains two changed IDs and one unchanged ID; the executable verifies first-delivery selection differs from final truth and last-delivery selection matches it. This is independent policy provenance: payouts' boundary duplicates are identical and do not show which copy to keep. The recorder binds T4.6a's actual page observations to that exact passing check in `RunRecord.checks` and `check_results`; `differential-v1` alone remains insufficient because it has no command or assertion. The combined lesson therefore attributes page facts to the payouts run and the last-wins rule to the separate trusted fixture check; it does not claim the payouts run demonstrated amended values or that the fixture exercised candidate code. If the check did not run and pass, the recorder returns an error and writes no lesson.

Legacy `verified-behavior` evidence remains the failure/fix input and includes its complete check plus optional `failed_run_id`. The linked failure must precede the passing fix in evidence order and both run envelopes must index the same change kind. Clef classifies the actual earlier failing run; only `api_change` can add failure-derived text. `flaky`, `test_setup`, and unrelated diagnoses write nothing. Empty behavior passes write nothing. A single per-service `Write` value owns the mutex shared by every `record_lesson` handler. It serializes validation, append, and receipt-backed resource/constraint/observation writes. If a graph write fails after evidence append, retry validates and reuses the identical typed lesson record, then repeats the same deterministic Lambo derive inputs and waits for their receipts; it does not append duplicate lesson evidence.

The build fixture covers recorded page observations and check bootstrap, retry after a failed graph write, concurrent calls sharing one writer, evidence order and shared change kind, flaky/no-observation no-write cases, API-change fix, and T4.4 evidence resolution. The production page-observer seam and benchmark tracer belong to T4.6a and are not edited by this task.

---

### T4.7: Kalari with OpenCode ★
```yaml
requires:   [T4.3, T4.4, T4.5, T4.6]
fixture-ok: no
size:       S · mid
owns:       bench/kalari-arm/
status:     not-started
```
The Kalari arm's setup: OpenCode 2.2.5 with `kalari serve` as its MCP server (and `microsandbox-mcp` removed, so code runs only through `run_in_sandbox`), host shell denied, `--standalone` and per-run `XDG_*` directories. One upgrade-one session end to end on the VM, **not counted as a benchmark run** (the pair isn't frozen until T5.3).

**Done when:** the session's transcript shows the five tools called, a run graded by the hidden grader, the measures recorded; no process or sandbox left.

---

## Exit Criteria

- [ ] An agent can upgrade a consumer through the five tools, with every claim backed by the evidence store.
- [ ] Lessons are written from verified runs only, failures and observed behaviour alike.
