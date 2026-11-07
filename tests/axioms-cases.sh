#!/usr/bin/env bash
# Negative-test harness for tools/axioms.sh: synthetic fixtures that must fail,
# each with the failure the gate owes it, plus a positive control that must
# pass. Proves the gate fails closed instead of silently checking nothing.
# Fast and offline: fixtures use only Lean core, elaborated with `lake env
# lean`; no microVM, no network, no keys. Needs the toolchain on PATH
# ($HOME/.elan/bin), same as the rest of the gate.
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0
FIX=tests/axioms-fixtures

# expect_fail <fixture> <expected message fragment>
expect_fail() {
  local file=$1 want=$2 out
  if out=$(AXIOMS_FILES="$file" tools/axioms.sh 2>&1); then
    echo "FAIL $file: axioms.sh passed, expected failure ($want)"
    fail=1; return
  fi
  if ! printf '%s\n' "$out" | grep -qF "$want"; then
    echo "FAIL $file: wanted [$want], got:"
    printf '%s\n' "$out"
    fail=1; return
  fi
  echo "ok   $file fails as expected ($want)"
}

# Positive control: must pass, and its anonymous instance must be renamed and
# reported (previously anonymous instances were silently unchecked).
if out=$(AXIOMS_FILES="$FIX/pass-clean.lean" tools/axioms.sh 2>&1); then
  if printf '%s\n' "$out" | grep -q '__axioms_instance_1'; then
    echo "ok   pass-clean.lean passes, anonymous instance renamed and checked"
  else
    echo "FAIL pass-clean.lean: anonymous instance not renamed+checked:"
    printf '%s\n' "$out"
    fail=1
  fi
else
  echo "FAIL pass-clean.lean: axioms.sh failed on the positive control:"
  printf '%s\n' "$out"
  fail=1
fi

expect_fail "$FIX/fail-sorry.lean" "sorry token found"
expect_fail "$FIX/fail-sorryax.lean" "sorry token found"
expect_fail "$FIX/fail-axiom.lean" "axiom declaration"
expect_fail "$FIX/fail-eval.lean" "non-trivial #eval"
expect_fail "$FIX/fail-runner.lean" "elaboration-time runner not covered"
expect_fail "$FIX/fail-section.lean" "declaration extraction failed"
expect_fail "$FIX/fail-extraprint.lean" "unexpected extra output"

if [ "$fail" = 0 ]; then echo "axioms cases passed"; else echo "axioms cases FAILED"; fi
exit $fail
