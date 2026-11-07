#!/usr/bin/env bash
# Live broker proofs: per-run identity, loopback isolation between two Lean
# brokers, and one payouts traversal through the authenticated tunnel.
# Not part of the gate: it binds loopback ports and runs the bench API.
#
# Budget: zero model calls, no key, no microVM. Needs python3 (bench API
# only; no probe/*.py runs here) and lake. Run from anywhere after `lake build`.
set -euo pipefail
cd "$(dirname "$0")/../.."
exec timeout 300 lake env lean --run tests/live/broker-proof.lean
