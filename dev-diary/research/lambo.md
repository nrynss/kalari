# Lambo 0.9.0

Lambo is **the memory**: a graph of typed concepts (`constraint`, `observation`, `resource`, …) with `depends_on` and `against` links, recall by meaning and by traversal, importance earned from independent support (canonical rulings), and stale knowledge flagged at recall. It speaks MCP itself (`lambo serve`). **Nothing needs building in Lambo**: configuration and Kalari's own code cover the rest.

## How Kalari uses it

| Job | How |
|---|---|
| Store a lesson | After a failed run and a passing fix: a `constraint` ("follow the page token until absent; every record exactly once", with its check ID) `depends_on` the change kind, and the run as an `observation` `depends_on` the lesson |
| Recall it | **By traversal, not by rank:** `lambo_inspect` on the change-kind resource (`pagination_changed`) lists its dependents. Vimanam reports the same change kind on another API in another format, and the lesson is found regardless of wording |
| Decide which to trust | One success is a lesson; the same lesson confirmed on independent upgrades becomes canonical and ranks higher |
| Retire a wrong one | A later outcome written `against` it; recall flags it; `lambo_stale` lists what the contradiction left stale. `lambo_inspect` gives no warning, only an incoming `Contradicts` edge: Kalari checks for it |
| Blast radius | Kalari's code search finds the call sites and writes them as `resource` concepts (`repo_scope` for paths); "3 callers in 2 services" is then a traversal |

**OpenCode never talks to Lambo.** Kalari starts `lambo serve` as a child, speaks MCP over its pipes, and is the single writer. Lambo never runs inside a sandbox. The runnable check lives in Kalari's evidence store; Lambo holds its wording and ID.

## Configuration

```toml
promotion_policy = "Solo"          # top-level, before the first [table]

[store]
kind = "sqlite"
path = "./kalari.db"

[embedder]
kind = "openai"                    # appends /v1/embeddings to url
url = "https://api.vultrinference.com"
model = "qwen3-embedding-4b"       # BGE M3 isn't served on Vultr
dim = 2560                         # Qwen's full width; `dimensions = 1024` (0.9.0) truncates, no better on recall (B4)
api_key_env = "VULTR_INFERENCE_API_KEY"
```

- **`Solo`, not the default `Swarm`.** Under Swarm a concept must survive 3 GC sweeps (about 30,000 mutations at the default cadence) before it can be a candidate; a hackathon never gets there. Solo is for a single writer, which Kalari is.
- **The change kind is a `resource`, not an `entity`.** GC's score cut removes only entities and resources, and spares a resource with dependents; an entity has no such protection. If the change kind were collected, every lesson anchored on it would lose its anchor.
- **Lessons and evidence are exempt from the score cut**; they're collected only as orphans or when unreachable. GC cadence needs no change.
- **A new store needs `lambo provision` before the first `serve`.** Since 0.9.0 the refusal says so ("no schema yet … Run `lambo provision`"); 0.8.0 wrongly blamed an older lambo ([lambo#222](https://github.com/nrynss/lambo/issues/222), fixed).
- **0.9.0 carries a calibration row for Qwen3 Embedding 4B** at 2560 and 1024 (merge threshold 0.89 / 0.90 in the `serve` log). `[embedder] calibration = "off"` restores the defaults.

## B4: measured (Lambo 0.9.0, Qwen3 Embedding 4B through Vultr, `gc_interval = 1`)

| Check | 0.8.0 | **0.9.0** |
|---|---|---|
| New store | Misleading "older lambo" refusal | **Pass:** "no schema yet … Run `lambo provision`" |
| Embeddings | Pass at 2560 | **Pass** at 2560, and at 1024 with `dimensions = 1024`; contract `kind=bge_m3 model=qwen3-embedding-4b`; calibration row applied |
| GC survival | Pass | **Pass:** sweeps ran (`trigger=mutations`), collected nothing; the change kind lists the lesson as a dependent; blast radius 3 after three runs |
| Solo promotion | Pass, about two minutes a step | **Pass, same timing:** score 1.50 (bar 3.00) until the citations pass the 60 s age floor; eligible at +74 s; **Candidate** at +139 s, then eligible for Venerable |
| Write receipt | Not recorded | **Pass:** `lambo_stats {receipt, wait_ms}` returns that write's outcome |
| Contradiction | Not recorded | **Pass:** the `against` write reports 1 contradiction and 1 stale dependency; recall flags the lesson; `lambo_stale` lists the run that cited it. `lambo_inspect` shows only the `Contradicts` edge, no warning |
| Recall, reworded query | Lesson 2nd (1.87 vs 3.42) | **Still 2nd:** 1.77 vs 2.92 behind "demo API v1 returns all items in one response"; 1.85 vs 3.43 once the lesson is a Candidate; 1.76 vs 2.92 at 1024; **identical with `calibration = "off"`** |

**#221 is closed but our case isn't fixed.** The calibration is real (the `serve` log shows its thresholds), but it doesn't move this ranking: on/off scores match to two decimals. Lambo's own check for the fix used a query with words in common with the lesson ("list endpoint … results … too many for one response"); ours, "the orders API now returns results one page at a time with a cursor", shares words only with the unrelated observation (*API*, *returns*, *one*), and the keyword leg decides it. Recordings: `testdata/lambo/`.

**This doesn't block Kalari.** Lessons are found by `lambo_inspect` on the change kind, never by recall rank, and that path passed on both releases. Recall stays a secondary read (the demo can show it, not rely on it).

The score formula (Solo, `src/canon/policy.rs`): sessions × 1.0 + human confirmations × 4.0 + dependent interactions × 2.0 − reverts × the revert weight, times the concept type's resistance (1.5 for a constraint). A dependent interaction counts only once its edge is older than `canonization_edge_min_age`.

## Reproduce

The B4 driver (a minimal MCP stdio client) and the four-step sequence are in `commands.md`.
