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
status:     not-started
```
`ChangeSource` over the `vimanam` CLI: two spec versions (files or Git refs) in, `ChangeFact`s out from JSON contract v2, plus the focused context (`--context --max-tokens`) for the agent. OpenAPI, GraphQL and protobuf. A Vimanam error is reported with its stderr, never swallowed.

**Done when:** both benchmark diffs from `testdata/vimanam/` parse into the expected change facts; a malformed spec gives a readable error.

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
status:     not-started
```
`DecisionClient` for the System One format at `/v1/systemone`, through `curl` with the key on stdin (`Examples/Curl.lean`). The three questions as typed functions: `failureCause` (a `choice`: api_change, test_setup, flaky, unrelated_bug, with probabilities and confidence), `callsChangedOperation` (a `noul`), `lessonApplies` (a `noul`). Input trimmed to the model's limit before sending (over-length is a 422, not a truncation). 429 retried after `Retry-After`; 502–504 with backoff.

**Done when:** the recorded replies parse into the typed answers; an over-length input is trimmed in a test; no key in any argument (the test checks the argv).

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
status:     not-started
```
From a change fact to the places in the consumer that call the changed operation: the endpoint path (REST), the field (GraphQL), the RPC name (gRPC), searched with `rg` through the process runner. Each hit with file, line and the line's text. Uncertain hits are confirmed by Clef's `callsChangedOperation` (T3.3), kept with their probability, and shown as uncertain, never counted.

**Done when:** on both benchmark workspaces, the v1 call sites are found with no false hits; a fixture with a decoy (the path in a comment, a similarly named field) shows the decoy as uncertain.

---

## Exit Criteria

- [ ] Vimanam, Lambo and Clef reachable through their interfaces, offline and live.
- [ ] The blast radius found by search, links written to Lambo.
