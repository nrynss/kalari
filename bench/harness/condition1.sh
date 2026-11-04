#!/usr/bin/env bash
# Condition 1's workspace and XDG decisions, in one place.
#
# `remote.sh` sources this on the VM. The no-inference rehearsal sources the
# repository copy. Both call `prepare_condition1`, so the rehearsal exercises
# the production decision rather than a copy of it.
#
# Condition 1 is one OpenCode session across both upgrades. The session stays
# attached to one absolute workspace. The settlements phase replaces that
# workspace's contents instead of creating a new directory. The workspace lives
# at `<root>/workspaces/condition-1`. Its parent holds no run artifacts. The
# path is stable across both upgrades. The continuation state records it.
set -euo pipefail

CONDITION1_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=continuation.sh
. "$CONDITION1_DIR/continuation.sh"

condition1_state_path() {
  printf '%s/state/condition-1.json\n' "$1"
}

condition1_xdg_path() {
  printf '%s/state/condition-1-xdg\n' "$1"
}

condition1_workspace_path() {
  printf '%s/workspaces/condition-1\n' "$1"
}

# Drop stale entries from the workspace parent. Keep the condition-1 entry.
condition1_clear_workspace_parent() { # $1 workspace path
  local parent name
  parent=$(dirname "$1")
  name=$(basename "$1")
  [[ -d "$parent" ]] || return 0
  find "$parent" -mindepth 1 -maxdepth 1 ! -name "$name" -exec rm -rf -- {} +
}

# prepare_condition1 <root> <stage> <stage-workspace> <upgrade>
#
# upgrade=payouts starts condition 1. It resets the continuation state and the
# XDG base. It drops stale entries from the workspace parent. It creates the
# stable workspace and copies the payouts stage into it.
# upgrade=settlements resumes. It requires the saved state. It requires that
# the state names the stable workspace. It hands the saved values to the caller
# and consumes the state before any session can start. Then it clears the
# workspace in place and copies the settlements stage into it.
#
# On success it sets COND1_WORKSPACE, COND1_XDG, COND1_SESSION_ID,
# COND1_CONTINUED, COND1_STAGE_DIGEST and COND1_WORKSPACE_DIGEST. It also sets
# the variables remote.sh consumes (WS, XDG_BASE, SESSION_ID,
# SESSION_CONTINUED, STAGE_DIGEST, WORKSPACE_DIGEST) and STATE_CONSUMED.
# On failure it returns nonzero. Its own checks print a `condition1:` line.
# Other failures keep the command's own error, including the continuation state
# check. Nothing falls back to a fresh workspace or a new session.
prepare_condition1() {
  local root=$1 stage=$2 stage_ws=$3 upgrade=$4
  local state xdg ws sid continued=0
  STATE_CONSUMED=0

  state=$(condition1_state_path "$root")
  ws=$(condition1_workspace_path "$root")
  case "$upgrade" in
    payouts)
      rm -rf "$(condition1_xdg_path "$root")" "$state"
      xdg=$(condition1_xdg_path "$root")
      sid=""
      condition1_clear_workspace_parent "$ws"
      ;;
    settlements)
      load_condition1_state "$state" || return 1
      sid=$STATE_SESSION_ID
      xdg=$STATE_XDG
      continued=1
      if [[ "$STATE_WORKSPACE" != "$ws" ]]; then
        echo "condition1: saved workspace $STATE_WORKSPACE is not the condition-1 workspace $ws" >&2
        return 1
      fi
      ;;
    *)
      echo "condition1: unknown upgrade $upgrade" >&2
      return 1
      ;;
  esac

  # Hand the saved values to the caller before the state file goes away. A
  # hard kill after this point cannot leave a live state for a retry.
  WS=$ws
  XDG_BASE=$xdg
  SESSION_ID=$sid
  SESSION_CONTINUED=$continued
  if [[ "$upgrade" == settlements ]]; then
    consume_condition1_state "$root"
    STATE_CONSUMED=1
  fi

  if [[ "$continued" == 1 ]]; then
    local dir
    for dir in "$xdg/data" "$xdg/state" "$xdg/cache" "$xdg/config"; do
      if [[ ! -d "$dir" ]]; then
        echo "condition1: missing XDG directory $dir" >&2
        return 1
      fi
    done
  else
    mkdir -p "$xdg/data" "$xdg/state" "$xdg/cache" "$xdg/config"
  fi

  if [[ "$continued" == 1 ]]; then
    if [[ ! -d "$ws" ]]; then
      echo "condition1: saved workspace is missing: $ws" >&2
      return 1
    fi
    # Keep the absolute path the session is attached to. Replace the contents.
    find "$ws" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  else
    rm -rf "$ws"
  fi
  mkdir -p "$ws"
  cp -a "$stage_ws/." "$ws/"
  cp "$stage/opencode.jsonc" "$ws/opencode.jsonc"
  git -C "$ws" init -q
  git -C "$ws" config user.email kalari-bench@localhost
  git -C "$ws" config user.name kalari-bench
  git -C "$ws" add -A
  git -C "$ws" commit -qm "v1 consumer"

  # The workspace must be exactly the staged tree. `.git`, the OpenCode
  # configuration and attached notes are added by the harness and excluded.
  local stage_digest workspace_digest
  stage_digest=$(python3 "$stage/tree_digest.py" "$stage_ws")
  workspace_digest=$(python3 "$stage/tree_digest.py" "$ws")
  if [[ "$stage_digest" != "$workspace_digest" ]]; then
    echo "condition1: staged workspace digest $stage_digest != workspace digest $workspace_digest" >&2
    echo "condition1: the condition-1 workspace does not hold the staged $upgrade tree" >&2
    return 1
  fi

  COND1_WORKSPACE=$ws
  COND1_XDG=$xdg
  COND1_SESSION_ID=$sid
  COND1_CONTINUED=$continued
  COND1_STAGE_DIGEST=$stage_digest
  COND1_WORKSPACE_DIGEST=$workspace_digest
  STAGE_DIGEST=$stage_digest
  WORKSPACE_DIGEST=$workspace_digest
  export COND1_WORKSPACE COND1_XDG COND1_SESSION_ID COND1_CONTINUED
  export COND1_STAGE_DIGEST COND1_WORKSPACE_DIGEST
  export WS XDG_BASE SESSION_ID SESSION_CONTINUED STAGE_DIGEST WORKSPACE_DIGEST
  return 0
}

# consume_condition1_state <root>
#
# Remove the continuation state. A retry then fails with a message that asks
# for a fresh condition-1 payouts run. That prevents a silent resume of a
# history that already contains a settlements attempt.
consume_condition1_state() {
  rm -f "$(condition1_state_path "$1")"
}
