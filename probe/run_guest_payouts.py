#!/usr/bin/env python3
"""Real guest payouts traversal through the complete host-auth path.

Starts a host-only Unix-socket adapter for the existing payouts handler
(bench/apis/payouts/server.py, unmodified) in a private per-run dir, plus
a host-side broker (auth via host-env reference). Creates one real
microVM guest with host proxy auth:

  --proxy http://127.0.0.1:<broker-port>
  --http-connect-username run-payouts
  --http-connect-password-env <host-env-var>

Runs the correct payouts consumer
(bench/apis/payouts/reference/correct.py, unmodified: limit 1000, follow
cursor, dedupe, retry one 429) inside the guest. The guest makes ordinary
API requests with no credential handling; the host runtime builds the
authenticated CONNECT through the broker to the Unix adapter. The broker
is the only entry; the adapter has no TCP listener and pins its client
identity to loopback. Auth values never leave host env and never appear
in responses, traces, logs, guest config, guest args, guest env, guest
output, copied files, or this transcript.

Validates the resulting host trace with the Kalari page-observation
parser used by production run_in_sandbox
(Kalari/Tools/Run.pageObservations via probe/validate_page_trace.lean),
and shows unauthorized requests (host-side wrong/missing auth, wrong
dest, plus guest wrong-dest via proxy) add no events.

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

HERE = os.path.dirname(os.path.abspath(__file__))
BROKER = os.path.join(HERE, "broker_unix.py")
ADAPTER = os.path.join(HERE, "payouts_unix_adapter.py")
VALIDATOR = os.path.join(HERE, "validate_page_trace.lean")
CORRECT = os.path.join(HERE, "..", "bench", "apis", "payouts", "reference", "correct.py")
CORRECT = os.path.normpath(CORRECT)
ALLOW = "192.0.2.1:18080"
ALLOW_HOST, ALLOW_PORT = ALLOW.rsplit(":", 1)
WRONG_DEST = "192.0.2.1:19999"
WRONG_HOST, WRONG_PORT = WRONG_DEST.rsplit(":", 1)
IMAGE = "python:3.13-slim"
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


def run_msb(argv, timeout=60):
    proc = subprocess.run(argv, capture_output=True, timeout=timeout)
    return proc


def main():
    os.umask(0o022)
    base = tempfile.mkdtemp(prefix="kalari-guest-payouts-")
    os.chmod(base, 0o700)
    run_dir = os.path.join(base, "run")
    os.mkdir(run_dir, 0o700)

    pw = secrets.token_hex(16)
    os.environ["KALARI_GUEST_PAYOUTS_PW"] = pw
    basic = "Basic " + base64.b64encode(f"run-payouts:{pw}".encode()).decode()
    secrets_set = {pw, basic}

    def assert_clean(text, where):
        for s in secrets_set:
            if s and s in text:
                raise SystemExit(f"credential leaked in {where}")

    port = free_port()
    sock = os.path.join(run_dir, "payouts.sock")
    trace = os.path.join(run_dir, "pages.jsonl")

    uniq = f"{os.getpid()}-{int(time.time()) % 100000}"
    guest = f"kalari-guest-payouts-{uniq}"

    procs = {}
    msb_outputs = []

    def spawn(name, argv, logname):
        log = open(os.path.join(run_dir, logname), "w")
        p = subprocess.Popen([sys.executable, *argv], stdout=log, stderr=subprocess.STDOUT)
        procs[name] = (p, log)
        shown = [a if a not in secrets_set else "[REDACTED]" for a in argv]
        print(f"ARGS {name}: {shown}", flush=True)
        return p

    guests_created = []

    def cleanup():
        cleaned = []
        for g in (guest,):
            if g in guests_created:
                r = run_msb(["msb", "remove", "-f", g], timeout=60)
                msb_outputs.append((r.stdout or b"").decode("utf-8", "replace"))
                cleaned.append(f"{g}=removed")
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
        os.environ.pop("KALARI_GUEST_PAYOUTS_PW", None)
        removed = False
        try:
            shutil.rmtree(base, ignore_errors=True)
            removed = not os.path.exists(base)
        except Exception:
            pass
        print(f"CLEANUP {' '.join(cleaned)} dir-removed={removed}".rstrip(), flush=True)

    try:
        # Image prep: pull with retries, creates use --pull never.
        print("SETUP image pull with retries, create uses --pull never", flush=True)
        pulled = False
        for attempt, wait in ((1, 0), (2, 1), (3, 2)):
            if wait:
                time.sleep(wait)
            r = run_msb(["msb", "pull", IMAGE], timeout=120)
            out = (r.stdout or b"").decode("utf-8", "replace") + (r.stderr or b"").decode("utf-8", "replace")
            assert_clean(out, "pull output")
            if r.returncode == 0:
                pulled = True
                print(f"SETUP pull attempt {attempt}: ok", flush=True)
                break
            print(f"SETUP pull attempt {attempt}: rc={r.returncode}", flush=True)
        if not pulled:
            note("image-pull", False, "cached image pull failed after retries")
            return 1
        note("image-pull", True, f"{IMAGE} cached, create uses --pull never")

        spawn("payouts-adapter", [ADAPTER, "--sock", sock, "--trace", trace], "log-adapter.txt")
        spawn("broker", [BROKER, "--port", str(port), "--user", "run-payouts",
                         "--pwenv", "KALARI_GUEST_PAYOUTS_PW", "--allow", ALLOW,
                         "--sock", sock], "log-broker.txt")
        ok = wait_unix(sock) and wait_tcp(port)
        note("guest-payouts-ready", ok, f"broker {port} adapter unix accept")
        if not ok:
            return 1

        # Create the guest with host proxy auth. The guest dials the API
        # address directly; the host builds CONNECT with the run's auth.
        argv = ["msb", "create", "--name", guest, "--cpus", "1", "--memory", "256M",
                "--no-net",
                "--net-rule", f"allow@{ALLOW_HOST}/32:tcp:{ALLOW_PORT}",
                "--net-rule", f"allow@{WRONG_HOST}/32:tcp:{WRONG_PORT}",
                "--pull", "never",
                "--proxy", f"http://127.0.0.1:{port}",
                "--http-connect-username", "run-payouts",
                "--http-connect-password-env", "KALARI_GUEST_PAYOUTS_PW",
                IMAGE]
        print(f"ARGS create-{guest}: {argv}", flush=True)
        for s in secrets_set:
            if s and s in " ".join(argv):
                raise SystemExit("credential value in create argv")
        r = run_msb(argv, timeout=120)
        out = (r.stdout or b"").decode("utf-8", "replace") + (r.stderr or b"").decode("utf-8", "replace")
        msb_outputs.append(out)
        assert_clean(out, "create output")
        if r.returncode != 0:
            note("guest-create", False, f"{guest} rc={r.returncode} {out[-200:]}")
            return 1
        guests_created.append(guest)
        note("guest-create", True, f"{guest} --no-net + proxy host-auth --pull never")

        r = run_msb(["msb", "exec", guest, "--", "sh", "-c",
                     "echo 1 > /proc/sys/vm/overcommit_memory"], timeout=30)
        msb_outputs.append((r.stdout or b"").decode("utf-8", "replace"))

        # The correct consumer is credential-free by inspection.
        correct_src = open(CORRECT).read()
        by_design = ("Proxy-Authorization:" not in correct_src
                     and "Basic " not in correct_src
                     and "sys.stdin" not in correct_src
                     and "password" not in correct_src.lower())
        note("guest-by-design", by_design, "correct consumer has no credential handling")
        if not by_design:
            return 1

        argv = ["msb", "copy", "-q", CORRECT, f"{guest}:/tmp/correct.py"]
        print(f"ARGS copy-{guest}: {argv}", flush=True)
        r = run_msb(argv, timeout=60)
        out = (r.stdout or b"").decode("utf-8", "replace") + (r.stderr or b"").decode("utf-8", "replace")
        msb_outputs.append(out)
        if r.returncode != 0:
            note("guest-copy", False, f"rc={r.returncode}")
            return 1
        note("guest-copy", True, "correct consumer copied to guest")

        # Run the correct traversal inside the guest via host-injected auth.
        argv = ["msb", "exec", guest, "--", "python3", "/tmp/correct.py",
                "--base-url", f"http://{ALLOW}", "--out", "/tmp/out.jsonl"]
        print(f"ARGS exec-correct: {argv}", flush=True)
        r = run_msb(argv, timeout=120)
        out = (r.stdout or b"").decode("utf-8", "replace")
        err = (r.stderr or b"").decode("utf-8", "replace")
        msb_outputs.append(out)
        msb_outputs.append(err)
        for s in secrets_set:
            if s and s in out:
                raise SystemExit("credential leaked into guest output")
        print(f"RESP guest-traversal: rc={r.returncode} {out.strip().splitlines()[-1] if out.strip() else 'none'}", flush=True)
        if r.returncode != 0:
            note("guest-traversal", False, f"rc={r.returncode} {out[-200:]}")
            return 1
        # The guest prints only the synced count, never a cursor or token.
        synced_ok = "synced" in out and "payouts" in out
        note("guest-traversal", synced_ok, out.strip().splitlines()[-1] if out.strip() else "no output")
        if not synced_ok:
            return 1

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
        has_cursor_key = any('"cursor"' in l for l in lines)
        note("guest-trace-shape", len(lines) >= 2 and not has_cursor_key,
             f"{len(lines)} events, raw-cursor-key={has_cursor_key}")

        # Validate with the production Lean parser.
        lake = shutil.which("lake") or "lake"
        env = dict(os.environ)
        env["PATH"] = os.path.expanduser("~/.elan/bin") + ":" + env.get("PATH", "")
        r = subprocess.run([lake, "env", "lean", "--run", VALIDATOR, trace],
                           capture_output=True, text=True, timeout=120, cwd=HERE + "/..",
                           env=env)
        out_p = (r.stdout or "") + (r.stderr or "")
        print(f"RESP parser: {r.stdout.strip().splitlines()[-1] if r.stdout.strip() else 'none'} rc={r.returncode}", flush=True)
        valid = r.returncode == 0 and "VALID" in (r.stdout or "")
        note("guest-parser", valid, "Lean pageObservations accepts the guest trace")
        if not valid:
            print(f"PARSER detail: {out_p[-500:]}", flush=True)
            return 1

        # Unauthorized requests add no events: host-side wrong/missing auth
        # and wrong dest, plus guest wrong-dest via proxy.
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
        s = socket.create_connection(("127.0.0.1", port), timeout=TIMEOUT)
        s.settimeout(TIMEOUT)
        s.sendall(f"CONNECT {WRONG_DEST} HTTP/1.1\r\nHost: x\r\nProxy-Authorization: {basic}\r\n\r\n".encode())
        tail = recv_until(s, b"\r\n\r\n")
        s.close()
        s3 = tail.decode("iso-8859-1", errors="replace").split("\r\n")[0] if tail else "<closed>"
        print(f"RESP unauth-dest-host: {s3}", flush=True)
        # Guest wrong-dest via proxy: ordinary GET to the wrong port.
        wrong_code = (
            "import socket;"
            f"s=socket.create_connection(('{WRONG_HOST}',{WRONG_PORT}),timeout=8);"
            "s.settimeout(8);"
            "s.sendall(b'GET /v2/payouts?limit=1 HTTP/1.1\\r\\nHost: x\\r\\nConnection: close\\r\\n\\r\\n');"
            "d=s.recv(4096);"
            "print('GUEST-WRONG len=%d' % len(d))"
        )
        argv = ["msb", "exec", guest, "--", "python3", "-c", wrong_code]
        r = run_msb(argv, timeout=30)
        gout = (r.stdout or b"").decode("utf-8", "replace") + (r.stderr or b"").decode("utf-8", "replace")
        msb_outputs.append(gout)
        print(f"RESP unauth-dest-guest: {gout.strip().splitlines()[-1] if gout.strip() else 'none'}", flush=True)
        time.sleep(1)
        after = open(trace, "rb").read()
        no_growth = after == before
        no_200 = all("200 OK" not in s for s in (s1, s2, s3))
        note("guest-unauth-closed", no_growth and no_200 and "407" in s1 and "407" in s2 and "403" in s3,
             f"wrong={s1} missing={s2} dest={s3} stable={no_growth}")

        # Logs and hygiene: no credential in guest config, args, env,
        # output, copied files, or host logs. Guest env holds no secret.
        insp = run_msb(["msb", "inspect", guest, "--format", "json"], timeout=30)
        insp_text = ((insp.stdout or b"") + (insp.stderr or b"")).decode("utf-8", "replace")
        msb_outputs.append(insp_text)
        r = run_msb(["msb", "exec", guest, "--", "env"], timeout=30)
        env_g = (r.stdout or b"").decode("utf-8", "replace")
        msb_outputs.append(env_g)
        r = run_msb(["msb", "exec", guest, "--", "cat", "/tmp/correct.py"], timeout=30)
        copied = (r.stdout or b"").decode("utf-8", "replace")
        msb_outputs.append(copied)
        logs = ""
        for fn in ("log-adapter.txt", "log-broker.txt"):
            p = os.path.join(run_dir, fn)
            if os.path.exists(p):
                logs += open(p).read()
        leaked = any(sec and sec in (insp_text + env_g + copied + "".join(msb_outputs)) for sec in secrets_set)
        leaked = leaked or any(sec and sec in logs for sec in secrets_set) or "Basic " in logs
        env_ref_ok = "KALARI_GUEST_PAYOUTS_PW" in insp_text
        env_clean = "KALARI_GUEST_PAYOUTS_PW" not in env_g and pw not in env_g
        mode_sock = oct(stat.S_IMODE(os.stat(sock).st_mode))
        mode_dir = oct(stat.S_IMODE(os.stat(run_dir).st_mode))
        print(f"TRACE modes: sock={mode_sock} dir={mode_dir}", flush=True)
        note("guest-hygiene", (not leaked) and env_ref_ok and env_clean
             and (mode_sock, mode_dir) == ("0o600", "0o700"),
             f"leaked={leaked} sock={mode_sock} dir={mode_dir}")
    finally:
        cleanup()

    failed = [n for n, ok, _ in results if not ok]
    print(f"RESULT: {'PASS' if not failed else 'FAIL'} {len(results) - len(failed)}/{len(results)}", flush=True)
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
