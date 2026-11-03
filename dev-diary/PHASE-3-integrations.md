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

### T3.2: Lambo client ★
```yaml
requires:   [T1.5, T0.4]
fixture-ok: yes
size:       M · frontier
owns:       Kalari/Lambo.lean
status:     not-started
```
`MemoryClient` over a child `lambo serve` (MCP over stdio): start it with Kalari's config, `initialize`, then `lambo_derive`, `lambo_inspect`, `lambo_recall`, `lambo_stats` (with a receipt and `wait_ms` when the next read needs the write). Kalari is the single writer under one stable agent ID. The change kind is a `resource`; a lesson a `constraint` `depends_on` it; a run an `observation` `depends_on` the lesson (research/lambo.md, How Kalari uses it). Lessons are found by `lambo_inspect` on the change kind, never by recall rank alone.

Can start against the 0.8.0 transcripts if T0.4 is still blocked; the orchestrator decides.

**Done when:** against the recorded transcripts: a lesson written and then found by inspecting its change kind; a contradicting outcome written `against` it shows as stale; the child is stopped cleanly on shutdown and restarted if it dies.

---

### T3.2b: Lambo client, live
```yaml
requires:   [T3.2]
fixture-ok: no
size:       S · mid
owns:       tests/live/lambo.sh
status:     not-started
```
A fresh store, `lambo provision`, the client writing the payouts lesson and three citing runs, then reading it back by change kind, then the Solo promotion after the 60 s age floor and one canonization cycle.

**Done when:** the transcript is in the report; promotion reached Candidate; cost (embeddings) under $0.01.

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
status:     not-started
```
The three questions on one real failure from the benchmark (the `no_dedupe` payouts run's grader output and its code).

**Done when:** the transcript is in the report; `failureCause` says `api_change`; cost under $0.01.

---

### T3.4: Code search for the blast radius
```yaml
requires:   [T1.5, T0.3]
fixture-ok: yes
size:       M · frontier
owns:       Kalari/Search.lean, testdata/search/
status:     claimed:grok-impl
```
From a change fact to the places in the consumer that call the changed operation: the endpoint path (REST), the field (GraphQL), the RPC name (gRPC), searched with `rg` through the process runner. Each hit with file, line and the line's text. Uncertain hits are confirmed by Clef's `callsChangedOperation` (T3.3), kept with their probability, and shown as uncertain, never counted.

**Done when:** on both benchmark workspaces, the v1 call sites are found with no false hits; a fixture with a decoy (the path in a comment, a similarly named field) shows the decoy as uncertain.

---

## Exit Criteria

- [ ] Vimanam, Lambo and Clef reachable through their interfaces, offline and live.
- [ ] The blast radius found by search, links written to Lambo.
