# The 0.2.3 repeat evidence

105 sanitised session rows behind the judges page. Each file is one session:
`<project>--<session>.json`, where the session id is the `kalari-...` or
`reference-...` directory the raw run lived in. `results.json` is the video
numbers file the page figures are checked against.

Projects `r1..r5-{glm,ds,mimo}-{learn,ref}` are the headline repeats: the
Kalari arm keeps one project and one store across payouts, settlements and
disbursements; the reference arm is OpenCode alone. `glm3-learn` is the
filmed GLM chain. `r1-qwen-*` and `r1-muse-*` are single runs outside the
headline. The `repeat` field is the repeat index for headline projects, `1`
for the single runs, and null for the chain. `headline` marks the 90 rows
the headline tallies.

## Sanitisation

The raw rows hold user home workspaces, the VM address, guest
aliases and runner-internal sandbox names. None of that is published. The
producer keeps a whitelisted field set and maps every host to a plain
placeholder (`the VM's public address`, `the guest API alias`). Run ids
(`run-<hex>`, `kalari-<scenario>-<hex>`) are kept: they are links.

## Recompute

`bench/check-023.py` recomputes every video number from these rows and
compares them with `results.json`. `bench/evidence-023.jsonl` is the API
store built from these rows by `bench/produce-evidence-023.py`.
