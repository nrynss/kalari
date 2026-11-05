#!/usr/bin/env bash
# Verify the frozen benchmark files still match bench/FROZEN.md.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
sha256sum -c <(awk '
/^\| bench\// {
  n = split($0, cells, "|")
  path = cells[2]; gsub(/^ +| +$/, "", path)
  hash = cells[3]; gsub(/^ +| +$/, "", hash)
  if (path != "" && hash ~ /^[0-9a-f]{64}$/) print hash "  " path
}' bench/FROZEN.md)
