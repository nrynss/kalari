# Kalari arm preparation

`prepare.py` creates an isolated OpenCode 2.2.5 configuration for a trusted,
previously prepared Kalari session. It registers only `kalari serve`, exposes
its five tools individually, denies the host shell and web, and creates private
per-run XDG directories. It makes no network or inference calls.

```
python3 bench/kalari-arm/prepare.py --directory /absolute/new-run-dir \
  --kalari /absolute/path/kalari --config /absolute/path/config.json \
  --session /absolute/path/session.json
```

The caller must set `OPENCODE_CONFIG` to the generated `opencode.json` and
`XDG_DATA_HOME`, `XDG_STATE_HOME`, and `XDG_CACHE_HOME` to the corresponding
subdirectories, and run OpenCode with `--standalone`. The session's trusted
workspace, baseline, checks, evidence, limits, API allowlist, aashaan, private
Lambo store and pinned tools must be prepared separately. The inference key
belongs in the environment, never in these files. See `tests/live/run.sh` for
trusted-session construction and private dependency staging.

The service currently rejects observer configuration and does not wire the
observer into its run context; an IP probe alone cannot make a page observation
trusted. `record_lesson` may still be called, but a call is not evidence that a
lesson was published.

`session.py` prepares separate candidate, baseline, check, and evidence
workspaces plus a private fixture-embedder Lambo configuration. Provision and
seed that Lambo store before starting the service, as in `tests/live/run.sh`.
`grade.sh` runs a final candidate in a uniquely named, network-restricted
microVM and returns its JSONL for the host-side hidden grader in
`bench/graders/grade.py`; its trap removes only that sandbox. `summarize.py`
extracts tool names and token counts from OpenCode events without printing tool
contents. Raw events may contain private data and must be reviewed and redacted
before a transcript is published.

A session budget must include both OpenCode and Clef. Usage is checked after
the first case; it is not a request-time spending cap.

`runner.py --offline-fixture` exercises preparation, fixture Lambo seeding,
standalone OpenCode, redacted structured event capture, grading, and process
group cleanup with fake executables. The runner gives subprocesses a small,
explicit fixture environment instead of inheriting the caller's environment.
The fixture marker and loopback check are test guards only; they do not provide
a network sandbox. Run only trusted fixture binaries and trusted fixture data.
`test-offline.sh` supplies those fakes and checks all five named tool events,
redaction, grader invocation and removal.
The offline transcript and grade are fixture evidence only. The live runner
records account-wide usage deltas and journals sandbox names for cleanup; it
does not yet collect the first-v2 snapshot.

The live runner's preflight requires a staged `rg` and the grader's payout
data, in addition to pinned Kalari, aashaan, msb, Vimanam and Lambo binaries.
The key is read from stdin. Use only one bounded session, inspect its spend,
and stop if it exceeds the task budget. Usage deltas are account-wide and are
not necessarily attributable to this session. The runner journals its own
sandbox names and removes them after the session. First-v2 grading is still
unimplemented. The first live attempt and its sanitized tool transcript are in
`results/upgrade-one.md` and `results/upgrade-one-tools.jsonl`.

By default the runner stops OpenCode after 60 seconds (configurable up to 120)
or when completed-step telemetry
reaches an estimated $0.20, whichever happens first. The estimate counts
uncached input, cache reads and writes at $0.15 per million and counts output
plus reasoning at $0.60 per million; reasoning may be counted twice. Malformed
step telemetry also stops the session. These are the project-recorded rates,
not a verified provider-enforced spending cap. An in-flight request, delayed
telemetry, Clef, price changes, and concurrent activity can put actual spending
above the estimate. The runner terminates the process group and then removes
its journaled sandboxes before grading.

The runner also stops after two failed calls to the same Kalari tool, even if
other tools run between them. A successful call to that tool resets its count;
repeated events with the same call ID count once. This early stop is separate
from, and does not strengthen, the soft spending cutoff.

Before a live session, the runner saves an account-wide model token snapshot in
the private result directory. On SIGTERM or SIGINT during OpenCode it stops the
process group, preserves a sanitized partial transcript and measures, skips the
grader, attempts a usage delta, and exits with the signal status. A missing
usage delta means actual usage is unknown. SIGKILL or an earlier interruption
cannot be handled this way.

OpenCode can assemble its first model request before the Kalari MCP connection
finishes. Live mode uses a loopback bootstrap proxy: it supplies a synthetic
read of the workspace README, then forwards an inference request only when its
tool list includes all five Kalari tools. This makes the synthetic tool call
part of the transcript and fails closed if discovery did not complete. A local
fake-provider probe with the real standalone OpenCode process confirmed the
first forwarded request includes all five tools; no provider inference was
used for that probe.
