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

This is preparation only, not a benchmark harness: it does not enforce a spend
limit, collect measures, run the hidden grader, or clean up sandboxes. Do not
use it for a live session until those controls are implemented. In particular,
the service currently rejects observer configuration and does not wire the
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

A hard session budget must include both OpenCode's model requests and Clef
requests from Kalari's subprocess. The existing service sends Clef directly to
its fixed HTTPS endpoint. Counting only OpenCode events or polling the
account-wide usage endpoint after requests cannot enforce the budget. These
helpers do not supply a request-time guard for both paths.
