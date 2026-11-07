#!/usr/bin/env bash
# One real microVM brokered run: the payouts `correct` consumer inside a real
# Microsandbox microVM reaches the observed payouts API only through one fresh
# Lean broker. Not part of the gate: needs msb, /dev/kvm, and lake build.
#
# Budget: zero model calls, no key, no inference. Loopback only.
# The image must already be cached or pullable: pulls retry here, before the
# run, so the run itself creates with --pull never and --no-net.
# Run from anywhere after `lake build`; the Lean entry point resolves the
# repository root from its own directory.
set -euo pipefail
umask 022
cd "$(dirname "$0")/../.."

image=python:3.13-slim
if ! msb list --format json >/dev/null 2>&1; then
  echo 'broker-microvm: msb list failed; sandbox cleanup is unproven' >&2
  exit 1
fi
if ! msb create --name "broker-microvm-probe-$$" --cpus 1 --memory 256M \
    --no-net --pull never "$image" >/dev/null 2>&1; then
  echo "broker-microvm: image ${image} is not cached; pulling with retries"
  pulled=0
  for i in 1 2 3; do
    echo "pull ${image} attempt ${i}"
    if msb pull "$image" >/dev/null 2>&1; then
      pulled=1
      break
    fi
    [[ "$i" -lt 3 ]] && sleep "$i"
  done
  [[ "$pulled" -eq 1 ]] || { echo "broker-microvm: msb pull failed" >&2; exit 1; }
else
  msb remove -f "broker-microvm-probe-$$" >/dev/null 2>&1 || true
fi
msb remove -f "broker-microvm-probe-$$" >/dev/null 2>&1 || true

export PATH="$HOME/.elan/bin:$PATH"
exec timeout 600 lake env lean --run tests/live/broker-microvm.lean
