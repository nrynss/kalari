#!/usr/bin/env bash
# The gate fails if any proved theorem rests on `sorryAx`.
# For each source file below, copy it to a temp dir, append one `#print axioms`
# line per `theorem` in it, and elaborate the copy with `lake env lean`. The
# output names every axiom each theorem depends on; any `sorryAx` fails.
# Aashaan has no lean_lib (it stays an exe root), so it cannot be imported.
# Elaborating a copy covers both files uniformly without touching lakefile.toml.
# Offline: imports resolve from the oleans `lake build` already produced.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

# check_axioms <source> <namespace prefix, may be empty> <entry points...>
# Every theorem in the file is checked; the entry points must be among them so
# a broken name extraction fails closed instead of silently checking nothing.
check_axioms() {
  local src=$1 ns=$2; shift 2
  local names
  names=$(grep -oE '^[[:space:]]*(@\[[^]]*\][[:space:]]*)?(private[[:space:]]+)?theorem[[:space:]]+[A-Za-z0-9_'"'"']+' "$src" \
    | grep -oE '[A-Za-z0-9_'"'"']+$') || { echo "FAIL $src: no theorems extracted"; fail=1; return; }
  local e
  for e in "$@"; do
    if ! printf '%s\n' "$names" | grep -qx "$e"; then
      echo "FAIL $src: entry point $e not extracted (update tools/axioms.sh)"; fail=1; return
    fi
  done
  local copy="$tmp/$(printf '%s' "$src" | tr '/' '_')"
  cp "$src" "$copy"
  local n
  for n in $names; do printf '#print axioms %s%s\n' "$ns" "$n" >> "$copy"; done
  local out
  if ! out=$(lake env lean "$copy" 2>&1); then
    echo "FAIL $src: lean failed:"; printf '%s\n' "$out"; fail=1; return
  fi
  for n in $names; do
    if ! printf '%s\n' "$out" | grep -qE "${ns}${n}' (depends on axioms:|does not depend on any axioms)"; then
      echo "FAIL $src: no axioms line for ${ns}${n}:"; printf '%s\n' "$out"; fail=1; return
    fi
  done
  if printf '%s\n' "$out" | grep -q 'sorryAx'; then
    echo "FAIL $src: sorryAx found:"
    printf '%s\n' "$out" | grep 'sorryAx'
    fail=1; return
  fi
  echo "ok   $src ($(printf '%s' "$names" | wc -w) theorems, no sorryAx)"
  printf '%s\n' "$out" | sed 's/^/  /'
}

check_axioms Kalari/Gate.lean "Kalari.Gate." \
  decide_workspace decide_network decide_caps decide_secrets
check_axioms Aashaan/Main.lean "" \
  killed_timeout_iff killed_output_cap_iff clampBytes_le \
  jstr_quotes_are_delimiters jstr_no_raw_control

exit $fail
