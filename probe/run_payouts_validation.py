#!/usr/bin/env python3
"""Real payouts validation through the authenticated broker path.

Starts a host-only Unix-socket adapter for the existing payouts handler
(bench/apis/payouts/server.py, unmodified) in a private per-run dir, plus
a host-side broker (auth via host-env reference). Runs the correct
payouts traversal (same algorithm as bench/apis/payouts/reference/
correct.py: limit 1000, follow cursor, dedupe, retry one 429) with each
page fetched through an authenticated CONNECT tunnel. The broker is the
only entry; the adapter has no TCP listener and pins its client identity
to loopback, never trusting guest headers. Auth values never leave host
env and never appear in responses, traces, logs, or this transcript.

Validates the resulting host trace with the Kalari page-observation
parser used by production run_in_sandbox
(Kalari/Tools/Run.pageObservations via probe/validate_page_trace.lean),
and shows unauthorized requests add no events.

Sanitized output only: statuses, page/retry counts, parser facts,
cleanup. No raw cursors, tokens, credentials, or personal data.
"""
import base64
import json
import os
import secrets
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
BROKER = os.path.join(HERE, "broker_unix.py")
ADAPTER = os.path.join(HERE, "payouts_unix_adapter.py")
VALIDATOR = os.path.join(HERE, "validate_page_trace.lean")
ALLOW = "127.0.0.1:18080"
TIMEOUT = 10.0

results = []


def note(name, ok, detail=""):
    results.append((name, ok, detail))
    print(f"CHECK {name}: {'PASS' if ok else 'FAIL'} {detail}".rstrip(), flush=True)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def wait_tcp(port, timeout=10.0):
    end = time.time() + timeout
    while time.time() < end:
        try:
            s = socket.create_connection(("127.0.0.1", port), timeout=1)
            s.close()
            return True
        except OSError:
            time.sleep(0.1)
    return False


def wait_unix(path, timeout=10.0):
    end = time.time() + timeout
    while time.time() < end:
        try:
            s = socket.socket(socket.AF_UNIX)
            s.settimeout(1)
            s.connect(path)
            s.close()
            return True
        except OSError:
            time.sleep(0.1)
    return False


def recv_until(s, marker, cap=1 << 20):
    data = b""
    try:
        while marker not in data:
            ch = s.recv(4096)
            if not ch:
                break
            data += ch
            if len(data) > cap:
                break
    except (socket.timeout, TimeoutError):
        pass
    return data


def read_all(s):
    data = b""
    try:
        while True:
            ch = s.recv(4096)
            if not ch:
                break
            data += ch
            if len(data) > (1 << 20):
                break
    except (socket.timeout, TimeoutError):
        pass
    return data


def split_response(block):
    # Returns (status_code:int|None, headers:dict, body:bytes)
    parts = block.split(b"\r\n\r\n", 1)
    head = parts[0] if parts else b""
    body = parts[1] if len(parts) > 1 else b""
    lines = head.decode("iso-8859-1", errors="replace").split("\r\n")
    code = None
    if lines and lines[0].startswith("HTTP/"):
        try:
            code = int(lines[0].split()[1])
        except Exception:
            code = None
    hdrs = {}
    for l in lines[1:]:
        if ":" in l:
            k, v = l.split(":", 1)
            hdrs[k.strip().lower()] = v.strip()
    return code, hdrs, body


def main():
    os.umask(0o022)
    base = tempfile.mkdtemp(prefix="kalari-payouts-")
    os.chmod(base, 0o700)
    run_dir = os.path.join(base, "run")
    os.mkdir(run_dir, 0o700)

    pw = secrets.token_hex(16)
    os.environ["KALARI_PAYOUTS_PW"] = pw
    basic = "Basic " + base64.b64encode(f"run-payouts:{pw}".encode()).decode()
    secrets_set = {pw, basic}

    def assert_clean(text, where):
        for s in secrets_set:
            if s and s in text:
                raise SystemExit(f"credential leaked in {where}")

    port = free_port()
    sock = os.path.join(run_dir, "payouts.sock")
    trace = os.path.join(run_dir, "pages.jsonl")

    procs = {}

    def spawn(name, argv, logname):
        log = open(os.path.join(run_dir, logname), "w")
        p = subprocess.Popen([sys.executable, *argv], stdout=log, stderr=subprocess.STDOUT)
        procs[name] = (p, log)
        shown = [a if a not in secrets_set else "[REDACTED]" for a in argv]
        print(f"ARGS {name}: {shown}", flush=True)
        return p

    def cleanup():
        cleaned = []
        for name, (p, log) in procs.items():
            try:
                if p.poll() is None:
                    p.terminate()
                    try:
                        p.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        p.kill()
                        p.wait(timeout=5)
                cleaned.append(f"{name}=reaped({p.poll()})")
            except Exception as ex:
                cleaned.append(f"{name}=ERROR({ex})")
            try:
                log.close()
            except Exception:
                pass
        os.environ.pop("KALARI_PAYOUTS_PW", None)
        removed = False
        try:
            shutil.rmtree(base, ignore_errors=True)
            removed = not os.path.exists(base)
        except Exception:
            pass
        print(f"CLEANUP {' '.join(cleaned)} dir-removed={removed}".rstrip(), flush=True)

    try:
        spawn("payouts-adapter", [ADAPTER, "--sock", sock, "--trace", trace], "log-adapter.txt")
        spawn("broker", [BROKER, "--port", str(port), "--user", "run-payouts",
                         "--pwenv", "KALARI_PAYOUTS_PW", "--allow", ALLOW,
                         "--sock", sock], "log-broker.txt")
        ok = wait_unix(sock) and wait_tcp(port)
        note("payouts-ready", ok, f"broker {port} adapter unix accept")
        if not ok:
            return 1

        def fetch_page(cursor):
            # One authenticated CONNECT tunnel per page, like correct.py's
            # one urlopen per page. Auth travels in the CONNECT block only;
            # the inner GET carries no credential.
            s = socket.create_connection(("127.0.0.1", port), timeout=TIMEOUT)
            s.settimeout(TIMEOUT)
            s.sendall(f"CONNECT {ALLOW} HTTP/1.1\r\nHost: {ALLOW}\r\nProxy-Authorization: {basic}\r\n\r\n".encode())
            reply = recv_until(s, b"\r\n\r\n")
            txt = reply.decode("iso-8859-1", errors="replace")
            if "200 Connection Established" not in txt:
                s.close()
                raise SystemExit(f"CONNECT refused: {txt.splitlines()[0] if txt else 'none'}")
            q = "/v2/payouts?limit=1000" + (f"&cursor={urllib.parse.quote(cursor)}" if cursor else "")
            s.sendall(f"GET {q} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".encode())
            resp = read_all(s)
            s.close()
            # Auth must never come back in a response.
            resp_text = resp.decode("iso-8859-1", errors="replace")
            for sec in secrets_set:
                if sec and sec in resp_text:
                    raise SystemExit("credential leaked into response")
            code, hdrs, body = split_response(resp)
            # Body may be shorter than Content-Length on reset; require JSON.
            try:
                doc = json.loads(body.decode("utf-8") or "{}")
            except Exception:
                raise SystemExit(f"inner page is not JSON: status={code}")
            return code, hdrs, doc

        # Correct traversal: follow cursor, dedupe, retry one 429.
        seen = set()
        rows = []
        cursor = None
        pages = 0
        retries = 0
        drained = False
        # 429 backoff: at most one retry per throttled cursor, like correct.py.
        while True:
            code, hdrs, doc = fetch_page(cursor)
            if code == 429:
                after = hdrs.get("retry-after", "1")
                try:
                    time.sleep(min(float(after or "1"), 5.0))
                except Exception:
                    time.sleep(1.0)
                code, hdrs, doc = fetch_page(cursor)
                if code == 429:
                    raise SystemExit("second 429 for the same cursor")
                retries += 1
                # The retried page must now be 200.
                if code != 200:
                    raise SystemExit(f"retry did not serve 200: {code}")
                # Fall through to handle as a page below.
            if code != 200:
                raise SystemExit(f"page fetch failed: {code} {str(doc)[:120]}")
            for p in doc.get("payouts", []):
                if p["id"] not in seen:
                    seen.add(p["id"])
                    rows.append(p)
            pages += 1
            cursor = doc.get("cursor")
            drained = bool(doc.get("drained"))
            if drained:
                break
            if pages > 100:
                raise SystemExit("traversal did not drain")
        print(f"RESP traversal: pages={pages} rows={len(rows)} retries={retries} drained={drained}", flush=True)
        note("payouts-traversal", drained and len(rows) > 0 and retries >= 1,
             f"pages={pages} rows={len(rows)} retries={retries}")
        time.sleep(1)
        trace_bytes = open(trace, "rb").read() if os.path.exists(trace) else b""
        lines = [l for l in trace_bytes.decode("utf-8", errors="replace").splitlines() if l.strip()]
        statuses = {}
        for l in lines:
            try:
                statuses[json.loads(l).get("status")] = statuses.get(json.loads(l).get("status"), 0) + 1
            except Exception:
                pass
        print(f"TRACE pages: {len(lines)} statuses={statuses}", flush=True)
        # No raw cursor or token in the trace: values are digests or IDs.
        # (IDs like po_xxxxx are public fixture IDs, not secrets.)
        has_cursor_key = any('"cursor"' in l for l in lines)
        note("payouts-trace-shape", len(lines) >= pages and not has_cursor_key,
             f"{len(lines)} events, raw-cursor-key={has_cursor_key}")

        # Validate with the production Lean parser.
        lake = shutil.which("lake") or "lake"
        env = dict(os.environ)
        env["PATH"] = os.path.expanduser("~/.elan/bin") + ":" + env.get("PATH", "")
        r = subprocess.run([lake, "env", "lean", "--run", VALIDATOR, trace],
                           capture_output=True, text=True, timeout=120, cwd=HERE + "/..",
                           env=env)
        out = (r.stdout or "") + (r.stderr or "")
        # The validator prints only VALID [...] or INVALID ...; never the trace.
        print(f"RESP parser: {r.stdout.strip().splitlines()[-1] if r.stdout.strip() else 'none'} rc={r.returncode}", flush=True)
        valid = r.returncode == 0 and "VALID" in (r.stdout or "")
        note("payouts-parser", valid, "Lean pageObservations accepts the trace")
        if not valid:
            print(f"PARSER detail: {out[-500:]}", flush=True)
            return 1

        # Unauthorized requests add no events.
        before = open(trace, "rb").read()

        def unauth(label, connect_bytes):
            s = socket.create_connection(("127.0.0.1", port), timeout=TIMEOUT)
            s.settimeout(TIMEOUT)
            s.sendall(connect_bytes)
            tail = recv_until(s, b"\r\n\r\n")
            s.close()
            st = tail.decode("iso-8859-1", errors="replace").split("\r\n")[0] if tail else "<closed>"
            print(f"RESP {label}: {st}", flush=True)
            return st

        wrong_basic = "Basic d3JvbmdjcmVkZW50aWFscw=="
        s1 = unauth("unauth-wrong", f"CONNECT {ALLOW} HTTP/1.1\r\nHost: {ALLOW}\r\nProxy-Authorization: {wrong_basic}\r\n\r\n".encode())
        s2 = unauth("unauth-missing", f"CONNECT {ALLOW} HTTP/1.1\r\nHost: {ALLOW}\r\n\r\n".encode())
        # Wrong dest with correct auth.
        s = socket.create_connection(("127.0.0.1", port), timeout=TIMEOUT)
        s.settimeout(TIMEOUT)
        s.sendall(f"CONNECT 127.0.0.1:19999 HTTP/1.1\r\nHost: x\r\nProxy-Authorization: {basic}\r\n\r\n".encode())
        tail = recv_until(s, b"\r\n\r\n")
        s.close()
        s3 = tail.decode("iso-8859-1", errors="replace").split("\r\n")[0] if tail else "<closed>"
        print(f"RESP unauth-dest: {s3}", flush=True)
        time.sleep(1)
        after = open(trace, "rb").read()
        no_growth = after == before
        no_200 = all("200 OK" not in s for s in (s1, s2, s3))
        note("payouts-unauth-closed", no_growth and no_200 and "407" in s1 and "407" in s2 and "403" in s3,
             f"wrong={s1} missing={s2} dest={s3} stable={no_growth}")

        # Logs and responses carry no credentials; socket/dir modes.
        logs = ""
        for fn in ("log-adapter.txt", "log-broker.txt"):
            p = os.path.join(run_dir, fn)
            if os.path.exists(p):
                logs += open(p).read()
        leaked = any(sec and sec in logs for sec in secrets_set) or "Basic " in logs
        mode_sock = oct(stat.S_IMODE(os.stat(sock).st_mode))
        mode_dir = oct(stat.S_IMODE(os.stat(run_dir).st_mode))
        print(f"TRACE modes: sock={mode_sock} dir={mode_dir}", flush=True)
        note("payouts-hygiene", (not leaked) and (mode_sock, mode_dir) == ("0o600", "0o700"),
             f"leaked={leaked} sock={mode_sock} dir={mode_dir}")
    finally:
        cleanup()

    failed = [n for n, ok, _ in results if not ok]
    print(f"RESULT: {'PASS' if not failed else 'FAIL'} {len(results) - len(failed)}/{len(results)}", flush=True)
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
