# Lambo 0.9.0 recordings

What Kalari's Lambo client (T3.2) replays instead of starting a real `lambo serve`. Every `.jsonl` is one `lambo serve` process over stdio: each line is `{"dir": "out" | "in", "msg": <JSON-RPC message>}`, `out` being what the client sent. The `.txt` beside it is the same run as the driver printed it (the tool's text, then `[structured]` and its `structuredContent`, cut at the step's `max`).

Config: `lambo.toml` (Qwen3 Embedding 4B through Vultr at 2560, Solo, SQLite). `b4-full` adds `[daemon] gc_interval = 1` so GC sweeps run on every mutation. Each store was provisioned first (`lambo provision`). No key appears: it reached `lambo serve` only through `VULTR_INFERENCE_API_KEY`.

| File | Steps | What it shows |
|---|---|---|
| `b4-full.jsonl` | `steps/b4-full.json` | `initialize`, `tools/list`; change kind (`resource`), lesson (`constraint` `depends_on` it), run evidence; five unrelated derives; `lambo_stats`; `lambo_inspect` on the change kind (the lesson among its dependents) and on the lesson; recall on a reworded query; two more citing runs; the lesson at +4 s (refused, score 1.50), +74 s (eligible for Candidate), +139 s (**Candidate**, eligible for Venerable); recall again |
| `receipt.jsonl` | `steps/receipt.json` | A fresh store: the same first writes, then **`lambo_stats` with `receipt` and `wait_ms`** returning that write's outcome (`receipt lwr1…: applied — …`) |
| `against.jsonl` | `steps/against.json` | **A second `serve` on `receipt`'s store** (a restart against an existing store). A run written `against` the lesson; its receipt reports `1 contradiction(s) recorded; 1 stale direct dependenc(ies)`; `lambo_inspect` on the lesson; recall flagging it; `lambo_stale` listing the run that cited it |
| `recall-1024.txt` | `steps/recall-1024.json` | The same writes at `dim = 1024` with `dimensions = 1024` (Matryoshka truncation, new in 0.9.0) |
| `recall-calibration-off.txt` | `steps/receipt.json` | `[embedder] calibration = "off"`: recall scores identical to the calibrated run |
| `unprovisioned.txt` | | `lambo serve` on a brand-new store before `lambo provision`: the 0.9.0 wording, exit 1 |

## What the client must handle (seen here)

- **Writes are acknowledged, not applied.** `lambo_derive` returns `accepted … not yet applied` and a receipt `lwr1.<hex>.<hex>.<n>`; the outcome arrives in the `write receipts (your earlier writes, now settled)` block of the *next* tool response, or from `lambo_stats {receipt, wait_ms}`.
- **`depends_on` and `against` take a concept's content or its id** (the 8-hex prefix recall shows, or the full UUID).
- **A contradiction shows differently on each read.** Recall puts `⚠ Contradicted at … by kalari: "…"` on the hit and in `warnings`. `lambo_inspect` on the contradicted lesson carries **no warning** (`warnings: []`); the contradiction is only an incoming `Contradicts` edge in `focus.levels[].neighbours`. Since Kalari finds lessons by inspecting the change kind, it checks each lesson for that edge itself.
- **Promotion is reported in `admission`:** `status`, `next`, `eligible`, and the gates in `checks` (`solo_score` `current` against `bar`). A lesson's label gains `, candidate` once promoted.
- **Recall rank is not the lesson finder.** On the reworded query the lesson ranks 2nd behind an unrelated observation in every run here (`research/lambo.md`).

## Reproduce

```bash
lambo provision --config ./lambo.toml
VULTR_INFERENCE_API_KEY=… python3 -I driver.py "$(command -v lambo)" <store-dir> ./lambo.toml steps/b4-full.json out.jsonl
```

`driver.py` adds `agent_id: "kalari"` to every call. A step with `"receipt": true` passes the previous ack's receipt to `lambo_stats` with `wait_ms` 10000.
