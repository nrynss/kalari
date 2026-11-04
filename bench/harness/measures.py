"""Measures for one benchmark session, from the event log and the workspace history.

The public address and the inference key are read from the environment only so they
can be stripped. They are never written out.
"""
import argparse
import json
import os
import re
import shutil
import subprocess

IPV4 = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
HOME = re.compile(r"/home/[^/\s\"']+")
TIMEOUT_PHRASE = re.compile(
    r"timed out|timeout expired|deadline exceeded|timeoutexpired|killed by timeout|exit code 124|status[\"']?\s*[:=]\s*[\"']?timeout",
    re.I,
)
EXEC_KIND = re.compile(r"sandbox_exec(?:_start)?|sandbox_shell|sandbox_run")
PYTHON = re.compile(r"\bpython[0-9.]*\b")


def redact(text, key, ip):
    if text is None:
        return ""
    if not isinstance(text, str):
        text = json.dumps(text, default=str)
    if key:
        text = text.replace(key, "[redacted]")
    if ip:
        text = text.replace(ip, "the VM's public address")
    text = IPV4.sub("the VM's public address", text)
    text = HOME.sub("~", text)
    return text


def load_events(path):
    events, bad = [], 0
    if not path or not os.path.exists(path):
        return events, bad
    with open(path, errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except ValueError:
                bad += 1
    return events, bad


def markers(upgrade):
    if upgrade == "payouts":
        return ("/v2/payouts", "/v1/payouts")
    return ("/v2/graphql", "/v1/graphql")


def find_gitdir(xdg):
    root = os.path.join(xdg, "opencode", "snapshot")
    found = []
    if not os.path.isdir(root):
        return ""
    for dirpath, _dirs, files in os.walk(root):
        if "HEAD" in files and "config" in files:
            found.append(dirpath)
    return found[0] if found else ""


def source_at(gitdir, tree, consumer):
    if not gitdir or not tree:
        return None
    proc = subprocess.run(
        ["git", "--git-dir", gitdir, "show", f"{tree}:{consumer}"],
        capture_output=True,
    )
    if proc.returncode != 0:
        return None
    return proc.stdout.decode(errors="replace")


def extract_embedded(code, consumer, v2_marker):
    """Python source embedded in an execute script, if it looks like the consumer."""
    if not code or consumer not in code or v2_marker not in code:
        return None
    chunks = re.findall(r"`([^`]*)`", code, re.S)
    chunks += re.findall(r'"""(.*?)"""', code, re.S)
    good = [c for c in chunks if v2_marker in c and ("import " in c or "def " in c)]
    if not good:
        return None
    return max(good, key=len)


def duration_s(state):
    t = (state or {}).get("time") or {}
    start, end = t.get("start"), t.get("end")
    if isinstance(start, (int, float)) and isinstance(end, (int, float)) and end >= start:
        return (end - start) / 1000.0
    return None


def timed_out(state, capped_tool):
    status = str((state or {}).get("status") or "").lower()
    if status in {"timeout", "timed_out"}:
        return True
    out = (state or {}).get("output")
    blob = out if isinstance(out, str) else json.dumps(out or "", default=str)
    meta = json.dumps((state or {}).get("metadata") or "", default=str)
    if TIMEOUT_PHRASE.search(blob) or TIMEOUT_PHRASE.search(meta):
        return True
    if capped_tool and status not in {"", "completed"}:
        return True
    return False


def is_consumer_run(tool, inp, consumer):
    if not isinstance(inp, dict):
        return False
    if tool == "bash":
        cmd = str(inp.get("command") or "")
        return consumer in cmd and PYTHON.search(cmd) is not None
    if tool != "execute":
        return False
    code = str(inp.get("code") or "")
    if consumer not in code or PYTHON.search(code) is None:
        return False
    return EXEC_KIND.search(code) is not None or re.search(
        rf"python[0-9.]*\s+.*{re.escape(consumer)}", code
    ) is not None


def is_sandbox_command(tool, inp):
    blob = json.dumps(inp, default=str) if not isinstance(inp, str) else inp
    return tool in {"bash", "execute", "shell"} and EXEC_KIND.search(blob) is not None


def classify(src, v2_marker, v1_marker):
    if not src:
        return "unknown"
    has_v2 = v2_marker in src
    has_v1 = v1_marker in src
    if has_v2 and has_v1:
        return "v1+v2"
    if has_v2:
        return "v2"
    if has_v1:
        return "v1"
    return "unknown"


def materialize(dest, gitdir, tree, workspace, consumer, overlay):
    if os.path.isdir(dest):
        shutil.rmtree(dest)
    os.makedirs(dest)
    archived = False
    if gitdir and tree:
        tar = dest + ".tar"
        proc = subprocess.run(
            ["git", "--git-dir", gitdir, "archive", f"--output={tar}", tree],
            capture_output=True,
        )
        if proc.returncode == 0 and os.path.exists(tar):
            subprocess.run(["tar", "-C", dest, "-xf", tar], check=False)
            os.remove(tar)
            archived = True
    if not archived and workspace:
        for name in os.listdir(workspace):
            if name == ".git":
                continue
            src = os.path.join(workspace, name)
            dst = os.path.join(dest, name)
            if os.path.isdir(src):
                shutil.copytree(src, dst)
            else:
                shutil.copy2(src, dst)
    if overlay:
        path = os.path.join(dest, consumer)
        current = ""
        if os.path.exists(path):
            current = open(path, errors="replace").read()
        if overlay != current:
            with open(path, "w") as f:
                f.write(overlay)
    return dest


def note_files(workspace):
    proc = subprocess.run(
        ["git", "-C", workspace, "status", "--porcelain", "-u"],
        capture_output=True,
        text=True,
    )
    found = []
    for line in proc.stdout.splitlines():
        path = line[3:] if len(line) > 3 else ""
        if " -> " in path:
            path = path.split(" -> ", 1)[1]
        if not path or path.endswith(".py") or path.endswith(".jsonl") or path == "opencode.jsonc":
            continue
        if os.path.isfile(os.path.join(workspace, path)):
            found.append(path)
    return found


def save_notes(workspace, final_answer, dest):
    if os.path.isdir(dest):
        shutil.rmtree(dest)
    os.makedirs(dest)
    files = note_files(workspace)
    for path in files:
        target = os.path.join(dest, path)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copy2(os.path.join(workspace, path), target)
    source = "files"
    if not files and final_answer:
        with open(os.path.join(dest, "session-answer.md"), "w") as f:
            f.write(final_answer)
        files = ["session-answer.md"]
        source = "final_answer"
    return {"source": source, "files": files}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--events", required=True)
    ap.add_argument("--upgrade", required=True, choices=("payouts", "settlements"))
    ap.add_argument("--workspace", required=True)
    ap.add_argument("--xdg", required=True)
    ap.add_argument("--elapsed", type=float, required=True)
    ap.add_argument("--exit-code", type=int, required=True)
    ap.add_argument("--stderr", default="")
    ap.add_argument("--out", required=True)
    ap.add_argument("--materialize", default="")
    ap.add_argument("--notes-dir", default="")
    args = ap.parse_args()

    key = os.environ.get("KALARI_REDACT_KEY", "")
    ip = os.environ.get("KALARI_PUBLIC_IP", "")
    consumer = "payout_sync.py" if args.upgrade == "payouts" else "settlement_reconcile.py"
    v2_marker, v1_marker = markers(args.upgrade)
    events, bad_lines = load_events(args.events)
    gitdir = find_gitdir(args.xdg)
    capped = args.exit_code == 124

    session_id = ""
    current_tree = ""
    latest_embedded = None
    runs = []
    stuck = []
    tool_counts = {}
    type_counts = {}
    bash_denied = 0
    sandbox_names = []
    texts = []
    stop_ts = None
    stamps = []
    token_sum = {"steps": 0, "input": 0, "output": 0, "reasoning": 0, "cache_read": 0}
    last_reason = ""

    for ev in events:
        et = ev.get("type")
        type_counts[et] = type_counts.get(et, 0) + 1
        if ev.get("sessionID") and not session_id:
            session_id = ev["sessionID"]
        ts = ev.get("timestamp")
        if isinstance(ts, (int, float)):
            stamps.append(ts)
        part = ev.get("part") or {}
        if et == "step_start":
            current_tree = part.get("snapshot") or current_tree
        elif et == "step_finish":
            current_tree = part.get("snapshot") or current_tree
            last_reason = part.get("reason") or last_reason
            if part.get("reason") == "stop":
                stop_ts = ts
            tokens = part.get("tokens") or {}
            token_sum["steps"] += 1
            token_sum["input"] += int(tokens.get("input") or 0)
            token_sum["output"] += int(tokens.get("output") or 0)
            token_sum["reasoning"] += int(tokens.get("reasoning") or 0)
            cache = tokens.get("cache") or {}
            token_sum["cache_read"] += int(cache.get("read") or 0)
        elif et == "text":
            texts.append(part.get("text") or "")
        elif et == "tool_use":
            tool = part.get("tool") or ""
            tool_counts[tool] = tool_counts.get(tool, 0) + 1
            state = part.get("state") or {}
            inp = state.get("input") if isinstance(state.get("input"), dict) else {}
            if tool == "bash" and state.get("status") == "error":
                bash_denied += 1
            code = str(inp.get("code") or "")
            for name in re.findall(r"name\s*:\s*[\"']([^\"']+)[\"']", code):
                if name not in sandbox_names:
                    sandbox_names.append(name)
            embedded = extract_embedded(code, consumer, v2_marker)
            if embedded:
                latest_embedded = embedded
            if tool == "write" and str(inp.get("path") or "").endswith(consumer):
                content = inp.get("content")
                if isinstance(content, str) and v2_marker in content:
                    latest_embedded = content
            dur = duration_s(state)
            hung = timed_out(state, False)
            consumer_run = is_consumer_run(tool, inp, consumer)
            if hung and is_sandbox_command(tool, inp) and not consumer_run:
                stuck.append({"tool": tool, "duration_s": dur or 0.0, "consumer": False})
            if not consumer_run:
                continue
            host = source_at(gitdir, current_tree, consumer)
            chosen = host
            basis = "snapshot"
            if not (host and v2_marker in host) and latest_embedded and v2_marker in latest_embedded:
                chosen = latest_embedded
                basis = "event_log"
            version = classify(chosen, v2_marker, v1_marker)
            runs.append({
                "version": version,
                "tool": tool,
                "status": state.get("status") or "",
                "duration_s": dur,
                "timed_out": hung,
                "basis": basis,
                "snapshot": current_tree or "",
                "source": chosen or "",
            })
            if hung:
                stuck.append({"tool": tool, "duration_s": dur or 0.0, "consumer": True})

    against_v1 = sum(1 for r in runs if r["version"] in {"v1", "v1+v2"})
    against_v2 = sum(1 for r in runs if r["version"] in {"v2", "v1+v2"})
    first = next((r for r in runs if r["version"] in {"v2", "v1+v2"}), None)
    if first and args.materialize:
        # Overlay the classified consumer so a failed archive cannot grade a later edit.
        materialize(
            args.materialize,
            gitdir,
            first.get("snapshot") or "",
            args.workspace,
            consumer,
            first.get("source") or None,
        )

    if stop_ts is not None and stamps:
        wall = (stop_ts - stamps[0]) / 1000.0
    elif stamps and not capped:
        wall = (stamps[-1] - stamps[0]) / 1000.0
    else:
        wall = args.elapsed
    time_stuck = sum(s["duration_s"] for s in stuck)

    final_answer = redact("\n".join(texts).strip(), key, ip)
    if len(final_answer) > 4000:
        final_answer = final_answer[:4000] + "\n[truncated]"

    diff_stat = ""
    if os.path.isdir(os.path.join(args.workspace, ".git")):
        proc = subprocess.run(
            ["git", "-C", args.workspace, "diff", "--stat", "HEAD"],
            capture_output=True,
            text=True,
        )
        diff_stat = redact(proc.stdout.strip(), key, ip)

    stderr_excerpt = ""
    if args.stderr and os.path.exists(args.stderr):
        stderr_excerpt = redact(open(args.stderr, errors="replace").read()[-2000:], key, ip)

    notes = None
    if args.notes_dir:
        notes = save_notes(args.workspace, final_answer, args.notes_dir)

    public_runs = []
    for r in runs:
        public_runs.append({
            "version": r["version"],
            "tool": r["tool"],
            "status": r["status"],
            "duration_s": None if r["duration_s"] is None else round(r["duration_s"], 3),
            "timed_out": r["timed_out"],
            "basis": r["basis"],
        })

    out = {
        "session_id": session_id,
        "session_capped": capped,
        "opencode_exit": args.exit_code,
        "wall_time_s": round(wall, 3),
        "process_elapsed_s": round(args.elapsed, 3),
        "time_stuck_s": round(time_stuck, 3),
        "stuck_runs": stuck,
        "sandbox_runs": len(runs),
        "sandbox_runs_against_v1": against_v1,
        "sandbox_runs_against_v2": against_v2,
        "consumer_runs": public_runs,
        "first_v2": {
            "found": first is not None,
            "basis": None if first is None else first["basis"],
            "snapshot": "" if first is None else (first.get("snapshot") or ""),
        },
        "opencode_tokens": token_sum,
        "event_summary": {
            "lines": len(events),
            "unparsed_lines": bad_lines,
            "types": type_counts,
            "tools": tool_counts,
            "steps": token_sum["steps"],
            "bash_denied": bash_denied,
            "sandbox_names": sandbox_names,
            "last_reason": last_reason,
            "final_answer": final_answer,
            "stderr_excerpt": stderr_excerpt,
            "diff_stat": diff_stat,
        },
        "notes": notes,
    }
    # Drop the raw source from anything we serialize. It can contain an address.
    text = redact(json.dumps(out, indent=2), key, ip)
    with open(args.out, "w") as f:
        f.write(text)
        f.write("\n")


if __name__ == "__main__":
    main()
