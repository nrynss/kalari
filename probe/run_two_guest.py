#!/usr/bin/env python3
"""Two-guest isolation runner for the probe broker (issues 2 and 3).

Local loopback only. No microVM, no VM writes. Passwords live in host
environment variables only and are never printed, logged, or written to
any file. Unix sockets live in a private per-run directory (mode 700)
with socket files at mode 600.

Checks:
 1. Guest A reaches its API via its broker; trace A holds its GET.
 2. Guest B reaches its API via its broker; traces stay separate.
 3. Wrong user, missing auth, wrong dest, and non-CONNECT fail closed
    with no trace growth.
 4. Empty close and incomplete tunnel write nothing (issue 2): no
    observation, no inner 200, no /empty line.
 5. Both runs live at once; traces stay separate.
 6. Owner-death: killing broker A (observer still running) fails closed;
    broker B keeps serving.
 7. Socket/dir modes, logs free of passwords, mini_proxy redaction.
 8. Real observer traces pass parser checks.

Output is sanitized: creation args show env names (never values),
responses show status lines and canned-body lengths, traces show counts
and request lines, cleanup shows reaped processes and dir removal.
"""
import argparse
import base64
import os
import re
import secrets
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
BROKER = os.path.join(HERE, "broker_unix.py")
OBS = os.path.join(HERE, "obs_unix.py")
PROXY = os.path.join(HERE, "mini_proxy.py")
ORIGIN = os.path.join(HERE, "mini_origin.py")

ALLOW = "127.0.0.1:18080"
TIMEOUT = 5.0
TRACE_RE = re.compile(r"^[A-Z]+ \S+ HTTP/\d(\.\d)?$")

results = []


def note(name, ok, detail=""):
    results.append((name, ok, detail))
    print(f"CHECK {name}: {'PASS' if ok else 'FAIL'} {detail}".rstrip(), flush=True)


def sanitize_argv(argv, secrets_set):
    out = []
    for a in argv:
        out.append("[REDACTED]" if a in secrets_set else a)
    return out


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


def recv_until(s, marker, cap=65536):
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
    except (socket.timeout, TimeoutError):
        pass
    return data


def status_line(block):
    txt = block.decode("iso-8859-1", errors="replace")
    return txt.split("\r\n")[0] if txt else ""


def trace_lines(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return f.read().splitlines()


def wait_trace(path, n, timeout=10.0):
    end = time.time() + timeout
    while time.time() < end:
        if len(trace_lines(path)) >= n:
            return True
        time.sleep(0.1)
    return False


def check_trace_file(path):
    lines = trace_lines(path)
    for ln in lines:
        if not ln.strip():
            return False, "blank line"
        if "/empty" in ln:
            return False, "invented /empty line"
        if not TRACE_RE.match(ln):
            return False, f"bad request line: {ln[:60]}"
    return True, f"{len(lines)} lines"


def basic(user, pw):
    return "Basic " + base64.b64encode(f"{user}:{pw}".encode()).decode()


def connect_tunnel(port, user, pw, dest, no_auth=False):
    s = socket.create_connection(("127.0.0.1", port), timeout=TIMEOUT)
    s.settimeout(TIMEOUT)
    req = f"CONNECT {dest} HTTP/1.1\r\nHost: {dest}\r\n"
    if not no_auth and pw is not None:
        req += f"Proxy-Authorization: {basic(user, pw)}\r\n"
    req += "\r\n"
    s.sendall(req.encode())
    reply = recv_until(s, b"\r\n\r\n")
    return s, status_line(reply)


def inner_get(s, path):
    s.sendall(f"GET {path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".encode())
    return read_all(s)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep", action="store_true", help="keep run dir for inspection")
    args = ap.parse_args()

    run_dir = tempfile.mkdtemp(prefix="kalari-probe-")
    os.chmod(run_dir, 0o700)
    assert stat.S_IMODE(os.stat(run_dir).st_mode) == 0o700, "run dir not private"

    pw_a = secrets.token_hex(16)
    pw_b = secrets.token_hex(16)
    os.environ["KALARI_PROBE_PW_A"] = pw_a
    os.environ["KALARI_PROBE_PW_B"] = pw_b
    secrets_set = {pw_a, pw_b, basic("run-a", pw_a), basic("run-b", pw_b)}

    port_a = free_port()
    port_b = free_port()
    port_o = free_port()
    port_p = free_port()
    sock_a = os.path.join(run_dir, "obs-a.sock")
    sock_b = os.path.join(run_dir, "obs-b.sock")
    trace_a = os.path.join(run_dir, "trace-a.log")
    trace_b = os.path.join(run_dir, "trace-b.log")
    for t in (trace_a, trace_b):
        open(t, "w").close()

    procs = {}

    def spawn(name, argv, logname):
        log = open(os.path.join(run_dir, logname), "w")
        p = subprocess.Popen([sys.executable, *argv], stdout=log, stderr=subprocess.STDOUT)
        procs[name] = (p, log)
        print(f"ARGS {name}: {sanitize_argv(argv, secrets_set)}", flush=True)
        return p

    try:
        spawn("obs-a", [OBS, "--sock", sock_a, "--trace", trace_a], "log-obs-a.txt")
        spawn("obs-b", [OBS, "--sock", sock_b, "--trace", trace_b], "log-obs-b.txt")
        spawn("broker-a", [BROKER, "--port", str(port_a), "--user", "run-a",
                            "--pwenv", "KALARI_PROBE_PW_A", "--allow", ALLOW,
                            "--sock", sock_a], "log-broker-a.txt")
        spawn("broker-b", [BROKER, "--port", str(port_b), "--user", "run-b",
                            "--pwenv", "KALARI_PROBE_PW_B", "--allow", ALLOW,
                            "--sock", sock_b], "log-broker-b.txt")
        spawn("origin", [ORIGIN, str(port_o)], "log-origin.txt")
        spawn("proxy", [PROXY, str(port_p), str(port_o)], "log-proxy.txt")

        ok = wait_unix(sock_a) and wait_unix(sock_b)
        note("obs-ready", ok, "both unix observers accept")
        ok = wait_tcp(port_a) and wait_tcp(port_b) and wait_tcp(port_p)
        note("broker-ready", ok, f"ports {port_a} {port_b} proxy {port_p}")

        mode_a = stat.S_IMODE(os.stat(sock_a).st_mode)
        mode_b = stat.S_IMODE(os.stat(sock_b).st_mode)
        note("sock-mode", (mode_a, mode_b) == (0o600, 0o600),
             f"obs-a.sock={oct(mode_a)} obs-b.sock={oct(mode_b)} dir=0o700")

        # C1: guest A round trip.
        s, st = connect_tunnel(port_a, "run-a", pw_a, ALLOW)
        print(f"RESP c1-connect: {st}", flush=True)
        c1 = st == "HTTP/1.1 200 Connection Established"
        resp = inner_get(s, "/a1")
        s.close()
        st2 = status_line(resp)
        print(f"RESP c1-inner: {st2} len={len(resp)}", flush=True)
        c1 = c1 and st2 == "HTTP/1.1 200 OK" and wait_trace(trace_a, 1)
        la, lb = trace_lines(trace_a), trace_lines(trace_b)
        c1 = c1 and la == ["GET /a1 HTTP/1.1"] and lb == []
        note("guest-a", c1, f"trace-a={len(la)} trace-b={len(lb)}")
        print(f"TRACE trace-a: {len(la)} lines last={la[-1] if la else '-'}", flush=True)

        # C2: guest B round trip; traces stay separate.
        s, st = connect_tunnel(port_b, "run-b", pw_b, ALLOW)
        c2 = st == "HTTP/1.1 200 Connection Established"
        print(f"RESP c2-connect: {st}", flush=True)
        resp = inner_get(s, "/b1")
        s.close()
        st2 = status_line(resp)
        print(f"RESP c2-inner: {st2} len={len(resp)}", flush=True)
        c2 = c2 and st2 == "HTTP/1.1 200 OK" and wait_trace(trace_b, 1)
        la, lb = trace_lines(trace_a), trace_lines(trace_b)
        c2 = c2 and la == ["GET /a1 HTTP/1.1"] and lb == ["GET /b1 HTTP/1.1"]
        note("guest-b", c2, f"trace-a={len(la)} trace-b={len(lb)}")

        # C3: fail-closed variants, no trace growth.
        before = (len(la), len(lb))
        s, st = connect_tunnel(port_a, "run-a", "wrong-password", ALLOW)
        s.close()
        r1 = st == "HTTP/1.1 407 Proxy Authentication Required"
        print(f"RESP wrong-user: {st}", flush=True)
        s, st = connect_tunnel(port_a, "run-a", None, ALLOW, no_auth=True)
        s.close()
        r2 = st == "HTTP/1.1 407 Proxy Authentication Required"
        print(f"RESP missing-auth: {st}", flush=True)
        s, st = connect_tunnel(port_a, "run-a", pw_a, "127.0.0.1:19999")
        s.close()
        r3 = st == "HTTP/1.1 403 Forbidden"
        print(f"RESP wrong-dest: {st}", flush=True)
        s = socket.create_connection(("127.0.0.1", port_a), timeout=TIMEOUT)
        s.settimeout(TIMEOUT)
        s.sendall(b"GET / HTTP/1.0\r\n\r\n")
        st = status_line(recv_until(s, b"\r\n\r\n"))
        s.close()
        r4 = st == "HTTP/1.1 405 Method Not Allowed"
        print(f"RESP no-connect: {st}", flush=True)
        la, lb = trace_lines(trace_a), trace_lines(trace_b)
        r5 = (len(la), len(lb)) == before
        note("fail-closed", all([r1, r2, r3, r4, r5]),
             f"407/407/403/405 traces={len(la)}/{len(lb)}")

        # C4: issue 2 regression — empty close writes nothing, no inner 200.
        snap_a = open(trace_a, "rb").read()
        snap_b = open(trace_b, "rb").read()
        s, st = connect_tunnel(port_a, "run-a", pw_a, ALLOW)
        e1 = st == "HTTP/1.1 200 Connection Established"
        s.shutdown(socket.SHUT_WR)  # empty tunnel: no inner bytes at all
        tail = read_all(s)
        s.close()
        e1 = e1 and tail == b""
        print(f"RESP empty-close-tail: {len(tail)} bytes", flush=True)
        time.sleep(1)
        e2 = open(trace_a, "rb").read() == snap_a and open(trace_b, "rb").read() == snap_b
        # Incomplete tunnel: partial headers then close.
        s, st = connect_tunnel(port_b, "run-b", pw_b, ALLOW)
        e3 = st == "HTTP/1.1 200 Connection Established"
        s.sendall(b"GET /partial")
        s.shutdown(socket.SHUT_WR)
        tail = read_all(s)
        s.close()
        e3 = e3 and tail == b""
        print(f"RESP incomplete-close-tail: {len(tail)} bytes", flush=True)
        time.sleep(1)
        e4 = open(trace_a, "rb").read() == snap_a and open(trace_b, "rb").read() == snap_b
        e5 = "/empty" not in open(trace_a).read() and "/empty" not in open(trace_b).read()
        note("empty-close", all([e1, e2, e3, e4, e5]),
             "no observation, no inner bytes, no /empty")

        # C5: both runs live at once.
        sa, sta = connect_tunnel(port_a, "run-a", pw_a, ALLOW)
        sb, stb = connect_tunnel(port_b, "run-b", pw_b, ALLOW)
        c5 = sta == stb == "HTTP/1.1 200 Connection Established"
        sa.sendall(b"GET /a2 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        sb.sendall(b"GET /b2 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        ra, rb = read_all(sa), read_all(sb)
        sa.close()
        sb.close()
        c5 = c5 and status_line(ra) == status_line(rb) == "HTTP/1.1 200 OK"
        c5 = c5 and wait_trace(trace_a, 2) and wait_trace(trace_b, 2)
        la, lb = trace_lines(trace_a), trace_lines(trace_b)
        c5 = c5 and la == ["GET /a1 HTTP/1.1", "GET /a2 HTTP/1.1"]
        c5 = c5 and lb == ["GET /b1 HTTP/1.1", "GET /b2 HTTP/1.1"]
        note("two-live", c5, f"trace-a={len(la)} trace-b={len(lb)}")

        # C5b: bytes buffered after CONNECT are preserved (pipelined send).
        s = socket.create_connection(("127.0.0.1", port_a), timeout=TIMEOUT)
        s.settimeout(TIMEOUT)
        s.sendall((f"CONNECT {ALLOW} HTTP/1.1\r\nHost: {ALLOW}\r\n"
                   f"Proxy-Authorization: {basic('run-a', pw_a)}\r\n\r\n"
                   f"GET /pipe HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n").encode())
        resp = read_all(s)
        s.close()
        txt = resp.decode("iso-8859-1", errors="replace")
        c5b = "200 Connection Established" in txt and txt.count("200 OK") == 1
        c5b = c5b and wait_trace(trace_a, 3)
        la = trace_lines(trace_a)
        c5b = c5b and la[-1] == "GET /pipe HTTP/1.1"
        print(f"RESP pipelined: established+inner-200 trace-a={len(la)}", flush=True)
        note("pipelined", c5b, "CONNECT+GET in one segment observed once")

        # C6: owner-death — kill broker A while observer A runs.
        pa, _ = procs["broker-a"]
        pa.terminate()
        pa.wait(timeout=10)
        dead = pa.poll() is not None
        nlines_a = len(trace_lines(trace_a))
        try:
            s = socket.create_connection(("127.0.0.1", port_a), timeout=TIMEOUT)
            s.close()
            refused = False
        except OSError:
            refused = True
        time.sleep(1)
        same = len(trace_lines(trace_a)) == nlines_a
        mode_a = stat.S_IMODE(os.stat(sock_a).st_mode)
        s, st = connect_tunnel(port_b, "run-b", pw_b, ALLOW)
        alive = st == "HTTP/1.1 200 Connection Established"
        resp = inner_get(s, "/b3")
        s.close()
        alive = alive and status_line(resp) == "HTTP/1.1 200 OK" and wait_trace(trace_b, 3)
        note("owner-death", dead and refused and same and mode_a == 0o600 and alive,
             f"broker-a reaped={dead} refused={refused} trace-stable={same} "
             f"sock={oct(mode_a)} broker-b alive={alive}")

        # C7: mini_proxy redaction.
        s = socket.create_connection(("127.0.0.1", port_p), timeout=TIMEOUT)
        s.settimeout(TIMEOUT)
        s.sendall(f"GET http://127.0.0.1/ HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                  f"Proxy-Authorization: {basic('run-a', pw_a)}\r\n\r\n".encode())
        resp = read_all(s)
        s.close()
        time.sleep(0.5)
        plog = open(os.path.join(run_dir, "log-proxy.txt")).read()
        leaked = any(secret in plog for secret in secrets_set) or pw_a in plog or pw_b in plog
        redacted = "[REDACTED]" in plog
        print(f"RESP proxy-origin: {status_line(resp)} len={len(resp)}", flush=True)
        note("proxy-redact", (not leaked) and redacted,
             f"leaked={leaked} redacted-marker={redacted}")

        # C8: logs hold no passwords; traces hold only request lines.
        logs = ""
        for fn in ("log-obs-a.txt", "log-obs-b.txt", "log-broker-a.txt",
                   "log-broker-b.txt", "log-origin.txt", "log-proxy.txt"):
            logs += open(os.path.join(run_dir, fn)).read()
        noleak = not any(secret in logs for secret in secrets_set)
        noleak = noleak and "Basic " not in logs.replace("[REDACTED]", "XX") and pw_a not in logs
        oka, da = check_trace_file(trace_a)
        okb, db = check_trace_file(trace_b)
        print(f"TRACE trace-a: {da} lines={trace_lines(trace_a)}", flush=True)
        print(f"TRACE trace-b: {db} lines={trace_lines(trace_b)}", flush=True)
        note("no-password-in-logs", noleak, "6 logs scanned")
        note("trace-parser", oka and okb, f"a: {da}; b: {db}")
    finally:
        # Cleanup: reap every child, then remove the run dir unless kept.
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
        for var in ("KALARI_PROBE_PW_A", "KALARI_PROBE_PW_B"):
            os.environ.pop(var, None)
        removed = False
        if not args.keep:
            shutil.rmtree(run_dir, ignore_errors=True)
            removed = not os.path.exists(run_dir)
        print(f"CLEANUP {' '.join(cleaned)} dir-removed={removed} kept={args.keep}", flush=True)

    failed = [n for n, ok, _ in results if not ok]
    print(f"RESULT: {'PASS' if not failed else 'FAIL'} {len(results) - len(failed)}/{len(results)}", flush=True)
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
