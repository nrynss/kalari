#!/usr/bin/env bash
# Verify the Chaaya pages against the fixture evidence store.
# Python standard library only. The fixture server is started and stopped here.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 web/check.py
