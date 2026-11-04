#!/usr/bin/env bash
# Pilot matrix for the reference arm. Prints the plan. A behaviour row is never started
# by this legacy driver, except B5: those rows go to bench/pilot/run-one.sh and are
# written under bench/pilot/harder/results/. B1 to B4 use bench/pilot/run-missing.sh
# for the isolated variant matrix. Condition rows for the full pair call
# bench/harness/run.sh only with --run. This script does not deploy API servers.
#
#   bench/pilot/run.sh --list
#   bench/pilot/run.sh --behaviour B1 --upgrade payouts --repeat 1
#   bench/pilot/run.sh --behaviour B5 --upgrade payouts --repeat 1
#   bench/pilot/run.sh --condition 3 --upgrade settlements
#   bench/pilot/run.sh --condition 3 --upgrade settlements --root bench/pilot/harder/results
#   bench/pilot/run.sh --run
#
# Without --run the selected plan is printed and the process exits 2, except --list,
# which prints the same plan and exits 0. The whole matrix is the default selection.
# --run on that matrix refuses too; run-missing.sh handles the isolated variants.
# Condition rows go to bench/pilot/results unless --root names another directory.
# The runner refuses an existing destination. T5.2b passes
# --root bench/pilot/harder/results so the old rows stay untouched.
#
# Condition runs are the proposed pair (every behaviour on).
# Condition 1 is one session across both upgrades: payouts, then settlements on it.
# Condition 2 is the same order, because the second upgrade reads the first's notes.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

RUN=0
LIST=0
BEHAVIOUR=""
CONDITION=""
UPGRADE=""
REPEAT=""
ROOT="bench/pilot/results"
ROOT_SET=0

usage() {
  sed -n '2,24p' "$0" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run) RUN=1; shift ;;
    --list) LIST=1; shift ;;
    --behaviour) BEHAVIOUR=${2:?behaviour id}; shift 2 ;;
    --condition) CONDITION=${2:?condition}; shift 2 ;;
    --upgrade) UPGRADE=${2:?upgrade}; shift 2 ;;
    --repeat) REPEAT=${2:?repeat}; shift 2 ;;
    --root) ROOT=${2:?destination root}; ROOT_SET=1; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done

if [[ -n $REPEAT && ! $REPEAT =~ ^[1-5]$ ]]; then
  echo "repeat must be 1, 2, 3, 4, or 5" >&2
  exit 2
fi
if [[ -n $BEHAVIOUR && -n $CONDITION ]]; then
  echo "pass a behaviour or a condition, not both" >&2
  exit 2
fi
if [[ -n $BEHAVIOUR && -z $UPGRADE ]]; then
  echo "a behaviour needs an upgrade" >&2
  exit 2
fi
ROOT=${ROOT%/}
case "$ROOT" in
  bench/pilot/results|bench/pilot/harder/results) ;;
  *) echo "root must be bench/pilot/results or bench/pilot/harder/results" >&2; exit 2 ;;
esac
if [[ -n $CONDITION && -z $UPGRADE ]]; then
  echo "a condition needs an upgrade" >&2
  exit 2
fi
if [[ -n $UPGRADE && -z $BEHAVIOUR && -z $CONDITION ]]; then
  echo "an upgrade needs a behaviour or a condition" >&2
  exit 2
fi
case "$UPGRADE" in
  ""|payouts|settlements) ;;
  *) echo "upgrade must be payouts or settlements" >&2; exit 2 ;;
esac
case "$CONDITION" in
  ""|1|2|3|6) ;;
  *) echo "condition must be 1, 2, 3, or 6" >&2; exit 2 ;;
esac
if [[ -n $BEHAVIOUR ]]; then
  case "$UPGRADE:$BEHAVIOUR" in
    payouts:B1|payouts:B2|payouts:B4|payouts:B5|settlements:B1|settlements:B2|settlements:B3|settlements:B5) ;;
    *) echo "unknown behaviour: $BEHAVIOUR" >&2; exit 2 ;;
  esac
fi

if [[ $LIST == 1 ]]; then
  MODE=list
elif [[ $RUN == 1 ]]; then
  MODE=run
else
  MODE=list
fi

if [[ -z $BEHAVIOUR && -z $CONDITION ]]; then
  cat <<'EOF'
# 8 single-behaviour variants x 5 fresh sessions, then conditions 1, 2, 3 and 6
# on the proposed pair, five times each. Condition 1 is one session across both
# upgrades (payouts, then settlements on that session).
# Behaviour rows are listed only. Use bench/pilot/run-missing.sh for isolated variants.
# Condition rows are not started unless --run is passed.
EOF
fi

# This legacy driver has no variant routing for the old single behaviours. The isolated
# driver handles those rows. B5 rows are routed to bench/pilot/run-one.sh, which keeps
# them under bench/pilot/harder/results/.
if [[ $MODE == run && -z $CONDITION && $BEHAVIOUR != B5 ]]; then
  echo "refusing behaviour run in legacy driver: use bench/pilot/run-missing.sh" >&2
  exit 2
fi

run_harness() { # condition upgrade dest
  local cond=$1 upgrade=$2 dest=$3
  # Refuse before the harness call, so an existing row is never overwritten.
  [[ ! -e "$dest" ]] || { echo "result already exists: $dest" >&2; exit 2; }
  local src="bench/harness/results/c${cond}-${upgrade}.json"
  bench/harness/run.sh --condition "$cond" --upgrade "$upgrade"
  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
}

handle_behaviour() { # upgrade behaviour repeat
  local upgrade=$1 behaviour=$2 rep=$3
  local dest="" line
  if [[ $behaviour == B5 ]]; then
    # B5-only rows belong to the harder pilot, apart from the frozen baseline rows.
    # An explicit --root must name that directory, or the flag would be ignored.
    if [[ $ROOT_SET == 1 && $ROOT != "bench/pilot/harder/results" ]]; then
      echo "B5 rows need --root bench/pilot/harder/results" >&2
      exit 2
    fi
    dest="bench/pilot/harder/results/behaviour-${upgrade}-${behaviour}-r${rep}.json"
    line="behaviour $upgrade $behaviour repeat $rep: bench/pilot/run-one.sh --behaviour $behaviour --upgrade $upgrade --dest $dest"
  else
    line="behaviour $upgrade $behaviour repeat $rep: bench/pilot/run-missing.sh (isolated variant)"
  fi
  if [[ $MODE == list ]]; then
    printf '%s\n' "$line"
    return 0
  fi
  if [[ $behaviour == B5 ]]; then
    bench/pilot/run-one.sh --behaviour "$behaviour" --upgrade "$upgrade" --dest "$dest"
    return 0
  fi
  echo "refusing behaviour $upgrade $behaviour in legacy driver: use bench/pilot/run-missing.sh" >&2
  exit 2
}

handle_condition() { # condition upgrade repeat
  local cond=$1 upgrade=$2 rep=$3
  local dest="$ROOT/condition-${cond}-${upgrade}-r${rep}.json"
  local line="condition $cond $upgrade repeat $rep: bench/harness/run.sh --condition $cond --upgrade $upgrade (writes $dest)"
  if [[ $cond == 1 && $upgrade == payouts ]]; then
    line="$line (session start; settlements repeat $rep continues it)"
  elif [[ $cond == 1 && $upgrade == settlements ]]; then
    line="$line (continues the payouts session)"
  fi
  if [[ $MODE == list ]]; then
    printf '%s\n' "$line"
    return 0
  fi
  echo "$line" >&2
  run_harness "$cond" "$upgrade" "$dest"
}

want_rep() { [[ -z $REPEAT || $REPEAT == "$1" ]]; }

if [[ -z $CONDITION ]]; then
  while read -r upgrade behaviour; do
    [[ -n $BEHAVIOUR && ( $UPGRADE != "$upgrade" || $BEHAVIOUR != "$behaviour" ) ]] && continue
    for rep in 1 2 3 4 5; do
      want_rep "$rep" || continue
      handle_behaviour "$upgrade" "$behaviour" "$rep"
    done
  done <<'EOF'
payouts B1
payouts B2
payouts B4
payouts B5
settlements B1
settlements B2
settlements B3
settlements B5
EOF
fi

if [[ -z $BEHAVIOUR ]]; then
  for cond in 1 2 3 6; do
    [[ -n $CONDITION && $CONDITION != "$cond" ]] && continue
    for rep in 1 2 3 4 5; do
      want_rep "$rep" || continue
      for upgrade in payouts settlements; do
        [[ -n $UPGRADE && $UPGRADE != "$upgrade" ]] && continue
        handle_condition "$cond" "$upgrade" "$rep"
      done
    done
  done
fi

if [[ $MODE == list && $LIST != 1 ]]; then
  echo "refusing to start the pilot without --run" >&2
  exit 2
fi
