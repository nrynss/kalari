#!/usr/bin/env bash
# Shared condition-1 continuation helper.
#
# remote.sh sources this after staging the harness, and the no-inference
# rehearsal sources the repository copy. A failed load exits nonzero before the
# caller reaches `opencode run`; nothing is guessed or started fresh.
set -euo pipefail

HARNESS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

load_condition1_state() {
  local state=$1 assignments
  assignments=$(python3 "$HARNESS_DIR/continuation.py" check --state "$state") || return $?
  eval "$assignments"
  export STATE_SESSION_ID STATE_XDG STATE_WORKSPACE STATE_WORKSPACE_DIGEST
}
