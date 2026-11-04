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
owns:       tests/live/run.sh, Kalari/Service.lean (trusted executable path only)
status:     done
```
The reference consumers (six for payouts, seven for settlements), through `kalari serve`'s `run_in_sandbox` on the VM against the live APIs.

**Done when:** the transcript is in the report; outcomes as in T4.5; no sandbox left.

**Notes (in review):** The live harness runs each reference consumer through the stdio service, using a private Lambo store with the fixture embedder and seeded change kinds, without inference calls. Candidate and baseline use separate v2-only and v1-capable API endpoints: the live endpoint also serves v1, so an unchanged v1 consumer would otherwise appear to pass. The optional trusted session `tool_path` admits absolute normalized directory components and defaults to the previous fixed path; it lets the VM use privately staged dependencies. Each run checks its own sandbox names are gone. The full transcript and route observations are in the handoff report.

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
status:     done
```
Lessons from **what verified runs showed**, not only from failures (bench/README.md, Where lessons come from). Three sources: a failure Clef attributes to `api_change`, and the fix that passed; a behaviour the differential check observed on a pass (boundary duplicates, a token on the final page); a behaviour the passing code had to handle (a short page mid-stream). Each written to Lambo with its change kind, observation, run and check. A failure Clef calls `flaky`, `test_setup` or `unrelated_bug` is never a lesson. Kalari decides what is recorded; the agent can propose, never write directly.

**Done when:** from the payouts reference runs, the expected lesson is written (with the one-payout overlap and the final-page token as observations); its rule says to key records by ID with **the last delivery winning**, never "keep the first" or a bare "dedupe", even though payouts' identical overlaps can't tell them apart (settlements' amended repeats can: bench/README.md); a `flaky` failure writes nothing; a pass with no observed behaviour writes nothing.

**Notes (in review):** `record` takes a run ID and reads the service-owned Evidence store. The T4.6a producer writes `page-observation` with envelope `session_id`, `run_id`, and `change_kinds`, and payload `{source, behaviors}`; it emits only after the candidate and all configured checks, including `differential-v1`, pass. This payload carries observations only, never policy or a check assertion. `Lesson.attachLessonBootstrapChecks(ctx)` adds one generic candidate-output check to `ctx.checks`. It parses the candidate JSONL and trusted final-truth JSONL, rejects duplicate or malformed IDs, and requires exact equality by ID and full record; stale-first output therefore fails whenever the truth contains amended values. `Lesson.verifyAmendedPolicyProvenance` runs a separate fixture check and records its result independently from the candidate run. That fixture uses two changed IDs and one unchanged ID to establish that keep-first differs from final truth while keep-last matches; it never examines candidate output. The recorder requires the independent policy record and the passing candidate-truth `CheckResult`, stores the latter as the Lesson's runnable check, and adds the policy provenance as a separate observation. Payouts' identical overlaps do not prove last-wins, so the lesson does not attribute amended values to the payouts page trace.

Run writes the bounded v1 artifact already collected by `compareRun` to a private host temp file, then copies those exact bytes into each fresh trusted check guest under `kalari-v1-truth.jsonl` beside the candidate artifact. The baseline consumer runs once; the same artifact drives both the differential result and the reusable candidate-versus-final-truth check. `Run` rejects the reserved filename as the candidate output name. The fake backend reads the staged truth source and asserts byte-for-byte equality with the v1 artifact, and checks that reserved-name refusal has no runner or resolver effects. The Lesson fixture executes the generated checker against correct and stale-first candidate outputs, records a passing RunRecord with its check and `differential-v1`, verifies policy provenance separately, and resolves its lesson through T4.4.

Legacy `verified-behavior` evidence remains the failure/fix input and includes its complete check plus optional `failed_run_id`. The linked failure must precede the passing fix in evidence order and both run envelopes must index the same change kind. Clef classifies the actual earlier failing run; only `api_change` can add failure-derived text. `flaky`, `test_setup`, and unrelated diagnoses write nothing. Empty behavior passes write nothing. A single per-service `Write` value owns the mutex shared by every `record_lesson` handler. It serializes validation, append, and receipt-backed resource/constraint/observation writes. If a graph write fails after evidence append, retry validates and reuses the identical typed lesson record, then repeats the same deterministic Lambo derive inputs and waits for their receipts; it does not append duplicate lesson evidence.

The build fixture covers candidate-versus-truth acceptance/rejection, separate policy provenance, recorded page observations, retry after a failed graph write, concurrent calls sharing one writer, evidence order and shared change kind, flaky/no-observation no-write cases, API-change fix, and T4.4 evidence resolution. The production page-observer seam and benchmark tracer belong to T4.6a and are not edited by this task. The call-level regression also records an actual empty `page-observation` while valid policy provenance exists and confirms it produces no lesson, write, or typed lesson evidence. `recordUnlocked` now skips empty page behavior lists before applying policy provenance, so the fixture cannot be mistaken for an observed page behavior.

---

### T4.6b: Trusted retry observations ★
```yaml
requires:   [T4.6, T5.2a]
fixture-ok: yes
size:       M · frontier
owns:       Kalari/Tools/Run.lean (observer and trace validation), Kalari/Tools/Lesson.lean, bench/apis/payouts/server.py (trusted trace only), bench/tests/quirks.sh (observed trace case)
status:     in-review
```
Extend the trusted payouts observer for B5 without weakening the existing complete-chain validation. The evidence sequence is a 429, the immediately subsequent request with the same trusted full-request fingerprint, a successful response, a complete cursor chain, and a passing candidate with every check and the differential comparison passing. The fingerprint, not the cursor alone, establishes request identity. Traces carry no raw request or token. A changed request, ambiguous sequence, failed run or missing differential pass cannot emit a retry observation.

Keep the observed fact separate from the transferred lesson and its runnable check. The observation claims only what the trace proves; it does not claim that the consumer honoured the retry delay unless trusted timing evidence establishes that too. Add the retry behaviour to typed lesson publication and recall-resolution fixtures.

**Done when:** the real payouts reference consumer and grader produce a verified B5 trace and `record_lesson` publishes a non-empty typed retry lesson; a mismatched fingerprint or unverified traversal publishes nothing; malformed and branched traces fail closed; `./tools/check.sh` passes.

**Notes (in review):** The trusted trace holds one event per traced request, in response-completion order. A page event carries `status`, the incoming cursor digest, the full-request fingerprint digest, a `retry` flag and the page. A 429 event carries `status`, the incoming cursor digest, the fingerprint digest, `retry: false` and `retry_after`, and no page. A traced request that is not a served v2 page carries its status and the incoming cursor digest, and no page. That covers a 400, a 404, a 410 and a base-handler status such as 501 for another method. A request from another client gets a 403 and leaves no trace event. The 429 reply and its append happen under the same lock as a page. The bound and the overflow marker are unchanged, and the retry journal is untouched.

The B5-off raw trace lines changed. Every page event now carries `status`, `fingerprint` and `retry`, with B5 on or off. The raw bytes differ from the old trace. The parsed facts do not. Old-shape lines, without those fields, still parse to the old facts. The B5-off observed trace parses to the same facts.

`pageObservations` parses each line by status. Only a 200 page and a 429 throttle are valid, so a traced 400, 404 or 410 fails closed. A 429 must carry no page field, must be followed immediately by a 200 with the same request digest and the same fingerprint digest marked as the retry, and at most one may appear. A page marked `retry` with no 429 ahead of it fails. A request must be empty or a 32-hex digest, and a response and a fingerprint must be a 32-hex digest. A page over the server's 100-record cap fails before the duplicate and overlap scans. A trace with no 429 parses as before and keeps its old facts. A valid retry adds `rate_limit_retry`. A mismatched fingerprint, a missing retry, a wrong cursor across the retry, a 429 whose cursor does not repeat the previous response, a 400 between the 429 and the retry, two throttles, an orphaned throttle, a branch, a repeated cursor or an unterminated chain fails closed. A passing run with such a trace returns an error before any evidence is appended.

`Lesson.descriptions` maps `rate_limit_retry` to "The API answered one request with HTTP 429 and a retry delay, and the identical request then succeeded." The sentence claims no wait. The lesson's runnable check stays the candidate-versus-final-truth check. The build fixture also gives a run a weaker passing check before the truth check and asserts the lesson takes the truth check. The build fixture publishes that lesson, resolves its reference through T4.4, and shows that a failed run and a run without a differential pass publish nothing.

`Run.exercise` covers the parser cases and the observer lifecycle. The observer fixture includes a run whose lesson check passes and whose differential fails, and asserts it emits no page observation. `realObserver` starts the real payouts server with B5 on, runs the real `correct` consumer and the real grader, and asserts the trace holds the 429 and the matching retry. `bench/tests/quirks.sh` asserts one 429, the matching request digest and fingerprint, the retry flag, the joined cursor chain, no raw cursor, the intervening 400 and 501 events and the B5-off facts.

The done-when has two parts. The build's `realObserver` proves the real payouts server and the real reference consumer produce a verified trace. The build fixture proves a synthetic page observation reaches `record_lesson` and publishes the retry lesson. The single chain from the real trace through the production service to `record_lesson` is T4.7c's done-when. The production service still rejects observer configuration.

---

### T4.7a: Wire the Kalari MCP service ★
```yaml
requires:   [T4.3, T4.4, T4.5, T4.6]
fixture-ok: yes
size:       M · frontier
owns:       Kalari/Main.lean, Kalari/Service.lean
status:     done
```
Wire the five MCP tools through a shared trusted session, evidence store, and lesson writer. Keep model-controlled inputs separate from trusted runtime setup.

**Done when:** the service dispatches all five tools through the executable stdio path against offline fixtures, validates trusted configuration and cleans up child resources on shutdown.


The executable serves a single trusted session with shared evidence and writer; model arguments cannot override trusted paths and limits. Observer configuration is rejected until exclusive guest source isolation can be verified. The offline executable self-test reaches all five routes over stdio and verifies EOF shutdown; sandbox and lesson checks cover refusals, not successful end-to-end runs. The fixture uses the same dispatcher with injected backends.

**Remediation notes:** Startup validation rejects dot-prefixed artifacts, empty baseline executables, NUL-containing baseline arguments, zero or over-limit baseline caps, absolute baseline command arguments outside the baseline workspace, workspace paths that resolve to files, trusted executable/spec paths that resolve to directories, and overlapping workspace roots; fixture cases cover each. The executable stdio path passes successful `run_in_sandbox` and `record_lesson` calls through the shared dispatcher, injected runtime, shared evidence store and shared Lambo-backed lesson writer. A real local fake Lambo child completes receipt exchanges and is reaped by the same cleanup wrapper used for service stdio EOF; an error-path fixture also proves cleanup runs when service work throws. `./tools/check.sh` and `.lake/build/bin/kalari --offline-self-test` pass.

---

### T4.7b: Offline OpenCode arm fixture
```yaml
requires:   [T4.7a]
fixture-ok: yes
size:       S · mid
owns:       bench/kalari-arm/
status:     done
```
The trusted offline fixture checks standalone configuration, five fake tool events, transcript redaction and grader cleanup. Live mode stays disabled.

---

### T4.7: Kalari with OpenCode ★
```yaml
requires:   [T4.7b]
fixture-ok: no
size:       S · mid
owns:       bench/kalari-arm/
status:     done
```
The Kalari arm's setup: OpenCode 2.2.5 with `kalari serve` as its MCP server (and `microsandbox-mcp` removed, so code runs only through `run_in_sandbox`), host shell denied, `--standalone` and per-run `XDG_*` directories. One upgrade-one session end to end on the VM, **not counted as a benchmark run** (the pair isn't frozen until T5.3).

Use one bounded live session with a stated budget, check the first case cost, and stop if it would exceed the budget.

**Done when:** the session's transcript shows the five tools called, a run graded by the hidden grader, the measures recorded; no process or sandbox left.

**Notes (in review; incomplete):** One live payout session ran; its sanitized tool events and measured usage are in `bench/kalari-arm/results/`. The agent called `what_changed`, `blast_radius`, and `recall_lessons`, but did not call `run_in_sandbox` or `record_lesson`. Blast-radius search failed because `rg` was absent from the staged tools. The grader guest exited successfully, but host grading failed because its data file was not staged; the output was lost during cleanup. No hidden verdict, first-v2 grade or time-stuck measure is available. Three tracked run sandboxes and the grader sandbox were removed; no session process or sandbox remained. The runner now preflights `rg` and grader data and preserves a private grader output. The account-wide cost estimate at the recorded model prices was about $0.411 and may include unrelated usage.

A subsequent bounded retry was interrupted by an unknown SIGTERM source before evidence or usage deltas were written; inference may have started and its cost is unknown. No session process or sandbox remained. See `bench/kalari-arm/results/interrupted-retry.md`. The runner now saves usage-before counts and preserves sanitized partial events and measures on a handled signal; the offline fixture exercises this path. The five-tool transcript, hidden grade and complete measures remain unmet.

Under a fresh $5 allowance, four further attempts produced no Kalari tool calls or candidate output. The first exposed a startup race; the second found a noncanonical staged aashaan path; after both were fixed, the third hit its 60-second watchdog and the fourth received a truncated provider stream. The guarded setup now passes a zero-spend standalone OpenCode fake-provider check with all five tools, and a timed streaming test. The four account-wide deltas sum to about $0.3573 at recorded rates, including concurrent benchmark activity; no session sandbox remained. Details and sanitized tool transcripts are in `bench/kalari-arm/results/fresh-budget-attempts.md`.

A diagnostic retry with identity encoding called all five Kalari tools and the hidden grader passed 2,431 of 2,431 records. The verified sandbox run passed both candidate-v1-truth and differential-v1 checks; `record_lesson` returned no lesson. The session lasted 20.233 seconds and its account-wide usage delta was 83,885 input and 2,837 output tokens (about $0.0143 at recorded rates). Four tracked sandboxes were removed and no session process remained. Retained events show two consumer runs (candidate v2 and baseline v1) and zero time stuck; they support a right-first-time pass by inference from the single write, subsequent run, no later candidate write, and final grade. No first-v2 snapshot was retained. The provenance, sanitized transcript and recorded measures are in `bench/kalari-arm/results/`.

**Cleanup evidence fix:** Cleanup command failures and failed post-cleanup verification are now captured in `cleanup.json` and `measures.json`. The runner writes and announces the sanitized transcript and measures before exiting nonzero on cleanup failure. An offline fixture injects a cleanup failure and checks that the five-tool transcript and measures survive while the run fails closed. `bench/kalari-arm/test-offline.sh` passes. No inference was run.

---

### T4.7c: Wire and rehearse the retry memory path ★
```yaml
requires:   [T4.6b, T4.7a, T4.7]
fixture-ok: no
size:       M · frontier
owns:       Kalari/Service.lean, Kalari/Tools/Run.lean (production observer wiring only), bench/kalari-arm/, tests/live/observer.sh
status:     not-started
```
The production service currently rejects observer configuration and constructs `Run.Context` without an observer, so a tool call or an offline observer fixture cannot establish the learning path. Wire the observer only after verifying exclusive guest-source isolation; keep refusing configurations that cannot establish it. Rehearse the real service and sandbox route without inference, using a private Lambo fixture embedder and no external model calls.

Demonstrate the complete cross-upgrade path through the actual dispatcher: a verified payouts run publishes the retry lesson; settlements recalls it as required; the trusted checker is rebound to the settlements artifact rather than retaining the payouts filename; a correct settlements consumer passes; a partial-output skip-on-429 consumer fails the recalled and differential checks. Agent and grading HTTP retry counts remain separate from sandbox runs.

**Done when:** the no-inference transcript shows observe → publish → recall → enforce end to end, including a non-empty published lesson and the failing partial-output case; unproven guest-source isolation still fails closed; every started process and sandbox is removed; the test and sanitized transcript are committed.

---

## Exit Criteria

- [ ] An agent can upgrade a consumer through the five tools, with every claim backed by the evidence store.
- [ ] Lessons are written from verified runs only, failures and observed behaviour alike.
