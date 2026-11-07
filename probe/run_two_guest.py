#!/usr/bin/env python3
"""Local broker regression suite for the probe transport (issues 2 and 3).

Loopback clients only, not microVMs: two broker+observer pairs run on
127.0.0.1 with private Unix sockets, exercised by plain TCP clients.
No microVM, no VM writes, no agent sessions, no inference. Passwords live in host
environment variables only and are never printed, logged, or written to
any file. Unix sockets live in a private per-run directory (mode 700)
with socket files at mode 600.

Checks:
 1. Client A reaches its API via its broker; trace A holds its GET.
 2. Client B reaches its API via its broker; traces stay separate.
 3. Wrong user, missing auth, wrong dest, and non-CONNECT fail closed
    with no trace growth.
 4. Empty close and incomplete tunnel write nothing (issue 2): no
    observation, no inner 200, no /empty line.
 4b. Oversize CONNECT and oversize inner fail 400 with zero trace
    growth (16 KiB header cap).
 4c. Framing refusals fail 400 with zero trace growth and no inner 200:
     any Transfer-Encoding, duplicate Content-Length (even identical),
     invalid or over-cap lengths, malformed request/header lines, and
     other unsupported framing. Includes Repro A (chunked incomplete)
     and Repro B (conflicting lengths).
 4d. Total deadline: a slow inner-header drip that stays under the
     per-read timeout but exceeds the total cap fails with an explicit
     408, zero trace growth, and no inner 200.
 4d2. Slow CONNECT drip before 200: the same shape on the CONNECT
     block fails with an explicit 408, zero trace growth, and no 200.
 4d3. Slow POST body drip: headers arrive fast, the body drips past
     the total cap, failing with an explicit 408, zero trace growth,
     and no inner 200.
 4e. Upstream truncation: an oversize, hung, or truncated upstream
     response fails with an explicit 502; no silent partial is ever
     forwarded and no inner 200 is returned.
 4e2. Close-delimited upstream: a response without Content-Length
     read until close forwards complete (200, exact bytes); an
     oversize close-delimited response fails with an explicit 502 and
     no partial leak. Total expiry after handoff maps to 502 by design
     (pre-contact expiry is 408; the send/handoff micro-window is 502
     with no observation and no partial).
 5. Both runs live at once; traces stay separate.
 5b. Bytes buffered after CONNECT are preserved (pipelined send).
 6. Broker-death: killing broker A (observer still running) fails closed;
     broker B keeps serving. This is a broker-only kill, not an owner
     SIGKILL test; see probe/owner_death.py for true owner death.
 7. Socket/dir modes, logs free of passwords, mini_proxy redaction.
 8. Probe trace spot checks (request-line shape only, not the Kalari
     page-observation parser in Kalari/Tools/Run.lean).

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
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
BROKER = os.path.join(HERE, "broker_unix.py")
OBS = os.path.join(HERE, "obs_unix.py")
PROXY = os.path.join(HERE, "mini_proxy.py")
ORIGIN = os.path.join(HERE, "mini_origin.py")

ALLOW = "127.0.0.1:18080"
TIMEOUT = 5.0
# Probe trace shape only: "METHOD path HTTP/x". This is not the Kalari
# page-observation parser (Kalari/Tools/Run.lean pageObservations), which
# validates JSON page/429 events, cursor chains, and retry linkage.
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

        # C4b: header cap — oversize CONNECT and oversize inner fail 400
        # with zero trace growth. Mirrors the empty-close snapshot pattern.
        cap_a = open(trace_a, "rb").read()
        cap_b = open(trace_b, "rb").read()
        s = socket.create_connection(("127.0.0.1", port_a), timeout=TIMEOUT)
        s.settimeout(TIMEOUT)
        s.sendall(f"CONNECT {ALLOW} HTTP/1.1\r\nHost: {ALLOW}\r\n".encode()
                  + b"X-Pad: " + b"A" * 17000 + b"\r\n\r\n")
        st = status_line(recv_until(s, b"\r\n\r\n"))
        s.close()
        o1 = st == "HTTP/1.1 400 Bad Request"
        print(f"RESP oversize-connect: {st}", flush=True)
        time.sleep(1)
        o2 = open(trace_a, "rb").read() == cap_a and open(trace_b, "rb").read() == cap_b
        s, st = connect_tunnel(port_a, "run-a", pw_a, ALLOW)
        o3 = st == "HTTP/1.1 200 Connection Established"
        s.sendall(b"GET /oversize HTTP/1.1\r\nHost: x\r\nX-Pad: " + b"B" * 17000 + b"\r\n\r\n")
        st_in = status_line(recv_until(s, b"\r\n\r\n"))
        s.close()
        o3 = o3 and st_in == "HTTP/1.1 400 Bad Request"
        print(f"RESP oversize-inner: {st_in}", flush=True)
        time.sleep(1)
        o4 = open(trace_a, "rb").read() == cap_a and open(trace_b, "rb").read() == cap_b
        o5 = "/oversize" not in open(trace_a).read() and "/oversize" not in open(trace_b).read()
        note("header-cap", all([o1, o2, o3, o4, o5]),
             "oversize CONNECT/inner 400, zero trace growth")

        # C4c: framing refusals — every case must fail 400 (never 200),
        # forward nothing, and leave both traces byte-identical.
        # Repro A: authenticated CONNECT then POST /incomplete with
        # Transfer-Encoding chunked, close with no chunks.
        # Repro B: authenticated CONNECT then POST /conflicting with two
        # Content-Length headers, close with no body.
        def framing_case(label, inner_bytes, must_absent):
            snap_a = open(trace_a, "rb").read()
            snap_b = open(trace_b, "rb").read()
            s, st = connect_tunnel(port_a, "run-a", pw_a, ALLOW)
            established = st == "HTTP/1.1 200 Connection Established"
            s.sendall(inner_bytes)
            # Half-close like the repros: no body follows.
            try:
                s.shutdown(socket.SHUT_WR)
            except OSError:
                pass
            tail = read_all(s)
            s.close()
            inner_status = status_line(tail) if tail else "<closed-no-bytes>"
            print(f"RESP {label}: {inner_status}", flush=True)
            time.sleep(1)
            no_growth = open(trace_a, "rb").read() == snap_a and open(trace_b, "rb").read() == snap_b
            no_200 = "200 OK" not in (tail.decode("iso-8859-1", errors="replace") if tail else "")
            absent = all(tok not in open(trace_a).read() and tok not in open(trace_b).read() for tok in must_absent)
            ok = established and no_growth and no_200 and absent
            # A clean close means either an explicit 400 or a close with
            # no 200; the broker must never return an inner 200 here.
            if tail:
                ok = ok and inner_status == "HTTP/1.1 400 Bad Request"
            return ok

        f_results = []
        f_results.append(framing_case("repro-a-chunked",
            b"POST /incomplete HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n",
            ["/incomplete"]))
        f_results.append(framing_case("repro-b-conflict",
            b"POST /conflicting HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\n",
            ["/conflicting"]))
        f_results.append(framing_case("framing-identical-dup",
            b"POST /dup-ident HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n",
            ["/dup-ident"]))
        f_results.append(framing_case("framing-te-and-cl",
            b"POST /te-cl HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\nhello",
            ["/te-cl"]))
        f_results.append(framing_case("framing-bad-length",
            b"POST /badlen HTTP/1.1\r\nHost: x\r\nContent-Length: abc\r\n\r\n",
            ["/badlen"]))
        f_results.append(framing_case("framing-over-cap",
            b"POST /overcap HTTP/1.1\r\nHost: x\r\nContent-Length: 999999\r\n\r\n",
            ["/overcap"]))
        f_results.append(framing_case("framing-bad-line",
            b"BADLINE\r\nHost: x\r\n\r\n",
            ["/badline", "BADLINE"]))
        f_results.append(framing_case("framing-bad-header",
            b"GET /badhdr HTTP/1.1\r\nHost x\r\n\r\n",
            ["/badhdr"]))
        note("framing", all(f_results),
             f"{sum(f_results)}/{len(f_results)} refused 400, zero trace growth, no inner 200")

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

        # C4d: total deadline — slow drip stays under per-read but exceeds
        # the total cap. Mirrors the empty-close snapshot pattern: byte-
        # identical traces, explicit 408, no inner 200, no /slowdrip line.
        port_t = free_port()
        spawn("broker-t", [BROKER, "--port", str(port_t), "--user", "run-a",
                            "--pwenv", "KALARI_PROBE_PW_A", "--allow", ALLOW,
                            "--sock", sock_a,
                            "--read-timeout", "10", "--total-timeout", "3"],
              "log-broker-t.txt")
        assert wait_tcp(port_t), "broker-t never listened"
        snap_a = open(trace_a, "rb").read()
        snap_b = open(trace_b, "rb").read()
        s, st = connect_tunnel(port_t, "run-a", pw_a, ALLOW)
        d_established = st == "HTTP/1.1 200 Connection Established"
        print(f"RESP drip-connect: {st}", flush=True)
        try:
            # Five small writes with gaps well under the 10s per-read
            # timeout but totalling past the 3s total cap.
            for chunk in (b"GET /slowdrip HTTP/1.1\r\n",
                          b"Host: x\r\n",
                          b"Connection: close\r\n",
                          b"X-Pad: 1\r\n",
                          b"\r\n"):
                try:
                    s.sendall(chunk)
                except OSError:
                    break
                time.sleep(0.8)
        except OSError:
            pass
        tail = read_all(s)
        try:
            s.close()
        except Exception:
            pass
        d_status = status_line(tail) if tail else "<closed-no-bytes>"
        print(f"RESP drip-inner: {d_status} len={len(tail)}", flush=True)
        time.sleep(1)
        d_growth = open(trace_a, "rb").read() == snap_a and open(trace_b, "rb").read() == snap_b
        d_no200 = "200 OK" not in tail.decode("iso-8859-1", errors="replace")
        d_absent = "/slowdrip" not in open(trace_a).read() and "/slowdrip" not in open(trace_b).read()
        d_explicit = d_status == "HTTP/1.1 408 Request Timeout"
        note("total-deadline", all([d_established, d_explicit, d_growth, d_no200, d_absent]),
             f"established={d_established} explicit-408={d_explicit} no-growth={d_growth} no-200={d_no200}")

        # C4d2: slow CONNECT drip before any 200. Same total-cap shape
        # as C4d but on the CONNECT block: gaps stay well under the 10s
        # per-read timeout, total exceeds the 3s cap. Expects explicit
        # 408 as the CONNECT reply, zero trace growth, no 200 anywhere.
        snap_a = open(trace_a, "rb").read()
        snap_b = open(trace_b, "rb").read()
        auth_a = basic("run-a", pw_a)
        s = socket.create_connection(("127.0.0.1", port_t), timeout=TIMEOUT)
        s.settimeout(TIMEOUT)
        try:
            for chunk in (b"CONNECT ",
                          ALLOW.encode() + b" ",
                          b"HTTP/1.1\r\n",
                          f"Host: {ALLOW}\r\n".encode(),
                          f"Proxy-Authorization: {auth_a}\r\n".encode(),
                          b"\r\n"):
                try:
                    s.sendall(chunk)
                except OSError:
                    break
                time.sleep(0.8)
        except OSError:
            pass
        tail = read_all(s)
        try:
            s.close()
        except Exception:
            pass
        cd_status = status_line(tail) if tail else "<closed-no-bytes>"
        print(f"RESP drip-connect-block: {cd_status} len={len(tail)}", flush=True)
        time.sleep(1)
        cd_growth = open(trace_a, "rb").read() == snap_a and open(trace_b, "rb").read() == snap_b
        cd_txt = tail.decode("iso-8859-1", errors="replace") if tail else ""
        cd_no200 = "200" not in cd_txt
        cd_explicit = cd_status == "HTTP/1.1 408 Request Timeout"
        note("connect-drip", all([cd_explicit, cd_growth, cd_no200]),
             f"explicit-408={cd_explicit} no-growth={cd_growth} no-200={cd_no200}")

        # C4d3: slow POST body drip. CONNECT and inner headers arrive
        # fast, then the body drips past the total cap. Expects explicit
        # 408 as the inner reply, zero trace growth, no inner 200, and
        # no /slowbody line.
        snap_a = open(trace_a, "rb").read()
        snap_b = open(trace_b, "rb").read()
        s, st = connect_tunnel(port_t, "run-a", pw_a, ALLOW)
        b_established = st == "HTTP/1.1 200 Connection Established"
        print(f"RESP body-drip-connect: {st}", flush=True)
        try:
            s.sendall(b"POST /slowbody HTTP/1.1\r\nHost: x\r\nContent-Length: 50\r\nConnection: close\r\n\r\n")
        except OSError:
            b_established = False
        try:
            for i in range(5):
                try:
                    s.sendall(b"0123456789")
                except OSError:
                    break
                time.sleep(0.8)
        except OSError:
            pass
        tail = read_all(s)
        try:
            s.close()
        except Exception:
            pass
        b_status = status_line(tail) if tail else "<closed-no-bytes>"
        print(f"RESP body-drip-inner: {b_status} len={len(tail)}", flush=True)
        time.sleep(1)
        b_growth = open(trace_a, "rb").read() == snap_a and open(trace_b, "rb").read() == snap_b
        b_txt = tail.decode("iso-8859-1", errors="replace") if tail else ""
        b_no200 = "200 OK" not in b_txt
        b_absent = "/slowbody" not in open(trace_a).read() and "/slowbody" not in open(trace_b).read()
        b_explicit = b_status == "HTTP/1.1 408 Request Timeout"
        note("body-drip", all([b_established, b_explicit, b_growth, b_no200, b_absent]),
             f"established={b_established} explicit-408={b_explicit} no-growth={b_growth} no-200={b_no200}")

        # C4e: upstream truncation — oversize, hung, and truncated
        # upstream responses yield explicit 502, never a silent partial.
        # A stub Unix-socket upstream varies behaviour by path; the main
        # obs traces must stay byte-identical (stub is separate), the
        # client must see 502 with no inner 200 and no partial bytes.
        stub_sock = os.path.join(run_dir, "stub.sock")
        stub_srv = socket.socket(socket.AF_UNIX)
        if os.path.exists(stub_sock):
            os.remove(stub_sock)
        stub_srv.bind(stub_sock)
        os.chmod(stub_sock, 0o600)
        stub_srv.listen(20)
        stub_srv.settimeout(0.5)
        stub_stop = threading.Event()

        def stub_handle(conn):
            try:
                conn.settimeout(5)
                data = b""
                try:
                    while b"\r\n\r\n" not in data:
                        ch = conn.recv(4096)
                        if not ch:
                            break
                        data += ch
                        if len(data) > 16384:
                            break
                except (socket.timeout, TimeoutError):
                    pass
                try:
                    txt = data.decode("iso-8859-1", errors="replace")
                    first = txt.split("\r\n")[0] if txt else ""
                    parts = first.split(" ")
                    path = parts[1] if len(parts) > 1 else "/"
                except Exception:
                    path = "/"
                if path == "/huge":
                    big = b"X" * 100000
                    conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: " + str(len(big)).encode() + b"\r\nConnection: close\r\n\r\n" + big)
                elif path == "/hang":
                    try:
                        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\n")
                        time.sleep(6)
                    except Exception:
                        pass
                elif path == "/trunc":
                    try:
                        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\n" + b"Y" * 10)
                    except Exception:
                        pass
                elif path == "/closedelim":
                    try:
                        conn.sendall(b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n" + b"close-ok")
                    except Exception:
                        pass
                elif path == "/closehuge":
                    try:
                        conn.sendall(b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n" + b"X" * 100000)
                    except Exception:
                        pass
                else:
                    body = b"stub-ok"
                    conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: " + str(len(body)).encode() + b"\r\nConnection: close\r\n\r\n" + body)
            except Exception:
                pass
            finally:
                try:
                    conn.close()
                except Exception:
                    pass

        def stub_loop():
            while not stub_stop.is_set():
                try:
                    cc, _ = stub_srv.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break
                threading.Thread(target=stub_handle, args=(cc,), daemon=True).start()

        stub_thread = threading.Thread(target=stub_loop, daemon=True)
        stub_thread.start()
        port_u = free_port()
        spawn("broker-u", [BROKER, "--port", str(port_u), "--user", "run-a",
                            "--pwenv", "KALARI_PROBE_PW_A", "--allow", ALLOW,
                            "--sock", stub_sock,
                            "--read-timeout", "2", "--total-timeout", "5"],
              "log-broker-u.txt")
        assert wait_tcp(port_u), "broker-u never listened"

        def upstream_case(label, path):
            snap_a = open(trace_a, "rb").read()
            snap_b = open(trace_b, "rb").read()
            s, st = connect_tunnel(port_u, "run-a", pw_a, ALLOW)
            established = st == "HTTP/1.1 200 Connection Established"
            try:
                s.sendall(f"GET {path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".encode())
            except OSError:
                pass
            tail = read_all(s)
            try:
                s.close()
            except Exception:
                pass
            inner_status = status_line(tail) if tail else "<closed-no-bytes>"
            print(f"RESP {label}: {inner_status} len={len(tail)}", flush=True)
            time.sleep(0.5)
            no_growth = open(trace_a, "rb").read() == snap_a and open(trace_b, "rb").read() == snap_b
            txt = tail.decode("iso-8859-1", errors="replace") if tail else ""
            no_200 = "200 OK" not in txt
            explicit = inner_status == "HTTP/1.1 502 Bad Gateway"
            # Partial bytes from the stub must never leak: huge sends
            # 100k Xs, trunc sends Ys, hang sends an incomplete header.
            leak = False
            if path == "/huge" and b"X" * 100 in tail:
                leak = True
            if path == "/trunc" and b"Y" * 4 in tail:
                leak = True
            if len(tail) > 4096:
                leak = True
            ok = established and explicit and no_growth and no_200 and (not leak)
            return ok

        u_results = []
        u_results.append(upstream_case("upstream-oversize", "/huge"))
        u_results.append(upstream_case("upstream-hang", "/hang"))
        u_results.append(upstream_case("upstream-truncated", "/trunc"))
        note("upstream-truncation", all(u_results),
             f"{sum(u_results)}/{len(u_results)} explicit 502, no partial, no inner 200")

        # C4e2: close-delimited upstream (no Content-Length, read until
        # close). Success forwards complete with exact bytes; oversize
        # close-delimited fails explicit 502 with no partial leak. Main
        # obs traces stay byte-identical in both (stub is separate).
        # Attribution note: total expiry before upstream contact is 408
        # (pre-contact check); any expiry after handoff, including during
        # the close-delimited read, is 502 by design — never a partial.
        # The leftover send/handoff micro-window is a known tiny window
        # that also reports 502 with no observation and no partial.
        def closedelim_case(label, path, expect_200):
            snap_a = open(trace_a, "rb").read()
            snap_b = open(trace_b, "rb").read()
            s, st = connect_tunnel(port_u, "run-a", pw_a, ALLOW)
            established = st == "HTTP/1.1 200 Connection Established"
            try:
                s.sendall(f"GET {path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".encode())
            except OSError:
                pass
            tail = read_all(s)
            try:
                s.close()
            except Exception:
                pass
            inner_status = status_line(tail) if tail else "<closed-no-bytes>"
            print(f"RESP {label}: {inner_status} len={len(tail)}", flush=True)
            time.sleep(0.5)
            no_growth = open(trace_a, "rb").read() == snap_a and open(trace_b, "rb").read() == snap_b
            txt = tail.decode("iso-8859-1", errors="replace") if tail else ""
            if expect_200:
                ok_body = tail.endswith(b"close-ok") and b"X" * 100 not in tail
                ok = established and inner_status == "HTTP/1.1 200 OK" and ok_body and no_growth
                ok = ok and "502" not in txt and len(tail) <= 4096
                return ok
            leak = (b"X" * 100 in tail) or len(tail) > 4096
            ok = established and inner_status == "HTTP/1.1 502 Bad Gateway" and no_growth and (not leak)
            ok = ok and "200 OK" not in txt
            return ok

        cd_ok = closedelim_case("upstream-close-delimited", "/closedelim", True)
        ch_ok = closedelim_case("upstream-close-oversize", "/closehuge", False)
        note("upstream-close-delimited", cd_ok and ch_ok,
             f"complete-forwarded={cd_ok} oversize-502-no-partial={ch_ok}")

        # C6: broker-death — kill broker A while observer A runs.
        # This is a broker-only kill. True owner SIGKILL ownership is
        # covered separately by probe/owner_death.py.
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
        note("broker-death", dead and refused and same and mode_a == 0o600 and alive,
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
                   "log-broker-b.txt", "log-broker-t.txt", "log-broker-u.txt",
                   "log-origin.txt", "log-proxy.txt"):
            fp = os.path.join(run_dir, fn)
            if os.path.exists(fp):
                logs += open(fp).read()
        noleak = not any(secret in logs for secret in secrets_set)
        noleak = noleak and "Basic " not in logs.replace("[REDACTED]", "XX") and pw_a not in logs
        oka, da = check_trace_file(trace_a)
        okb, db = check_trace_file(trace_b)
        print(f"TRACE trace-a: {da} lines={trace_lines(trace_a)}", flush=True)
        print(f"TRACE trace-b: {db} lines={trace_lines(trace_b)}", flush=True)
        note("no-password-in-logs", noleak, "8 logs scanned")
        note("trace-parser", oka and okb, f"a: {da}; b: {db}")
    finally:
        # Cleanup: stop the stub upstream, reap every child, then remove
        # the run dir unless kept.
        try:
            stub_stop.set()
        except Exception:
            pass
        try:
            stub_srv.close()
        except Exception:
            pass
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
