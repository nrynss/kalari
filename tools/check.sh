#!/usr/bin/env bash
# The gate: every commit must pass this. CI runs the same script.
# Needs no key, no network beyond the toolchain, and no running server.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "-- lake build"
lake build
echo "-- kalari --version"
.lake/build/bin/kalari --version
echo "-- kalari-aashaan cases"
tests/aashaan-cases.sh
echo "gate passed"
