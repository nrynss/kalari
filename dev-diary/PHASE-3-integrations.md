# P3: Integrations

Kalari's clients for the tools it drives: Vimanam for what changed, Lambo for memory, Clef for the judgement calls, and its own code search for the blast radius. Each runs against `testdata/` offline; each `b` task proves it live.

Read first: [`research/lambo.md`](research/lambo.md), [`research/vultr-inference.md`](research/vultr-inference.md) (Clef's answer shape, limits), [`../docs/lean.md`](../docs/lean.md) (JSON-RPC, Outbound HTTPS).

Tracks A (Vimanam), B (Lambo), C (Clef) and D (search) touch different files and run in parallel.

---

### T3.1: Vimanam runner ★
```yaml
requires:   [T1.5, T0.3]
fixture-ok: yes
size:       S · mid
owns:       Kalari/Vimanam.lean
status:     done
```
`ChangeSource` over the `vimanam` CLI: two spec versions (files or Git refs) in, `ChangeFact`s out from JSON contract v2, plus the focused context (`--context --max-tokens`) for the agent. OpenAPI, GraphQL and protobuf. A Vimanam error is reported with its stderr, never swallowed.

**Done when:** both benchmark diffs from `testdata/vimanam/` parse into the expected change facts; a malformed spec gives a readable error.

Notes:

`make` takes a runner `(argv, timeoutMs, outputCap) → IO Proc.Result` and returns a `ChangeSource`. `diff` is `vimanam diff --format json <old> <new>`. The two paths are last. `vimanam diff --help` on the binary on PATH (1.7.0) prints `vimanam diff [OPTIONS] [OLD] [NEW]`, so options come before the paths. That help does not list `--context` or `--max-tokens`. Those flags are options too, so focused context is `vimanam diff --format json --context --max-tokens <n> <old> <new>`. No git-ref flags. The paths are the ones the recordings were made from: the payouts OpenAPI pair and the settlements GraphQL pair. A protobuf spec uses that same argv. There is no protobuf recording.

`focusedContext` is a function in this module. It is not a field on `ChangeSource`. It runs the context argv and returns the process stdout. The recordings have no context body, so it does not parse one, and the checks do not invent one. `#guard` checks that the context argv contains `--context` and `--max-tokens`.

Stdout on exit 0 is JSON contract v2. `changes[]` is decoded with derived `FromJson` on `ChangeFact`, which keeps `id` and `kind` and ignores every other key. `ChangeFact` is not widened. A non-zero exit is `Except.error`. The string is `vimanam: exit <code>: <stderr>`, so a stub with exit 1 and stderr `error: not a spec` surfaces `not a spec`. It is not `failed` and it is not an empty list. Timeout and output cap are errors too, not a parsed diff.

The diff budget is 30000 ms and 1048576 bytes. The help names no other limit. Focused context uses the same budget. `live` binds `Proc.run` with an explicit `PATH` and `inheritEnv := false`, because the child environment is empty otherwise. The `#eval` replays `payouts.json` and `settlements.json`. It reads the files. It does not spawn `vimanam` and it does not call `live`. A recording the runner was not given throws, which fails the build.

Surprises:

- The `vimanam` on PATH is 1.7.0. Its `diff --help` has no `--context` and no `--max-tokens`. The flag order used is still that help's order: options, then the two paths.
- OpenAPI and GraphQL are the two benchmark files. The argv does not change with the format. Protobuf would be the same command. Nothing in `testdata/vimanam/` is a protobuf diff.

---

### T3.1a: Vimanam runner on 2.1.0
```yaml
requires:   [T3.1, T0.6]
fixture-ok: yes
size:       S · mid
owns:       Kalari/Vimanam.lean, testdata/vimanam/
status:     done
```
Move the runner and its checks from the 2.0.0/`main` recordings to `testdata/vimanam/2.1.0/` (T0.6). Handle `operation_moved` (its old and new paths, with the inner changes attributed to the new path). The checks assert **`pagination_changed` on both benchmark specs**, with the IDs recorded. Then delete the 2.0.0 recordings that nothing replays any more (keep `probes/` as history).

**`--context` is GraphQL-only in 2.1.0.** For the REST upgrade, choose and record another source of focused context for `what_changed` (for example Vimanam's OpenAPI rendering with a token budget, `--overview-max-tokens`), or show the change facts alone, and say why.

**Done when:** the checks replay the 2.1.0 recordings and see `pagination_changed` on both specs; a moved operation's facts parse; the REST context choice is recorded in `research/vimanam.md`.

Notes:

The checks replay `testdata/vimanam/2.1.0/`. They read the files. They do not spawn `vimanam`. `ChangeFact` stays `id` and `kind`. Derived `FromJson` ignores every other key, so a 2.1.0 object still parses. No path field was added.

Payouts is 11 facts. `pagination_changed` is `vc2_ff47bb628a187fbe4f28e53ef03a6231e2b22188bc0e84446306104ba37029d8`. `operation_moved` is `vc2_a604d335c9ac1b47b192a9f46eca61773f4ccd1db93a772f71808fbdb36b933c`. Its `details.old_path` is `/v1/payouts` and its `native.path` is `/v2/payouts`. The pagination fact's `native.path` is `/v2/payouts`, the new path. Every change that has a string `native.path` names `/v2/payouts`. The decoded list contains both kinds. Settlements is 6 facts. Its `pagination_changed` is `vc2_25e58920a86bef7532571b31025312531a0b34db9a10e132ca13c4bea27f795d`.

`--context` is GraphQL-only in 2.1.0. An OpenAPI diff fails with "--context is GraphQL-only; OpenAPI and protobuf diffs do not support it". `--context` renders Markdown, so it is not combined with `--format json`. `diff` has no other focused-context flag. `--overview-max-tokens` is a conversion flag, not a `diff` flag. The `vimanam` on PATH is 1.7.0. Its `diff --help` lists neither `--context` nor `--overview-max-tokens`. A GraphQL pair uses `vimanam diff --context --max-tokens <n> <old> <new>`, matching `settlements.context.md` (2000). REST focused context is the change facts: the same JSON diff, and the argv does not contain `--context`.

The 2.0.0 files stay. `Kalari/Fake.lean` still replays `testdata/vimanam/payouts.json` and `testdata/vimanam/settlements.json`, and this task does not edit Fake. `probes/` stays. A 2.0.0 file is deleted only once nothing in the repo names it.

Surprises:

- 2.1.0 refuses `--format json` together with `--context`. The GraphQL context argv is Markdown.
- `type_added` on the payouts diff has `native.path` null. The moved operation and the inner changes that name a path all name `/v2/payouts`.

---

### T3.2: Lambo client ★
```yaml
requires:   [T1.5, T0.4]
fixture-ok: yes
size:       M · frontier
owns:       Kalari/Lambo.lean
status:     done
```
`MemoryClient` over a child `lambo serve` (MCP over stdio): start it with Kalari's config, `initialize`, then `lambo_derive`, `lambo_inspect`, `lambo_recall`, `lambo_stats` (with a receipt and `wait_ms` when the next read needs the write). Kalari is the single writer under one stable agent ID. The change kind is a `resource`; a lesson a `constraint` `depends_on` it; a run an `observation` `depends_on` the lesson (research/lambo.md, How Kalari uses it). Lessons are found by `lambo_inspect` on the change kind, never by recall rank alone.

Replays `testdata/lambo/` (Lambo 0.9.0; its README lists what the client must handle). Read a write's outcome from the next response's `write receipts` block or from `lambo_stats` with the receipt. A contradicted lesson carries no warning on `lambo_inspect`, only an incoming `Contradicts` edge: the client checks each lesson it inspects for one.

**Done when:** against the recorded transcripts: a lesson written and then found by inspecting its change kind; a contradicting outcome written `against` it shows as stale; the child is stopped cleanly on shutdown and restarted if it dies.

**Notes:** `Kalari.Lambo` retains the typed client for concept types, citations, receipt waits, and stale lesson status. Its frozen `MemoryClient` adapter maps string writes to observations, returns an applied created/matched concept ID (or an error), returns validated direct dependent IDs from `inspect`, and returns hit IDs from `recall`. `MemoryAdapter` exposes both the owning typed `Client` and its `shutdown` operation. Lesson classification requires the exact terminal `[Constraint]` or `[Constraint, candidate]` suffix, so free-form mentions do not qualify. Build-time checks replay receipt and contradiction transcripts through actual JSON-RPC child processes, assert outgoing concept arguments and matching receipt IDs, find a lesson through change-kind inspection, inspect an incoming contradiction, and exercise exact adapter concept IDs, clean shutdown, clean restart, and a forced child exit followed by automatic restart on the next call. Mismatched receipts, malformed or missing recall hit IDs, and malformed or truncated dependent IDs are rejected.

---

### T3.2b: Lambo client, live
```yaml
requires:   [T3.2]
fixture-ok: no
size:       S · mid
owns:       tests/live/lambo.sh
status:     in-review
```
A fresh store, `lambo provision`, the client writing the payouts lesson and three citing runs, then reading it back by change kind, then the Solo promotion after the 60 s age floor and one canonization cycle.

**Done when:** the transcript is in the report; promotion reached Candidate; cost (embeddings) under $0.01.

Notes:

`tests/live/lambo.sh` is not part of the gate. It provisions a fresh SQLite store in a temp directory: Solo, Qwen3 Embedding 4B at 2560, `api_key_env = "VULTR_INFERENCE_API_KEY"`, and `[daemon] gc_interval = 1`. The store path is absolute. It is not a shared `kalari.db`. The client command is `["lambo", "serve"]`. That argv does not pass `--session`, and a stdio serve refuses to start when neither `[[serve.projects]]` nor `[serve] default_session` is set, so the temp toml sets `default_session = "kalari"`.

A temp Lean file outside the repo imports `Kalari.Lambo` and is deleted on exit. It calls `create`, `write`, `lessons`, `inspect`, and `shutdown`. It does not call `lambo_derive` from the shell, and it does not call recall. The change kind `pagination_changed` is a `resource`. The lesson is a `constraint` that `depends_on` that resource. Three citing runs are `observation`s that `depends_on` the lesson id from the write receipt. The lesson text is the payouts rule: stop on the end flag, never on the token's presence or a short or empty page; key records by id, and the last delivery wins, with the benchmark check (exact count against v1, zero duplicate ids, every record equal to v1).

The lesson id is `a22ee882-ddcf-433c-9ecd-ef445f05c8dc`. `lessons` on `pagination_changed` found it, `stale=false`. Right after the writes the label ended `[Constraint]`, admission `status=None`, `eligible=false`, score 1.50, reason `solo score 1.50, needs at least 3.00`. At 75 s it was eligible, score 10.5, status still None, reason `every gate holds; the cycle's batch and ring order decide when`. At 145 s `lessons` returned the label ending `[Constraint, candidate]`, and inspect reported `status=Candidate`. `shutdown` returned and the child was gone.

`/v1/usage` has no dollar amount. `qwen3-embedding-4b` is a row of `usage.current_month.chat_usage`. List price is $0.05 per 1M input tokens. The change-kind write, which also pinned the embedder canary, moved that row by 537 input tokens, $0.00002685. Four times that is $0.00010740, under $0.01, so the lesson and the three runs were written. The whole run moved 2511 input tokens and 0 output tokens, $0.00012555.

The `lambo` already on PATH was 0.8.0. This run put the 0.9.0 release binary first on PATH, checksum checked, so the client still executed `lambo serve`.

Surprises:

- The same canonization cycle promoted the change-kind resource to Candidate. Its label was not read again after that.
- Once the lesson was Candidate, the next gate was Venerable and it was not eligible: coverage 0.18, needs at least 0.30. The recorded run was eligible for Venerable. It had five unrelated observations. This run did not write them. Candidate did not need them.
- `gc_idle_floor` stays 100, so with `gc_interval = 1` the timed GC trigger cannot fire. The serve log says so. Promotion still ran on the canonization interval.
- The first usage delta is the canary plus the change kind, 537 tokens, not the length of the string `pagination_changed`.

---

### T3.3: Clef client
```yaml
requires:   [T1.5, T0.5]
fixture-ok: yes
size:       S · mid
owns:       Kalari/Clef.lean
status:     done
```
`DecisionClient` for the System One format at `/v1/systemone`, through `curl` with the key on stdin (`Examples/Curl.lean`). The three questions as typed functions: `failureCause` (a `choice`: api_change, test_setup, flaky, unrelated_bug, with probabilities and confidence), `callsChangedOperation` (a `noul`), `lessonApplies` (a `noul`). Input trimmed to the model's limit before sending (over-length is a 422, not a truncation). 429 retried after `Retry-After`; 502–504 with backoff.

**Done when:** the recorded replies parse into the typed answers; an over-length input is trimmed in a test; no key in any argument (the test checks the argv).

Notes:

`failureCause`, `callsChangedOperation`, and `lessonApplies` each build one System One body (`model` `clef`, a `state` object, and `questions`) and return `DecisionAnswer`. `failure_cause` is a `choice` with `api_change`, `test_setup`, `flaky`, and `unrelated_bug`. The other two are `noul`, one question per hit or change. A call sends every question it was given and does not split them. More than 64 is an error. `DecisionClient.ask` was not widened. It still takes a recording case name. These three functions are not that field.

The key is read from the environment variable the caller names. It is written only into curl's stdin config. It is not an argv element. `live` binds `Proc.run` with an explicit `PATH` and `inheritEnv := false`, so the child does not inherit the variable. Stdin does not use `setsid`. A curl call does not need a group kill. The checks do not call `live`, do not spawn curl, and do not need a real key.

The JSON body is a temp file (`--data-binary @file`). The trim cap is 1048576 characters, which does not fit in one argv element.

Trim estimate: 4 characters per token. Clef reads 262144 tokens, so `trimToCap` keeps a prefix of at most `262144 * 4` characters. Each state string is trimmed that way before sending. Past the limit the server answers 422 rather than truncating. The over-length request file is elided, so the check parses the response and does not embed the request.

Retry stops after 3 attempts. 429 waits `Retry-After` seconds (`0` waits 0). A missing `Retry-After` uses the same backoff as a server error. 502, 503, and 504 wait `1000 * n` milliseconds, where `n` is how many of those failures have already happened. The check passes a delay that records the wait and returns at once. It does not sleep. A 429 with `Retry-After: 0` and a 502 each succeed on the second attempt. A run of 502, 503, then 504 stops on the third response.

Surprises:

- The over-length request recording is a short note, not the body that was sent. The 422 text is only in the response file.
- Noul numbers in the response bodies are the full values. `index.json` rounds them to three decimals. The decoder uses the body.
- Curl's write-out for that header is `%header{retry-after}`. An absent header is empty.

---

### T3.3b: Clef client, live
```yaml
requires:   [T3.3]
fixture-ok: no
size:       XS · mid
owns:       tests/live/clef.sh
status:     done
```
The three questions on one real failure from the benchmark (the `no_dedupe` payouts run's grader output and its code).

**Done when:** the transcript is in the report; `failureCause` says `api_change`; cost under $0.01.

Notes:

`tests/live/clef.sh` is not part of the gate. It starts the local payouts server with `--v1 off`, runs `bench/apis/payouts/reference/no_dedupe.py`, and grades that jsonl. The consumer printed `synced 2455 payouts`. The grader JSON was `verdict` FAIL, `records` 2455, `unique` 2431, `duplicates` 24. That JSON is the run value. The change text is the B2 fact: the next window starts at the previous window's last payout, and the docs say to deduplicate on id. The code text is `no_dedupe.py`. The call site is line 18, the `/v2/payouts` request. The lesson is `Deduplicate on id.`

A temp Lean file outside the repo imports `Kalari.Clef` and is deleted on exit. It calls `failureCause`, then `callsChangedOperation`, then `lessonApplies`, each with `Kalari.Clef.live` and PATH `/usr/bin:/bin`. The delay is `IO.sleep`. The key is read from `VULTR_INFERENCE_API_KEY` or the keyring. It is not an argument and it is not printed.

`failureCause` returned `api_change`, confidence `0.485748`. Probabilities, in name order: `api_change` `0.614311`, `flaky` `0.019747`, `test_setup` `0.010406`, `unrelated_bug` `0.355536`. `callsChangedOperation` for `no_dedupe_call` was `0.867934`. `lessonApplies` for `b2` was `0.981022`. One call each. The criteria were not changed.

`/v1/usage` has no dollar amount. `clef` is a row of `usage.current_month.chat_usage`. List price is $0.10 per 1M input tokens, and output is not priced. The first call moved `clef` by 533 input tokens and 0 output tokens, $0.00005330. Three times that is $0.00015990, under $0.01, so the other two ran. All three moved 956 input tokens and 0 output tokens, $0.00009560. The counter had moved on the first after-read, so the character estimate was not used.

Surprises:

- The label is `api_change`, but confidence is under 0.5 and `unrelated_bug` is 0.356. The change text is only the overlap sentence. That was not sent again.
- `callsChangedOperation` still put 0.868 on the `/v2/payouts` line, and the dedupe-on-id lesson applied at 0.981, from that same short change text.

---

### T3.4: Code search for the blast radius
```yaml
requires:   [T1.5, T0.3]
fixture-ok: yes
size:       M · frontier
owns:       Kalari/Search.lean, testdata/search/
status:     done
```
From a change fact to the places in the consumer that call the changed operation: the endpoint path (REST), the field (GraphQL), the RPC name (gRPC), searched with `rg` through the process runner. Each hit with file, line and the line's text. Uncertain hits are confirmed by Clef's `callsChangedOperation` (T3.3), kept with their probability, and shown as uncertain, never counted.

**Done when:** on both benchmark workspaces, the v1 call sites are found with no false hits; a fixture with a decoy (the path in a comment, a similarly named field) shows the decoy as uncertain.

Notes:

`search` takes a runner, a confirmer, a `ChangeFact`, an operation, and a consumer root. The operation is separate from `ChangeFact`: REST is the endpoint path, GraphQL is the field, gRPC is the RPC name. `ChangeFact` stays `id` and `kind`. The counted `BlastRadius.change_id` is that id.

`rg --json -F` runs through `Proc.run`. `live` passes an explicit `PATH` and `inheritEnv := false`. Exit 0 and exit 1 (no matches) are parsed. Exit 2, a cap, or empty stdout is an error, not an empty radius. The checks run `rg`. They do not replay a recording, and they do not spawn `vimanam`, `msb`, or `curl`.

The search checks run the `rg` on PATH, and the CI workflow installs the `ripgrep` package because the Ubuntu 26.04 runner image does not ship it.

Source globs are code (`*.py`, `*.go`, and the other source suffixes). Specs and guides are not searched. A GraphQL schema line `settlements(` and the guide's query sample would look like calls.

A line is certain when a match is the call. REST: the path is a whole path, inside a string, on a line that performs a request (`urlopen` on the payouts consumer). GraphQL: the field is a whole name inside a string and the next token is `{` or `(`. gRPC: the RPC name is a whole name in code and the next token is `(`. A line is uncertain when the match is in a comment, or it is only a substring of a longer name, or the line is not the call. Uncertain lines are not in `BlastRadius`.

`CallSite` has no line field. A counted hit's `path` is the file. Its `detail` is the line number, a colon, and the line text, as in `8: ...`.

Uncertain hits go to the confirmer in one call. The checks pass `clefConfirmer` with a stub runner, so `callsChangedOperation` runs and Clef's `live` does not. The stub answers each question with noul `0.25`. The uncertain hit keeps that probability. It prints as `0.250000`.

On `payout-sync`, the only counted hit is `payout_sync.py` line 8, the `/v1/payouts` request. Nothing else is counted. On `settlement-reconcile`, the only counted hit is `settlement_reconcile.py` line 6, the `settlements` field in the query. Lines 1, 22, 24, 26, and 28 name `settlements` and stay uncertain. The decoy counts the `/v1/ledger` request once. The comment and the field `/v1/ledgerItems` are uncertain. The gRPC fixture counts `stub.GetLedger(ctx, req)` once.

Surprises:

- `ChangeFact` cannot name the path or the field, so the operation is a separate argument. The search does not re-parse a Vimanam diff and does not spawn `vimanam`.
- `rg` exit 1 means no matches. Treating it as a hard error would fail a consumer that does not call the operation.
- The settlements schema and the developer guide both contain `settlements(`. They are not the consumer. The search stays on source files so those lines are not counted.
- `String.get?` in this toolchain is deprecated. The neighbour scan uses `String.Pos.Raw.get?`.

---

## Exit Criteria

- [ ] Vimanam, Lambo and Clef reachable through their interfaces, offline and live.
- [ ] The blast radius found by search, links written to Lambo.
