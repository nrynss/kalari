#!/usr/bin/env bash
# The gate: every commit must pass this. CI runs the same script.
# Needs no key, no network beyond the toolchain, and no running server.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "-- lake build"
lake build
echo "-- kalari --version"
.lake/build/bin/kalari --version
echo "-- kalari offline self-test"
.lake/build/bin/kalari --offline-self-test
echo "-- kalari-aashaan cases"
tests/aashaan-cases.sh
echo "-- examples"
tests/examples.sh
echo "-- http api"
tests/http-api.sh
echo "-- benchmark quirks"
bench/tests/quirks.sh
echo "-- web evidence"
web/check.sh
echo "gate passed"
