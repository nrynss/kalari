#!/usr/bin/env python3
"""Recompute every 0.2.3 video number from the published rows.

Reads bench/rows-0.2.3/*.json (the sanitised rows) and compares each figure
with bench/rows-0.2.3/results.json. Exits 1 on any disagreement. This is the
same recomputation web/check.py runs against the served page.
"""

from __future__ import annotations

import glob
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
ROWS = REPO / "bench" / "rows-0.2.3"
EXPECTED = json.loads((ROWS / "results.json").read_text(encoding="utf-8"))

fails: list[str] = []


def check(name: str, got, want) -> None:
    if got != want:
        fails.append(f"{name}: got {got!r} want {want!r}")


def load_rows() -> list[dict]:
    rows = []
    for path in sorted(glob.glob(str(ROWS / "*.json"))):
        if path.endswith("results.json"):
            continue
        with open(path, encoding="utf-8") as handle:
            rows.append(json.load(handle))
    return rows


def main() -> int:
    rows = load_rows()
    check("published row count", len(rows), 105)

    headline = [r for r in rows if r.get("headline")]
    check("headline row count", len(headline), 90)
    kalari = [r for r in headline if r["arm"] == "kalari"]
    alone = [r for r in headline if r["arm"] == "reference"]
    check("headline kalari rows", len(kalari), 45)
    check("headline alone rows", len(alone), 45)

    kalari_pass = sum(1 for r in kalari if r["measures"]["verdict"] == "PASS")
    alone_pass = sum(1 for r in alone if r["measures"]["verdict"] == "PASS")
    check("kalari pass", kalari_pass, 45)
    check("alone pass", alone_pass, 34)

    kalari_cost = sum(r["cost_usd"] for r in kalari) / 45
    alone_cost = sum(r["cost_usd"] for r in alone) / 45
    kalari_wall = sum(r["measures"]["wall_time_s"] for r in kalari) / 45
    alone_wall = sum(r["measures"]["wall_time_s"] for r in alone) / 45
    check("kalari mean cost", round(kalari_cost, 4), 0.0242)
    check("alone mean cost", round(alone_cost, 4), 0.0666)
    check("kalari mean wall", round(kalari_wall, 1), 58.4)
    check("alone mean wall", round(alone_wall, 1), 166.0)
    check("cost ratio", round(alone_cost / kalari_cost, 1), 2.8)
    check("wall ratio", round(alone_wall / kalari_wall, 1), 2.8)

    # The grid: per model x upgrade x arm over the headline repeats.
    grid = EXPECTED["grid"]
    by_cell: dict[tuple[str, str, str], list[dict]] = {}
    for r in headline:
        by_cell.setdefault((r["model"], r["scenario"], r["arm"]), []).append(r)
    check("grid cells", len(by_cell), 18)
    model_names = {
        "deepseek-v4.1-flash-1017": "DeepSeek V4.1 Flash",
        "glm-5.3-flash": "GLM 5.3 Flash",
        "mimo-v2.6-flash": "MiMo V2.6 Flash",
    }
    for (model_id, scenario, arm), cell in sorted(by_cell.items()):
        want = grid[model_names[model_id]][scenario]["kalari" if arm == "kalari" else "alone"]
        check(f"grid {model_id} {scenario} {arm} n", len(cell), want["n"])
        passed = sum(1 for r in cell if r["measures"]["verdict"] == "PASS")
        check(f"grid {model_id} {scenario} {arm} pass", passed, want["pass"])

    # Alone disbursement failures per model.
    alone_dis = [r for r in alone if r["scenario"] == "disbursements"]
    failed: dict[str, int] = {}
    for r in alone_dis:
        failed[r["model"]] = failed.get(r["model"], 0) + (r["measures"]["verdict"] != "PASS")
    check("alone disbursements GLM failed", failed.get("glm-5.3-flash"), 5)
    check("alone disbursements DS failed", failed.get("deepseek-v4.1-flash-1017"), 4)
    check("alone disbursements MiMo failed", failed.get("mimo-v2.6-flash"), 2)

    # Problem row: GLM alone disbursements shipped 23 wrong.
    glm_ref_dis = [r for r in alone_dis if r["model"] == "glm-5.3-flash"]
    check("GLM alone disbursements rows", len(glm_ref_dis), 5)
    check("GLM alone disbursements pass", sum(1 for r in glm_ref_dis if r["measures"]["verdict"] == "PASS"), 0)
    check(
        "GLM alone disbursements all mismatched 23",
        sorted((r.get("grade") or {}).get("mismatched") for r in glm_ref_dis),
        [23, 23, 23, 23, 23],
    )

    # Payouts and settlements passed alone in all three headline models.
    easy_alone = [r for r in alone if r["scenario"] in ("payouts", "settlements")]
    check("easy alone rows", len(easy_alone), 30)
    check("easy alone pass", sum(1 for r in easy_alone if r["measures"]["verdict"] == "PASS"), 30)

    # The 900 s cap stopped two GLM alone payouts sessions.
    capped = [r for r in alone if r.get("session_capped")]
    check("alone capped count", len(capped), 2)
    check("alone capped scenarios", sorted(r["scenario"] for r in capped), ["payouts", "payouts"])
    check("alone capped model", sorted(set(r["model"] for r in capped)), ["glm-5.3-flash"])

    # Learning: payouts wrote, settlements and disbursements recalled.
    # The 15 headline repeats (r1..r5 x glm, ds, mimo); qwen and muse sit apart.
    learn = [r for r in rows if r.get("headline") and r["arm"] == "kalari"]
    payouts_learn = [r for r in learn if r["scenario"] == "payouts"]
    check("payouts learn rows", len(payouts_learn), 15)
    check("payouts lessons written", sum(len(r.get("lessons_published") or []) for r in payouts_learn), 15)
    sett_learn = [r for r in learn if r["scenario"] == "settlements"]
    check("settlements recalled 15/15", sum(1 for r in sett_learn if r.get("lessons_recalled")), 15)
    dis_learn = [r for r in learn if r["scenario"] == "disbursements"]
    check("disbursements recalled 14/15", sum(1 for r in dis_learn if r.get("lessons_recalled")), 14)

    # Filmed GLM chain.
    chain = {r["scenario"]: r for r in rows if r.get("chain") == "glm3"}
    check("chain scenarios", sorted(chain), ["disbursements", "payouts", "settlements"])
    facts = EXPECTED["chain"]
    for scenario in ("payouts", "settlements", "disbursements"):
        row, want = chain[scenario], facts[scenario]
        check(f"chain {scenario} verdict", row["measures"]["verdict"], want["verdict"])
        check(f"chain {scenario} records", (row.get("grade") or {}).get("records"), want["records_right"])
        check(f"chain {scenario} wall", round(row["measures"]["wall_time_s"], 1), want["wall_s"])
        check(f"chain {scenario} cost", round(row["cost_usd"], 3), want["cost_usd"])
    check("chain payouts written", len(chain["payouts"].get("lessons_published") or []), facts["payouts"]["lessons_written"])
    check("chain settlements recalled", len(chain["settlements"].get("lessons_recalled") or []), facts["settlements"]["lessons_recalled"])
    check("chain disbursements recalled", len(chain["disbursements"].get("lessons_recalled") or []), facts["disbursements"]["lessons_recalled"])

    # Containment bundle.
    evidence = [json.loads(line) for line in (REPO / "tests" / "live" / "containment-0.2.3" / "evidence.jsonl").read_text(encoding="utf-8").splitlines() if line.strip()]
    cont = [r for r in evidence if r.get("kind") == "containment"]
    check("containment records", len(cont), 1)
    result = cont[0]["payload"]["result"]
    numbers = EXPECTED["containment"]
    check("containment cap", cont[0]["payload"]["config"]["time_cap_ms"], numbers["cap_ms"])
    check("containment measured", result["wall_ms"], numbers["measured_ms"])
    check("containment verdict", result["verdict"], numbers["verdict"])
    check("containment pages", result["pages_fetched"], numbers["pages_before_kill"])
    observed = cont[0]["payload"]["network"]["observed"]
    check("containment allowed", observed["allowed_attempts"], numbers["allowed"])
    check("containment refused", observed["denied_attempts"], numbers["refused"])
    check("containment breaches", observed["breaches"], 0)
    check("containment cleanup", cont[0]["payload"]["cleanup"]["ok"], True)
    check("containment sandboxes left", (cont[0]["payload"]["cleanup"].get("still_listed") or []), [])

    # Qwen and Muse: outside the headline.
    for model_id, kalari_want, alone_want in (
        ("qwen3.8-27b", "2 of 3", "2 of 3"),
        ("muse-glimmer-30b", "1 of 3", "2 of 3"),
    ):
        for arm, want in (("kalari", kalari_want), ("reference", alone_want)):
            cell = [r for r in rows if r["model"] == model_id and r["arm"] == arm]
            check(f"{model_id} {arm} rows", len(cell), 3)
            passed = sum(1 for r in cell if r["measures"]["verdict"] == "PASS")
            check(f"{model_id} {arm} pass", f"{passed} of 3", want)

    # Frozen baseline stays demoted.
    frozen = [json.loads(line) for line in (REPO / "bench" / "frozen-evidence.jsonl").read_text(encoding="utf-8").splitlines() if line.strip()]
    k_cost = [r["payload"]["cost_usd"] for r in frozen if r["payload"]["arm"] == "kalari"]
    r_cost = [r["payload"]["cost_usd"] for r in frozen if r["payload"]["arm"] == "reference"]
    check("frozen sessions", len(frozen), 60)
    check("frozen kalari per session", round(sum(k_cost) / len(k_cost), 3), EXPECTED["baseline_frozen"]["kalari_cost_usd"])
    check("frozen reference per session", round(sum(r_cost) / len(r_cost), 3), EXPECTED["baseline_frozen"]["reference_cost_usd"])

    if fails:
        print(f"MISMATCHES: {len(fails)}")
        for line in fails:
            print("FAIL " + line)
        return 1
    print(f"RECOMPUTE-023: ALL OK ({len(rows)} published rows match results.json)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
