# Lambo 0.8.0

Lambo is **the memory**: a graph of typed concepts (`constraint`, `observation`, `resource`, …) with `depends_on` and `against` links, recall by meaning and by traversal, importance earned from independent support (canonical rulings), and stale knowledge flagged at recall. It speaks MCP itself (`lambo serve`). **Nothing needs building in Lambo**: configuration and Kalari's own code cover the rest.

## How Kalari uses it

| Job | How |
|---|---|
| Store a lesson | After a failed run and a passing fix: a `constraint` ("follow the page token until absent; every record exactly once", with its check ID) `depends_on` the change kind, and the run as an `observation` `depends_on` the lesson |
| Recall it | **By traversal, not by rank:** `lambo_inspect` on the change-kind resource (`pagination_changed`) lists its dependents. Vimanam reports the same change kind on another API in another format, and the lesson is found regardless of wording |
| Decide which to trust | One success is a lesson; the same lesson confirmed on independent upgrades becomes canonical and ranks higher |
| Retire a wrong one | A later outcome written `against` it; recall flags it stale; `lambo_stale` lists what a contradiction left stale |
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
dim = 2560                         # the adapter sends no `dimensions`, so Qwen's full width
api_key_env = "VULTR_INFERENCE_API_KEY"
```

- **`Solo`, not the default `Swarm`.** Under Swarm a concept must survive 3 GC sweeps (about 30,000 mutations at the default cadence) before it can be a candidate; a hackathon never gets there. Solo is for a single writer, which Kalari is.
- **The change kind is a `resource`, not an `entity`.** GC's score cut removes only entities and resources, and spares a resource with dependents; an entity has no such protection. If the change kind were collected, every lesson anchored on it would lose its anchor.
- **Lessons and evidence are exempt from the score cut**; they're collected only as orphans or when unreachable. GC cadence needs no change.
- **A new store needs `lambo provision` before the first `serve`** ([lambo#222](https://github.com/nrynss/lambo/issues/222): the error wrongly says it "was provisioned by an older lambo").

## B4: measured (Lambo 0.8.0, Qwen3 Embedding 4B through Vultr, `gc_interval = 1`)

| Check | Result |
|---|---|
| Embeddings | Pass: every concept embedded; contract `kind=bge_m3 model=qwen3-embedding-4b dim=2560` |
| GC survival | Pass: sweeps ran (`trigger=mutations`) and collected nothing; the change kind lists the lesson as a dependent; blast radius 3 after three runs |
| Solo promotion | Pass, with timing to plan for. One citation leaves the lesson at score 1.5 (bar 3.0). After three citing runs, each citation older than `canonization_edge_min_age` (60 s), it is eligible; at the next `canonization_eval_interval` (60 s), with `serve` running, it becomes a **Candidate**, eligible for Venerable at the next cycle. **About two minutes per step: the demo's memory scene must allow for it** |
| Recall, reworded query | **Weak:** the lesson ranks 2nd (1.87), behind the unrelated "demo API v1 returns all items in one response" (3.42) |

**The ranking problem is Lambo's, not Qwen's.** Qwen's raw cosine ranks the lesson first (0.659, then the run evidence 0.549, then that observation 0.526), with or without Qwen's instruction prefix. Qwen's similarities sit in a narrow band (0.26–0.66), and Lambo's recall is calibrated per embedding contract only for measured contracts; this one falls back to defaults. Filed as [lambo#221](https://github.com/nrynss/lambo/issues/221). Fixes are in progress, and a Lambo release follows: **re-run B4 on it.** Until then, find lessons by the change kind.

The score formula (Solo, `src/canon/policy.rs`): sessions × 1.0 + human confirmations × 4.0 + dependent interactions × 2.0 − reverts × the revert weight, times the concept type's resistance (1.5 for a constraint). A dependent interaction counts only once its edge is older than `canonization_edge_min_age`.

## Reproduce

The B4 driver (a minimal MCP stdio client) and the four-step sequence are in `commands.md`.
