#!/usr/bin/env python3
"""Save and require condition 1's continuation state.

Condition 1 is one OpenCode session across both upgrades. The settlements run
must resume the payouts session in the same absolute workspace, so the state
carries the session id, the XDG base and the workspace path. Anything missing
or stale is a harness error: condition 1 never silently starts a fresh session.
"""
import argparse
import json
import os
import shlex
import sqlite3
import sys
import tempfile

FIELDS = ("session_id", "xdg", "workspace", "payouts_start_digest")


def fail(message):
    print(f"continuation: {message}", file=sys.stderr)
    raise SystemExit(1)


def load(path):
    if not os.path.isfile(path):
        fail(f"condition-1 state missing: {path}")
    try:
        with open(path) as f:
            doc = json.load(f)
    except (OSError, ValueError) as e:
        fail(f"condition-1 state unreadable: {path}: {e}")
    if not isinstance(doc, dict):
        fail(f"condition-1 state incomplete: {path} is not an object")
    missing = [name for name in FIELDS if not isinstance(doc.get(name), str) or not doc[name]]
    if missing:
        fail(f"condition-1 state incomplete: {path} is missing {', '.join(missing)}")
    return doc


def check_dirs(doc):
    for name in ("workspace", "xdg"):
        path = doc[name]
        if not os.path.isabs(path):
            fail(f"condition-1 state names a relative {name}: {path}")
        if not os.path.isdir(path):
            fail(f"condition-1 state names a missing {name} directory: {path}")
    data = os.path.join(doc["xdg"], "data", "opencode")
    if not os.path.isdir(data):
        fail(f"condition-1 state names a missing OpenCode data directory: {data}")
    db = os.path.join(data, "opencode.db")
    if not os.path.isfile(db):
        fail(f"condition-1 state names a missing session database: {db}")
    return db


def check_session(doc, db):
    try:
        con = sqlite3.connect(db, timeout=5)
        try:
            row = con.execute(
                "select directory from session_v2 where id = ?", (doc["session_id"],)
            ).fetchone()
        finally:
            con.close()
    except sqlite3.Error as e:
        fail(f"condition-1 session database unreadable: {db}: {e}")
    if row is None:
        fail(f"condition-1 state names a session that is not in the database: {doc['session_id']}")
    directory = row[0] or ""
    if os.path.realpath(directory) != os.path.realpath(doc["workspace"]):
        fail(
            "condition-1 session is attached to a different directory: "
            f"{directory} != {doc['workspace']}"
        )


def cmd_check(args):
    doc = load(args.state)
    db = check_dirs(doc)
    check_session(doc, db)
    for name, value in (
        ("STATE_SESSION_ID", doc["session_id"]),
        ("STATE_XDG", doc["xdg"]),
        ("STATE_WORKSPACE", doc["workspace"]),
        ("STATE_PAYOUTS_START_DIGEST", doc["payouts_start_digest"]),
    ):
        print(f"{name}={shlex.quote(value)}")


def cmd_save(args):
    for name, value in (
        ("workspace", args.workspace),
        ("xdg", args.xdg),
    ):
        if not os.path.isabs(value) or not os.path.isdir(value):
            fail(f"{name} must be an existing absolute directory: {value}")
    if not args.session_id:
        fail("session id is empty")
    if not args.start_digest:
        fail("payouts start digest is empty")
    doc = {
        "session_id": args.session_id,
        "xdg": args.xdg,
        "workspace": args.workspace,
        # Informational only: the payouts tree before the agent edits it.
        # Nothing compares this with the settlements workspace.
        "payouts_start_digest": args.start_digest,
    }
    os.makedirs(os.path.dirname(os.path.abspath(args.state)), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(args.state)), prefix=".condition-1.")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(doc, f, indent=2)
            f.write("\n")
        os.replace(tmp, args.state)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="command", required=True)
    check = sub.add_parser("check", help="require and print the saved state as shell assignments")
    check.add_argument("--state", required=True)
    check.set_defaults(func=cmd_check)
    save = sub.add_parser("save", help="write the state after the payouts session")
    save.add_argument("--state", required=True)
    save.add_argument("--workspace", required=True)
    save.add_argument("--xdg", required=True)
    save.add_argument("--session-id", required=True)
    save.add_argument("--start-digest", required=True)
    save.set_defaults(func=cmd_save)
    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
