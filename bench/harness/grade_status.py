#!/usr/bin/env python3
"""Classify one hidden-grader pass from its status line and fresh output.

`grade_runner.py` prints `EXIT <rc>`, `EXIT timeout` or `EXIT launch`; the
harness prints `EXIT create` and friends when the sandbox or copy fails.
`timeout` is a consumer crash; `launch` means the consumer could not be started
at all, which is a grader failure. Only `/w/out.jsonl` copied out of the fresh
guest is graded. A file that happens to sit in the agent's workspace is never a
fallback for a missing or crashed run.
"""
import argparse
import json
import os
import re

GRADER_FAILURES = {
    "create",
    "mkdir",
    "tar",
    "copy",
    "copy-runner",
    "untar",
    # `grade_runner.py` prints this when it cannot start the consumer at all.
    # That is a grading/harness failure, not agent behaviour.
    "launch",
}
STATUS = re.compile(r"^EXIT\s+(\S+)\s*$")


def classify(status_text, fresh_output, workspace, output_name, exec_rc, pass_name):
    output_present = os.path.isfile(fresh_output) and os.path.getsize(fresh_output) > 0
    size = os.path.getsize(fresh_output) if os.path.isfile(fresh_output) else None
    stale = bool(output_name) and os.path.isfile(os.path.join(workspace, output_name))
    stale_ignored = stale and not output_present
    suffix = f"; stale workspace {output_name} ignored" if stale_ignored else ""

    value = None
    for line in status_text.splitlines():
        match = STATUS.match(line.strip())
        if match:
            value = match.group(1)
            break

    if value is None:
        return {
            "pass": pass_name,
            "consumer_exit": None,
            "grader_exit": None,
            "output_present": output_present,
            "output_bytes": size,
            "grade_status": "grader_failed",
            "stale_output_ignored": stale_ignored,
            "exec_rc": exec_rc,
            "note": f"grader failed: no EXIT status (exec rc={exec_rc}){suffix}",
        }

    if value in GRADER_FAILURES:
        return {
            "pass": pass_name,
            "consumer_exit": None,
            "grader_exit": value,
            "output_present": output_present,
            "output_bytes": size,
            "grade_status": "grader_failed",
            "stale_output_ignored": stale_ignored,
            "exec_rc": exec_rc,
            "note": f"grader failed: EXIT {value}{suffix}",
        }

    if value == "timeout":
        return {
            "pass": pass_name,
            "consumer_exit": "timeout",
            "grader_exit": None,
            "output_present": output_present,
            "output_bytes": size,
            "grade_status": "consumer_crashed",
            "stale_output_ignored": stale_ignored,
            "exec_rc": exec_rc,
            "note": "consumer timed out (EXIT timeout)" + suffix,
        }

    try:
        code = int(value)
    except ValueError:
        return {
            "pass": pass_name,
            "consumer_exit": None,
            "grader_exit": value,
            "output_present": output_present,
            "output_bytes": size,
            "grade_status": "grader_failed",
            "stale_output_ignored": stale_ignored,
            "exec_rc": exec_rc,
            "note": f"grader failed: unrecognised status EXIT {value}{suffix}",
        }

    if code == 0:
        if output_present:
            return {
                "pass": pass_name,
                "consumer_exit": 0,
                "grader_exit": None,
                "output_present": True,
                "output_bytes": size,
                "grade_status": "ok",
                "stale_output_ignored": stale_ignored,
                "exec_rc": exec_rc,
                "note": "grading ran on fresh output",
            }
        return {
            "pass": pass_name,
            "consumer_exit": 0,
            "grader_exit": None,
            "output_present": False,
            "output_bytes": None,
            "grade_status": "no_output",
            "stale_output_ignored": stale_ignored,
            "exec_rc": exec_rc,
            "note": f"no consumer output (consumer exited 0){suffix}",
        }

    detail = "partial output graded" if output_present else "no consumer output"
    return {
        "pass": pass_name,
        "consumer_exit": code,
        "grader_exit": None,
        "output_present": output_present,
        "output_bytes": size,
        "grade_status": "consumer_crashed",
        "stale_output_ignored": stale_ignored,
        "exec_rc": exec_rc,
        "note": f"consumer crashed: EXIT {code}; {detail}{suffix}",
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--status", required=True)
    ap.add_argument("--fresh-output", required=True)
    ap.add_argument("--workspace", required=True)
    ap.add_argument("--output-name", required=True)
    ap.add_argument("--exec-rc", type=int, required=True)
    ap.add_argument("--pass", dest="pass_name", required=True, choices=("final", "first"))
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    text = ""
    if os.path.exists(args.status):
        with open(args.status, errors="replace") as f:
            text = f.read()
    doc = classify(
        text, args.fresh_output, args.workspace, args.output_name, args.exec_rc, args.pass_name
    )
    # The directory this pass checked for a stale output. remote.sh passes the
    # agent workspace for the final pass and the first-source tree for the
    # first pass, because that is the only place the first pass could be stale.
    doc["workspace_checked"] = args.workspace
    with open(args.out, "w") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
