# Disbursements v2: where each behaviour lives (never shown to an arm)

This is a **manufactured scenario** for the showcase: the behaviour combination is synthetic,
not sourced from a real vendor's API. The agent-facing docs
(`workspace/disbursement-sync/docs/meridian-disbursements-api.md`) are true sentence by
sentence; they describe the window overlap and say "deduplicate on `id`" and say nothing about
which delivery of a repeated record is current.

| Behaviour | Server (`server.py`) | Docs (agent-facing) |
|---|---|---|
| A token on every page, the last included; `drained` ends the traversal | `mint(end - 1)` on every window, drained included | "Every response includes a `cursor`…"; "`drained: true` means the export has caught up" |
| Windows overlap: the next window begins with the record that ended the previous one | the next window starts at `end - 1` | "Windows overlap at their edges… that disbursement appears in both responses… deduplicate on `id`" |
| **The trap**: the record's first delivery (closing a window) is its window-edge version; the re-delivery (opening the next window) is its final version | `page[-1] = edge(page[-1])` on every non-final window; every other delivery final | Nothing. The docs never say the two deliveries are equal, and never say which is current |

**Truth:** 2,341 disbursements, `ds_00001` to `ds_02341`, final versions in `data.py` (`FINAL`);
the window-edge version of a record is its amount before a late 1,250-cent adjustment. v1
serves final versions only. At `limit: 100` a traversal runs 24 windows and delivers 23
records twice (indices 99, 198, …, 2277).

| The obvious code | Outcome |
|---|---|
| One v2 request | 100 of 2,341, the 100th at its edge amount |
| Stop on `drained`, append every page | 2,364 records, 23 duplicates |
| Stop on `drained`, keep the first version per `id` (`if id not in seen`) | 2,341 exactly once, **23 at the unadjusted amount** — exit 0, plausible counts |
| Stop on `drained`, keep the last version per `id` | 2,341, exactly once, PASS |

The hidden grader (`grader/grade.py`) counts missing, extra, duplicates and **mismatched**
records against `FINAL`. The reference consumers in `reference/` exist to check these outcomes
offline before any live session.
