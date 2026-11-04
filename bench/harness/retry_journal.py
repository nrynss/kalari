#!/usr/bin/env python3
"""Trusted retry measurement from the API servers' host-owned retry journals.

Each API server writes one JSON event per request to a journal on its own
microVM: timestamp, keyed client digest, HTTP status, request fingerprint
digest, traversal digest, and whether the request was a retry candidate or the
matching retry. The journal never holds a raw cursor, a raw request or a token.

The harness truncates every journal at the start of a phase and reads it at the
end, so agent activity and grading activity are counted apart. A missing
journal, a failed truncation or a malformed event is `unknown` with null
counts, never zero. HTTP retries inside one consumer process are not sandbox
runs.

Usage:
  retry_journal.py truncate --remote NAME=PATH [--remote ...] [--out FILE]
  retry_journal.py read --phase agent --truncated FILE --remote NAME=PATH ... [--out FILE]
  retry_journal.py read --phase agent --local NAME=FILE --out FILE

`--remote NAME=PATH` runs `msb exec NAME` on the VM. `--local NAME=FILE` reads
a journal file directly, for offline checks.
"""
import argparse
import json
import os
import subprocess
import sys

REQUIRED = (
    "t", "client", "api", "status", "request", "traversal",
    "throttled", "matching_retry", "retry_candidate",
)
COUNTS = ("requests", "b5_429_responses", "matching_retry_attempts", "successful_matching_retries")

TRUNCATE = (
    "import os,sys\n"
    "p=sys.argv[1]\n"
    "if not os.path.exists(p):\n"
    "    print('missing'); raise SystemExit(0)\n"
    "open(p,'w').close()\n"
    "print('truncated')\n"
)
READ = (
    "import json,os,sys\n"
    "p=sys.argv[1]\n"
    "if not os.path.exists(p):\n"
    "    print(json.dumps({'present': False})); raise SystemExit(0)\n"
    "print(json.dumps({'present': True, 'events': [json.loads(l) for l in open(p) if l.strip()]}))\n"
)


def parse_targets(values, flag):
    targets = []
    for value in values or []:
        if "=" not in value:
            raise SystemExit(f"{flag} wants NAME=PATH, got {value!r}")
        name, path = value.split("=", 1)
        if not name or not path:
            raise SystemExit(f"{flag} wants NAME=PATH, got {value!r}")
        targets.append((name, path))
    return targets


def guest(name, code, path):
    proc = subprocess.run(
        ["msb", "exec", name, "--", "python3", "-c", code, path],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        return None, (proc.stderr or proc.stdout or f"msb exec exit {proc.returncode}").strip()[:300]
    return proc.stdout.strip(), None


def truncate(targets):
    results = {}
    for name, path in targets:
        out, error = guest(name, TRUNCATE, path)
        results[name] = {
            "status": out or "failed",
            "path": path,
            "error": error,
        }
    return {"phase_start": "truncated", "journals": results}


def read_docs(targets, local):
    docs = []
    for name, path in targets:
        if local:
            if not os.path.exists(path):
                docs.append((name, {"present": False}))
                continue
            events = []
            try:
                with open(path, errors="replace") as f:
                    for line in f:
                        if line.strip():
                            events.append(json.loads(line))
            except ValueError as e:
                docs.append((name, {"present": True, "error": f"unreadable journal: {e}"}))
                continue
            docs.append((name, {"present": True, "events": events}))
            continue
        out, error = guest(name, READ, path)
        if error is not None:
            docs.append((name, {"present": False, "error": error}))
            continue
        try:
            docs.append((name, json.loads(out)))
        except ValueError:
            docs.append((name, {"present": True, "error": "journal read did not return JSON"}))
    return docs


def summarize(phase, docs, truncated):
    apis, unknown = {}, []
    allowed = (truncated or {}).get("journals") or {}
    totals = {key: 0 for key in COUNTS}
    for name, doc in docs:
        start = allowed.get(name) or {}
        if start.get("status") != "truncated":
            reason = "journal missing" if start.get("status") == "missing" else "journal not truncated at phase start"
            apis[name] = {"status": "unknown", "reason": reason, **{key: None for key in COUNTS}}
            unknown.append(name)
            continue
        if not doc.get("present") or doc.get("error"):
            apis[name] = {
                "status": "unknown",
                "reason": doc.get("error") or "journal missing",
                **{key: None for key in COUNTS},
            }
            unknown.append(name)
            continue
        events = doc.get("events")
        if not isinstance(events, list):
            apis[name] = {"status": "unknown", "reason": "journal has no events list",
                          **{key: None for key in COUNTS}}
            unknown.append(name)
            continue
        bad = [
            e for e in events
            if not isinstance(e, dict) or any(key not in e for key in REQUIRED)
        ]
        if bad:
            apis[name] = {"status": "unknown", "reason": f"{len(bad)} malformed events",
                          **{key: None for key in COUNTS}}
            unknown.append(name)
            continue
        counts = {
            "requests": len(events),
            "b5_429_responses": sum(1 for e in events if e["throttled"] is True),
            "matching_retry_attempts": sum(1 for e in events if e["retry_candidate"] is True),
            "successful_matching_retries": sum(1 for e in events if e["matching_retry"] is True),
        }
        inconsistent = (
            counts["successful_matching_retries"] > counts["matching_retry_attempts"]
            or any(e["matching_retry"] is True and e["throttled"] is True for e in events)
        )
        if inconsistent:
            apis[name] = {"status": "unknown", "reason": "journal counts disagree",
                          **{key: None for key in COUNTS}}
            unknown.append(name)
            continue
        apis[name] = {"status": "ok", "clients": len({e["client"] for e in events}), **counts}
        for key in COUNTS:
            totals[key] += counts[key]
    out = {"phase": phase, "status": "ok" if not unknown else "unknown"}
    if unknown:
        out["reason"] = "unknown journals: " + ", ".join(unknown)
        out.update({key: None for key in COUNTS})
    else:
        out.update(totals)
        out["clients"] = len({
            event["client"]
            for _name, doc in docs
            for event in doc.get("events") or []
        })
    out["apis"] = apis
    return out


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="command", required=True)

    t = sub.add_parser("truncate")
    t.add_argument("--remote", action="append", default=[])
    t.add_argument("--out")

    r = sub.add_parser("read")
    r.add_argument("--phase", required=True, choices=("agent", "grading"))
    r.add_argument("--remote", action="append", default=[])
    r.add_argument("--local", action="append", default=[])
    r.add_argument("--truncated")
    r.add_argument("--out")

    a = ap.parse_args()
    if a.command == "truncate":
        result = truncate(parse_targets(a.remote, "--remote"))
        text = json.dumps(result, indent=2, sort_keys=True) + "\n"
        if a.out:
            os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
            with open(a.out, "w") as f:
                f.write(text)
        sys.stdout.write(text)
        return 0

    local = bool(a.local)
    targets = parse_targets(a.local if local else a.remote, "--local" if local else "--remote")
    truncated = None
    if a.truncated:
        try:
            with open(a.truncated) as f:
                truncated = json.load(f)
        except (OSError, ValueError):
            truncated = None
    if local and truncated is None:
        # A local journal is read directly: the caller is the phase boundary.
        truncated = {"journals": {name: {"status": "truncated"} for name, _path in targets}}
    result = summarize(a.phase, read_docs(targets, local), truncated)
    text = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if a.out:
        os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
        with open(a.out, "w") as f:
            f.write(text)
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
