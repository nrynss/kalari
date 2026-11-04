#!/usr/bin/env python3
"""Structural checks on the condition-1 production call sites.

These catch one-line edits that the resume rehearsal cannot see because it
calls the shared functions directly. The checks ignore comment-only lines, so a
commented-out call does not satisfy them. Run from the rehearsal or directly.
"""
import os
import re
import sys


def code_lines(path, errors):
    lines = []
    try:
        with open(path) as f:
            for number, line in enumerate(f, 1):
                text = line.rstrip("\n")
                if text.strip().startswith("#"):
                    continue
                lines.append((number, text))
    except OSError as e:
        errors.append(f"cannot read {path}: {e}")
    return lines


def function_body(lines, name):
    start = None
    for i, (_number, text) in enumerate(lines):
        if re.match(rf"^{re.escape(name)}\s*\(\)\s*\{{", text):
            start = i
            break
    if start is None:
        return None
    for i in range(start + 1, len(lines)):
        if lines[i][1].strip() == "}":
            return lines[start:i + 1]
    return None


def find(lines, pattern):
    found = []
    for i, (number, text) in enumerate(lines):
        if re.search(pattern, text):
            found.append((i, number, text))
    return found


def main():
    here = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
    errors = []

    remote = code_lines(os.path.join(here, "remote.sh"), errors)
    condition1 = code_lines(os.path.join(here, "condition1.sh"), errors)
    run = code_lines(os.path.join(here, "run.sh"), errors)

    # remote.sh sources the shared modules.
    for module in ("condition1.sh", "grade_one.sh"):
        pattern = rf'^\s*\.\s+"\$STAGE/{re.escape(module)}"\s*$'
        if not find(remote, pattern):
            errors.append(f"remote.sh must source {module}")

    # remote.sh has exactly one prepare_condition1 call.
    prepare = find(remote, r"^\s*prepare_condition1\s+\S")
    if len(prepare) != 1:
        errors.append(
            f"remote.sh must call prepare_condition1 exactly once, found {len(prepare)}"
        )
    else:
        index = prepare[0][0]
        banned = re.compile(r"^\s*(?:export\s+)?(WS|XDG_BASE|SESSION_ID)\s*=")
        for number, text in remote[index + 1:]:
            match = banned.match(text)
            if match:
                errors.append(
                    f"remote.sh:{number}: {match.group(1)} is assigned after prepare_condition1"
                )

    # remote.sh grades the final workspace as final and the first source as first.
    final_call = r'^\s*grade_one\s+"\$WS"\s+final\b'
    first_call = r'^\s*grade_one\s+"\$RUN/first-v2-src"\s+first\b'
    if not find(remote, final_call):
        errors.append('remote.sh must call grade_one "$WS" final')
    if not find(remote, first_call):
        errors.append('remote.sh must call grade_one "$RUN/first-v2-src" first')
    for number, text in remote:
        if re.match(r'^\s*grade_one\s+"', text):
            if not re.search(final_call, text) and not re.search(first_call, text):
                errors.append(f"remote.sh:{number}: unexpected grade_one call")

    # condition1.sh consumes the state inside prepare_condition1, after the
    # load and after the saved values are in WS, XDG_BASE and SESSION_ID.
    body = function_body(condition1, "prepare_condition1")
    if body is None:
        errors.append("condition1.sh must define prepare_condition1")
    else:
        consume = find(body, r"\bconsume_condition1_state\b")
        if len(consume) != 1:
            errors.append(
                "condition1.sh must call consume_condition1_state once inside "
                f"prepare_condition1, found {len(consume)}"
            )
        else:
            consume_index = consume[0][0]
            load = find(body, r"\bload_condition1_state\b")
            if not load or load[0][0] >= consume_index:
                errors.append(
                    "condition1.sh must consume the state after load_condition1_state"
                )
            for name in ("WS", "XDG_BASE", "SESSION_ID"):
                assigned = [
                    i for i, (_number, text) in enumerate(body)
                    if re.match(rf"^\s*{name}=", text)
                ]
                if not assigned or min(assigned) >= consume_index:
                    errors.append(
                        f"condition1.sh must set {name} before consuming the state"
                    )

    # run.sh requires the condition-1 identity and publishes the evidence.
    guard = r"\brequire_condition1_identity\s*\(\s*cond\s*,\s*upgrade\s*,\s*analysis\s*\)"
    if not find(run, guard):
        errors.append("run.sh must call require_condition1_identity uncommented")
    if not find(run, r"\bcondition1_evidence\s*\(\s*analysis\s*\)"):
        errors.append("run.sh must publish condition1_evidence(analysis)")
    if not find(run, r"\bgrading_evidence\s*\(\s*grading\s*\)"):
        errors.append("run.sh must publish grading_evidence(grading)")

    if errors:
        for error in errors:
            print(f"structure: {error}", file=sys.stderr)
        return 1
    print("structure: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
