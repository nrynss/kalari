#!/usr/bin/env bash
# Continue only missing single-behaviour rows; preserve all committed rows.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
[[ ! -e bench/pilot/.pending ]] || { echo "an interrupted run needs spend reconciliation before resuming" >&2; exit 1; }
[[ -f bench/pilot/results/behaviour-payouts-B1-r1.json ]] || { echo 'run and check the first case before the matrix' >&2; exit 1; }
python3 bench/pilot/validate.py --partial
for pair in 'payouts B1' 'payouts B2' 'payouts B4' 'settlements B1' 'settlements B2' 'settlements B3'; do
  read -r upgrade behaviour <<< "$pair"
  for rep in 1 2 3 4 5; do
    dest="bench/pilot/results/behaviour-${upgrade}-${behaviour}-r${rep}.json"
    [[ -e "$dest" ]] && continue
    # Charge every recorded row at list price; use at least $0.25 per remaining
    # session, or the most expensive measured session, whichever is higher.
    python3 - <<'PY'
import glob, json, sys
paths = glob.glob('bench/pilot/results/*.json')
rows = [json.load(open(p)) for p in paths]
spent = sum(r['cost_usd'] for r in rows)
variants = [r for r in rows if r.get('behaviour')]
remaining = 30 - len(variants)
rate = max([0.25] + [r['cost_usd'] for r in variants])
projection = spent + remaining * rate
print(f'budget: spent=${spent:.6f}, remaining={remaining}, conservative projection=${projection:.6f}', flush=True)
if projection > 16: sys.exit('budget projection exceeds $16; stopping')
PY
    printf "%s\n" "$dest" > bench/pilot/.pending
    bench/pilot/run-one.sh --upgrade "$upgrade" --behaviour "$behaviour" --dest "$dest"
    python3 bench/pilot/validate.py --partial
    rm bench/pilot/.pending
  done
done
python3 bench/pilot/validate.py
