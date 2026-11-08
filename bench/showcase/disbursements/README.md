# The showcase scenario: disbursements (manufactured)

One upgrade, run by OpenCode 2.2.5 alone (the reference setup) and by OpenCode 2.2.5 with
Kalari, on models that can also be **self-hosted**. This suite is **not** one of the frozen
pair and its behaviour is **not sourced from a real vendor's API**: it is a manufactured
scenario built to demonstrate the differential check. The agent-facing docs are true sentence
by sentence; the trap is a gap, not a lie.

## The scenario

`disbursement-sync` moves off `GET /v1/disbursements` (one response, every record) onto
`GET /v2/disbursements` (a windowed export). In v2:

- Every response carries a `cursor`, the last one included; `drained` says the export has
  caught up.
- Windows overlap: each window begins with the record that ended the previous one, so that
  record is delivered twice.
- **The manufactured behaviour:** the first delivery of a repeated record (it closes a window)
  carries a window-edge amount — the amount before a late 1,250-cent adjustment. The
  re-delivery (it opens the next window) carries the final amount. Every other record is
  delivered once, final. v1 serves final versions only.
- `POST /v2/verify` is a documented self-check that honestly checks ids only: every id exactly
  once, nothing about field values.

The docs describe the overlap and say "deduplicate on `id`" and never say which delivery of a
repeated record is current. The natural consumer deduplicates keeping the **first** delivery:
the id set is exactly right, the count is exactly right, `POST /v2/verify` passes, the process
exits 0 — and 23 of 2,341 records carry amounts that were never paid. Only a record-by-record
comparison against v1 exposes it, and that is exactly the check Kalari runs unasked
(`differential-v1`: none missing, none extra, each exactly once, each equal to v1's version).

`QUIRKS.md` maps every behaviour to server code and docs. The hidden grader
(`grader/grade.py`) compares against the final versions. `reference/` holds the offline
consumers (`correct.py` passes; `keep_first.py` is the silent failure: exit 0, 2,341 records,
23 mismatched).

## Where it runs

Two microVMs on the benchmark VM, exactly as `bench/apis/deploy.sh` runs the frozen APIs:
`api-disbursements-live` (`:18082`, v1 on) and `api-disbursements-grading` (`:18092`, v1
retired with 410), each `--net-default-egress deny`, ports published on the VM's public IP.
Both stay up for the demo.

```bash
# one reference-arm session (OpenCode alone, fresh session, the frozen prompt)
bench/showcase/disbursements/_harness/run-reference.sh --repeat 1 --model glm-5.3-flash --label glm-r1

# one Kalari-arm session (same model, Kalari's MCP tools, enforced checks)
bench/showcase/disbursements/_harness/run-kalari.sh --repeat 1 --model glm-5.3-flash --label glm-r1
```

Results land in `runs/reference/` and `runs/kalari/` with sanitized transcripts beside them.
List prices used for cost (per million tokens, cached input counted as input, no discount):
MiMo V2.6 Flash 0.10/0.25, GLM 5.3 Flash 0.10/0.35, Qwen3.8 27B 0.15/1.00, Muse Glimmer 30B
0.25/1.00, Qwen3.8 Flash Next 0.10/0.20, DeepSeek V4.1 Flash 0.15/0.60.

## Every run

| Arm | Model | Run | Verdict | Lost | Dup | Changed | Wall s | Cost USD | Differential fired | Files |
|---|---|---|---|---|---|---|---|---|---|---|
| reference | DeepSeek V4.1 Flash | r1 | PASS | 0 | 0 | 0 | 61 | not measured | — | [json](runs/reference/deepseek-r1.json) |
| reference | DeepSeek V4.1 Flash | r2 | PASS | 0 | 0 | 0 | 221 | 0.107389 | — | [json](runs/reference/deepseek-r2.json) |
| reference | DeepSeek V4.1 Flash | r3 | PASS | 0 | 0 | 0 | 37 | 0.056516 | — | [json](runs/reference/deepseek-r3.json) |
| reference | MiMo V2.6 Flash | r1 | FAIL | 2341 | 0 | 0 | 10 | 0.004570 | — | [json](runs/reference/mimo-r1.json) |
| reference | GLM 5.3 Flash | r1 | FAIL | 0 | 0 | **23** | 65 | 0.028190 | — | [json](runs/reference/glm-r1.json) |
| reference | GLM 5.3 Flash | r2 | PASS | 0 | 0 | 0 | 47 | 0.016175 | — | [json](runs/reference/glm-r2.json) |
| reference | GLM 5.3 Flash | r3 | FAIL | 0 | 0 | **23** | 139 | 0.035607 | — | [json](runs/reference/glm-r3.json) |
| reference | Qwen3.8 27B | r1 | FAIL | 0 | 0 | **23** | 38 | 0.064113 | — | [json](runs/reference/qwen27b-r1.json) |
| reference | Muse Glimmer 30B | r1 | FAIL | 0 | 0 | **23** | 26 | 0.082224 | — | [json](runs/reference/muse-r1.json) |
| kalari | GLM 5.3 Flash | r1 | PASS | 0 | 0 | 0 | 36 | 0.008561 | nothing to catch (correct first consumer) | [json](runs/kalari/glm-r1.json) |
| kalari | GLM 5.3 Flash | r2 | FAIL | 0 | 0 | 23 | 62 | 0.019734 | yes, "23 changed" twice; model did not fix | [json](runs/kalari/glm-r2.json) |
| kalari | GLM 5.3 Flash | r3 | PASS | 0 | 0 | 0 | 57 | 0.014646 | **yes: "23 changed" then "0 changed" after the fix** | [json](runs/kalari/glm-r3.json) |
| kalari | Qwen3.8 27B | r1 | FAIL | 0 | 0 | 23 | 72 | 0.077535 | yes, 9 trusted runs, never fixed | [json](runs/kalari/qwen27b-r1.json) |
| kalari | Muse Glimmer 30B | r1 | FAIL | 0 | 0 | 23 | 36 | 0.088541 | yes, once; never fixed | [json](runs/kalari/muse-r1.json) |

Transcripts sit beside every JSON with the same base name. Sessions were capped at 1200 s
(reference) and 600 s (Kalari); none hit the cap. Spend across all 14 sessions: about
0.65 USD at list price.

## What the runs show

**The reference setup ships silent corruption.** On GLM 5.3 Flash (2 of 3 sessions), Qwen3.8
27B and Muse Glimmer 30B (1 of 1 each), the agent deduplicated keeping the first delivery,
verified with the API's own documented self-check (`POST /v2/verify`: every id exactly once),
and ended the session reporting success — while 23 records carried amounts that were never
paid. Nothing in its setup ever compares records against v1. The final messages quote the
id-level check as authoritative; see `runs/reference/glm-r1.transcript.jsonl` for a session
that declares the sync verified with 23 wrong amounts.

**Kalari catches it every time it exists.** In every Kalari session whose consumer kept the
first delivery, the enforced differential reported exactly `0 missing, 0 extra, 0 duplicates,
23 changed` — in `glm-r3` the agent then fixed the consumer and the same check reported
`0 changed` before the session ended: the catch-and-fix loop the product claims. In `glm-r2`,
`qwen27b-r1` and `muse-r1` the check fired and the model still shipped the broken consumer:
the failure is surfaced and recorded in the run's evidence, which is the difference from the
reference arm, where nothing surfaces at all.

**The boundary, stated plainly.** On DeepSeek V4.1 Flash the arms do not diverge: in all
three reference sessions the model spontaneously compared its output against v1 record by
record and corrected itself ( transcripts show `matches v1 exactly: False` mid-session and a
flip to keeping the last delivery). A strong model self-administers the differential; on it,
Kalari's measured edge is enforcement, containment and cost, not pass rate. MiMo V2.6 Flash
could not drive the agent harness at all (malformed tool calls; a loud failure, not a silent
one). The divergence claim holds for the mid tier — the models that can also be self-hosted,
which is the economical way to run migrations, and exactly the tier where an enforced check
earns its keep.

**Correction (0.2.3 repeats are canonical).** The rows above ran on an earlier harness and an earlier Kalari release, where the reference agent shared an OS user with the API microVMs. In DeepSeek r2 and r3 it reached inside `api-disbursements-live` through microsandbox-mcp and read the server's source, so those two passes are not clean evidence; r1 had no such access and passed by comparing amounts against v1. With that access removed (0 guest calls in 45 sessions), DeepSeek alone failed disbursements 4 of 5, and the one pass was the one session whose tool calls compared amounts against v1. The suite, model, OpenCode version and reasoning effort did not change, and no session hit its cap. MiMo's "could not drive the harness" above was one run; in the repeats it completed every session.

## Honesty notes

- The scenario is manufactured and labeled as such; the agent-facing docs contain no false
  sentence. The trap is that they never say which delivery of a repeated record is current,
  and the API's own self-check honestly covers ids only.
- No agent output was scripted. Every row above is a real session; the transcripts are the
  raw (sanitized) OpenCode event logs.
- The harness wrappers are adapted copies of the frozen harnesses
  (`bench/harness/`, `bench/runs/kalari/_harness/`); no frozen file was edited, and
  `bench/runs/kalari/_harness/verify-frozen.sh` runs before every Kalari-arm session.
