#!/usr/bin/env python3
"""Reproducible two-microVM isolation test with host-only proxy auth.

Two host broker+observer pairs (distinct loopback ports, users, host-env
passwords, Unix sockets, traces) plus two real microVM guests. Each guest
is created with --no-net, explicit destination rules, --pull never, plus
host proxy auth:

  --proxy http://127.0.0.1:<broker-port>
  --http-connect-username <run-user>
  --http-connect-password-env <host-env-var>

The guest makes ordinary API requests with no credential handling: the
guest probe script carries no secret, takes no stdin, and builds no
Proxy-Authorization header. The host runtime builds the authenticated
CONNECT to the broker. By design no credential value ever enters guest
memory. Broker credentials travel to the broker only via --pwenv
host-env references, and to the msb runtime only via
--http-connect-password-env host-env references. Nothing with a
credential value reaches guest config, guest args, guest env, guest
output, copied files, host logs, or this transcript.

The API destination is a non-loopback TEST-NET-1 address
(192.0.2.1:18080) so the guest dial leaves the guest via the proxy
instead of hitting guest loopback. The broker allowlists exactly that
destination.

Verifies with actual guests:
  A reaches own observer via host-injected auth; B reaches own observer;
  traces stay separate during overlap; host-side B creds/missing/wrong
  auth fail closed on A broker (407); guest wrong dest via proxy fails
  closed with zero growth and no inner 200; host-side direct
  (non-CONNECT) fails closed (405) and never reaches the private Unix
  observer (a guest cannot send non-CONNECT: the host runtime always
  sends CONNECT).

Records sanitized creation args (env names, never values), statuses,
trace counts, and cleanup. Checks that credential values never appear in
guest config, args, env, output, or copied files, and that the guest
probe contains no credential handling by construction.

Exit 0 on pass, 1 on fail or on any isolation breach (stops and reports).
"""
import base64
import os
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
GUEST_PROBE = os.path.join(HERE, "guest_probe.py")
ALLOW = "192.0.2.1:18080"
ALLOW_HOST, ALLOW_PORT = ALLOW.rsplit(":", 1)
WRONG_DEST = "192.0.2.1:19999"
WRONG_HOST, WRONG_PORT = WRONG_DEST.rsplit(":", 1)
IMAGE = "python:3.13-slim"
TIMEOUT = 8.0

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


def trace_bytes(path):
    if not os.path.exists(path):
        return b""
    with open(path, "rb") as f:
        return f.read()


def run_msb(argv, timeout=60, inp=None):
    # umask 022 for every msb invocation; never logs credential values
    # (callers pass only sanitized argv here).
    proc = subprocess.run(
        argv, input=inp, capture_output=True, timeout=timeout)
    return proc


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


def status_line(block):
    txt = block.decode("iso-8859-1", errors="replace")
    return txt.split("\r\n")[0] if txt else ""


def host_connect_status(port, dest, auth_value):
    """Host-side loopback CONNECT to a broker; returns the status line."""
    s = socket.create_connection(("127.0.0.1", port), timeout=TIMEOUT)
    s.settimeout(TIMEOUT)
    req = f"CONNECT {dest} HTTP/1.1\r\nHost: {dest}\r\n"
    if auth_value:
        req += f"Proxy-Authorization: {auth_value}\r\n"
    req += "\r\n"
    s.sendall(req.encode())
    reply = recv_until(s, b"\r\n\r\n")
    s.close()
    return status_line(reply)


def main():
    os.umask(0o022)
    base = tempfile.mkdtemp(prefix="kalari-microvm-")
    os.chmod(base, 0o700)
    run_dir = os.path.join(base, "run")
    os.mkdir(run_dir, 0o700)

    pw_a = secrets.token_hex(16)
    pw_b = secrets.token_hex(16)
    os.environ["KALARI_MICROVM_PW_A"] = pw_a
    os.environ["KALARI_MICROVM_PW_B"] = pw_b
    secrets_set = {pw_a, pw_b}
    basic_a = "Basic " + base64.b64encode(f"run-a:{pw_a}".encode()).decode()
    basic_b = "Basic " + base64.b64encode(f"run-b:{pw_b}".encode()).decode()
    secrets_set |= {basic_a, basic_b}

    def sanitized(argv):
        return [a if a not in secrets_set else "[REDACTED]" for a in argv]

    def assert_clean(text, where):
        for s in secrets_set:
            if s and s in text:
                raise SystemExit(f"credential leaked in {where}")

    port_a = free_port()
    port_b = free_port()
    sock_a = os.path.join(run_dir, "obs-a.sock")
    sock_b = os.path.join(run_dir, "obs-b.sock")
    trace_a = os.path.join(run_dir, "trace-a.log")
    trace_b = os.path.join(run_dir, "trace-b.log")
    for t in (trace_a, trace_b):
        open(t, "w").close()

    # Unique guest names target only this test's resources on cleanup.
    uniq = f"{os.getpid()}-{int(time.time()) % 100000}"
    guest_a = f"kalari-observe-microvm-a-{uniq}"
    guest_b = f"kalari-observe-microvm-b-{uniq}"

    procs = {}
    msb_outputs = []  # every msb stdout/stderr for the leak scan

    def spawn(name, argv, logname):
        log = open(os.path.join(run_dir, logname), "w")
        p = subprocess.Popen([sys.executable, *argv], stdout=log, stderr=subprocess.STDOUT)
        procs[name] = (p, log)
        print(f"ARGS {name}: {sanitized(argv)}", flush=True)
        return p

    guests_created = []

    def cleanup():
        cleaned = []
        # Remove only this test's guests by exact unique name.
        for g in (guest_a, guest_b):
            r = run_msb(["msb", "remove", "-f", g], timeout=60)
            msb_outputs.append((r.stdout or b"").decode("utf-8", "replace"))
            msb_outputs.append((r.stderr or b"").decode("utf-8", "replace"))
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
        for var in ("KALARI_MICROVM_PW_A", "KALARI_MICROVM_PW_B"):
            os.environ.pop(var, None)
        removed = False
        try:
            shutil.rmtree(base, ignore_errors=True)
            removed = not os.path.exists(base)
        except Exception:
            pass
        print(f"CLEANUP {' '.join(cleaned)} dir-removed={removed}".rstrip(), flush=True)

    try:
        # Image prep, separately: pull with retries, then --pull never.
        print("SETUP image pull with retries, creates use --pull never", flush=True)
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
        note("image-pull", True, f"{IMAGE} cached, creates use --pull never")

        spawn("obs-a", [OBS, "--sock", sock_a, "--trace", trace_a], "log-obs-a.txt")
        spawn("obs-b", [OBS, "--sock", sock_b, "--trace", trace_b], "log-obs-b.txt")
        spawn("broker-a", [BROKER, "--port", str(port_a), "--user", "run-a",
                           "--pwenv", "KALARI_MICROVM_PW_A", "--allow", ALLOW,
                           "--sock", sock_a], "log-broker-a.txt")
        spawn("broker-b", [BROKER, "--port", str(port_b), "--user", "run-b",
                           "--pwenv", "KALARI_MICROVM_PW_B", "--allow", ALLOW,
                           "--sock", sock_b], "log-broker-b.txt")
        ok = wait_unix(sock_a) and wait_unix(sock_b) and wait_tcp(port_a) and wait_tcp(port_b)
        note("host-ready", ok, f"brokers {port_a} {port_b} observers accept")
        if not ok:
            return 1

        # Create guests: --no-net, destination rules for the API address
        # (correct + wrong port so wrong-dest reaches the proxy and fails
        # at the broker, not at the policy), --pull never, plus host
        # proxy auth. Sanitized args recorded (no credential values: only
        # --pwenv / --http-connect-password-env names ever appear, and
        # those are host-side only).
        for guest, port, user, pwenv in (
                (guest_a, port_a, "run-a", "KALARI_MICROVM_PW_A"),
                (guest_b, port_b, "run-b", "KALARI_MICROVM_PW_B")):
            argv = ["msb", "create", "--name", guest, "--cpus", "1", "--memory", "256M",
                    "--no-net",
                    "--net-rule", f"allow@{ALLOW_HOST}/32:tcp:{ALLOW_PORT}",
                    "--net-rule", f"allow@{WRONG_HOST}/32:tcp:{WRONG_PORT}",
                    "--pull", "never",
                    "--proxy", f"http://127.0.0.1:{port}",
                    "--http-connect-username", user,
                    "--http-connect-password-env", pwenv,
                    IMAGE]
            print(f"ARGS create-{guest}: {argv}", flush=True)
            assert "--no-net" in argv and "--pull" in argv and "never" in argv
            assert "--proxy" in argv and "--http-connect-username" in argv
            assert "--http-connect-password-env" in argv
            # The create argv must never carry a credential value.
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
        note("guest-create", True, f"{guest_a} {guest_b} --no-net + proxy host-auth --pull never")
        print(f"STATUS guests created: {guests_created}", flush=True)

        # Overcommit for the Lean runtime pattern (harmless for python guests,
        # keeps the existing pattern exercised).
        for guest in guests_created:
            r = run_msb(["msb", "exec", guest, "--", "sh", "-c",
                         "echo 1 > /proc/sys/vm/overcommit_memory"], timeout=30)
            msb_outputs.append((r.stdout or b"").decode("utf-8", "replace"))

        # Copy the credential-free probe into each guest. The probe takes
        # no stdin and builds no Proxy-Authorization header.
        for guest in guests_created:
            argv = ["msb", "copy", "-q", GUEST_PROBE, f"{guest}:/tmp/guest_probe.py"]
            print(f"ARGS copy-{guest}: {argv}", flush=True)
            r = run_msb(argv, timeout=60)
            out = (r.stdout or b"").decode("utf-8", "replace") + (r.stderr or b"").decode("utf-8", "replace")
            msb_outputs.append(out)
            if r.returncode != 0:
                note("guest-copy", False, f"{guest} rc={r.returncode}")
                return 1
        note("guest-copy", True, "credential-free probe copied to both guests")

        def guest_exec(guest, dest_host, dest_port, path, timeout=30):
            argv = ["msb", "exec", guest, "--", "python3", "/tmp/guest_probe.py",
                    dest_host, str(dest_port), path]
            r = run_msb(argv, timeout=timeout)
            out = (r.stdout or b"").decode("utf-8", "replace")
            err = (r.stderr or b"").decode("utf-8", "replace")
            msb_outputs.append(out)
            msb_outputs.append(err)
            # Credential values must never reach guest output.
            for s in secrets_set:
                if s and s in out:
                    note("cred-leak", False, f"credential value in output of {guest}")
                    raise SystemExit("credential leaked into guest output")
            return r.returncode, out, err

        # A reaches own observer via host-injected auth; B reaches own.
        rc, out_a, _ = guest_exec(guest_a, ALLOW_HOST, ALLOW_PORT, "/a1")
        print(f"RESP guest-a-valid: rc={rc} {out_a.strip().replace(chr(10), ' | ')}", flush=True)
        time.sleep(1)
        rc, out_b, _ = guest_exec(guest_b, ALLOW_HOST, ALLOW_PORT, "/b1")
        print(f"RESP guest-b-valid: rc={rc} {out_b.strip().replace(chr(10), ' | ')}", flush=True)
        time.sleep(1)
        la = trace_bytes(trace_a)
        lb = trace_bytes(trace_b)
        print(f"TRACE trace-a: {la.count(bytes([10]))} lines={la.decode().splitlines()}", flush=True)
        print(f"TRACE trace-b: {lb.count(bytes([10]))} lines={lb.decode().splitlines()}", flush=True)
        ok_ab = (b"GET /a1 HTTP/1.1\n" in la and b"GET /b1 HTTP/1.1\n" in lb
                 and la.count(b"\n") == 1 and lb.count(b"\n") == 1)
        note("microvm-reach-own", ok_ab, f"trace-a={la.count(bytes([10]))} trace-b={lb.count(bytes([10]))}")
        if not ok_ab:
            print("STOP isolation breach or transport failure", flush=True)
            return 1

        # Overlap: both guests at once; traces stay separate.
        snap_a = trace_bytes(trace_a)
        snap_b = trace_bytes(trace_b)
        holder = {}

        def run_a():
            holder["a"] = guest_exec(guest_a, ALLOW_HOST, ALLOW_PORT, "/a2")

        def run_b():
            holder["b"] = guest_exec(guest_b, ALLOW_HOST, ALLOW_PORT, "/b2")

        ta = threading.Thread(target=run_a)
        tb = threading.Thread(target=run_b)
        ta.start()
        tb.start()
        ta.join(timeout=60)
        tb.join(timeout=60)
        print(f"RESP overlap-a: {holder['a'][1].strip().replace(chr(10), ' | ')}", flush=True)
        print(f"RESP overlap-b: {holder['b'][1].strip().replace(chr(10), ' | ')}", flush=True)
        time.sleep(1)
        la = trace_bytes(trace_a)
        lb = trace_bytes(trace_b)
        overlap_ok = (la == snap_a + b"GET /a2 HTTP/1.1\n" and lb == snap_b + b"GET /b2 HTTP/1.1\n")
        note("microvm-overlap", overlap_ok, f"trace-a={la.count(bytes([10]))} trace-b={lb.count(bytes([10]))}")
        if not overlap_ok:
            print("STOP traces not separate during overlap", flush=True)
            return 1

        # Fail-closed auth: host-side loopback CONNECTs with B creds on A,
        # missing auth, and wrong auth. The guest path cannot present wrong
        # auth by design (the host injects it), so these prove the broker
        # still refuses. Each must add no trace and no inner 200.
        def expect_host_closed(label, broker_port, dest, auth_value):
            before_a = trace_bytes(trace_a)
            before_b = trace_bytes(trace_b)
            st = host_connect_status(broker_port, dest, auth_value)
            print(f"RESP {label}: {st}", flush=True)
            time.sleep(1)
            after_a = trace_bytes(trace_a)
            after_b = trace_bytes(trace_b)
            return ("200 Connection Established" not in st
                    and after_a == before_a and after_b == before_b)

        # Fail-closed wrong dest via the real guest path: the guest dials
        # the wrong port with ordinary GET; the host builds CONNECT with
        # the guest's correct auth and the broker refuses.
        def expect_guest_closed(label, guest, dest_host, dest_port, path):
            before_a = trace_bytes(trace_a)
            before_b = trace_bytes(trace_b)
            rc, out, _ = guest_exec(guest, dest_host, dest_port, path)
            print(f"RESP {label}: rc={rc} {out.strip().replace(chr(10), ' | ')}", flush=True)
            time.sleep(1)
            after_a = trace_bytes(trace_a)
            after_b = trace_bytes(trace_b)
            closed = ("INNER HTTP/1.1 200 OK" not in out and after_a == before_a and after_b == before_b)
            return closed

        c1 = expect_host_closed("b-creds-on-a", port_a, ALLOW, basic_b)
        c2 = expect_host_closed("missing-auth", port_a, ALLOW, "")
        c3 = expect_host_closed("wrong-auth", port_a, ALLOW, "Basic d3JvbmdjcmVkZW50aWFscw==")
        c4 = expect_guest_closed("wrong-dest-guest", guest_a, WRONG_HOST, WRONG_PORT, "/x4")
        c5 = expect_host_closed("wrong-dest-host", port_a, "192.0.2.1:19998", basic_a)
        note("microvm-fail-closed", all([c1, c2, c3, c4, c5]), "B-creds/missing/wrong/dest all closed, zero growth")
        if not all([c1, c2, c3, c4, c5]):
            print("STOP fail-closed breach", flush=True)
            return 1

        # Direct (non-CONNECT) from the host fails closed with 405 and never
        # reaches the private Unix observer. A guest cannot send
        # non-CONNECT through the proxy: the host runtime always sends
        # CONNECT first, so this is the host-side proof the broker still
        # refuses it.
        before_a = trace_bytes(trace_a)
        s = socket.create_connection(("127.0.0.1", port_a), timeout=TIMEOUT)
        s.settimeout(TIMEOUT)
        s.sendall(b"GET /direct HTTP/1.0\r\n\r\n")
        tail = recv_until(s, b"\r\n\r\n")
        s.close()
        st = status_line(tail) if tail else "<closed>"
        print(f"RESP direct-no-connect: {st}", flush=True)
        time.sleep(1)
        direct_ok = ("405" in st and trace_bytes(trace_a) == before_a)
        note("microvm-direct-closed", direct_ok, "plain GET 405, zero trace growth")
        if not direct_ok:
            print("STOP direct access reached observer or wrong status", flush=True)
            return 1

        # Credential hygiene: guest config, args, env, output, files, and
        # by-construction checks. The probe must contain no credential
        # handling at all: no proxy-auth header construction, no Basic
        # value, no standard-input reading.
        probe_src = open(GUEST_PROBE).read()
        by_design = ("Proxy-Authorization:" not in probe_src
                     and "Basic " not in probe_src
                     and "sys.stdin" not in probe_src
                     and "base64" not in probe_src)
        note("microvm-by-design", by_design, "guest probe has no credential handling")
        if not by_design:
            print("STOP guest probe carries credential handling", flush=True)
            return 1
        insp_a = run_msb(["msb", "inspect", guest_a, "--format", "json"], timeout=30)
        insp_b = run_msb(["msb", "inspect", guest_b, "--format", "json"], timeout=30)
        insp_text = ((insp_a.stdout or b"") + (insp_a.stderr or b"") + (insp_b.stdout or b"")).decode("utf-8", "replace")
        msb_outputs.append(insp_text)
        # The inspect must reference passwords by env name only.
        env_ref_ok = ("KALARI_MICROVM_PW_A" in insp_text and "KALARI_MICROVM_PW_B" in insp_text)
        r = run_msb(["msb", "exec", guest_a, "--", "env"], timeout=30)
        env_a = (r.stdout or b"").decode("utf-8", "replace")
        msb_outputs.append(env_a)
        r = run_msb(["msb", "exec", guest_a, "--", "cat", "/tmp/guest_probe.py"], timeout=30)
        copied = (r.stdout or b"").decode("utf-8", "replace")
        msb_outputs.append(copied)
        guest_env_clean = ("KALARI_MICROVM_PW_A" not in env_a and "KALARI_MICROVM_PW_B" not in env_a)
        hygiene_text = insp_text + env_a + copied + "".join(msb_outputs)
        leaked = any(s and s in hygiene_text for s in secrets_set)
        # Also scan host broker/observer logs for credential values.
        logs = ""
        for fn in ("log-obs-a.txt", "log-obs-b.txt", "log-broker-a.txt", "log-broker-b.txt"):
            p = os.path.join(run_dir, fn)
            if os.path.exists(p):
                logs += open(p).read()
        leaked = leaked or any(s and s in logs for s in secrets_set) or "Basic " in logs.replace("[REDACTED]", "XX")
        print(f"TRACE final-a: {trace_bytes(trace_a).count(bytes([10]))} final-b: {trace_bytes(trace_b).count(bytes([10]))}", flush=True)
        note("microvm-hygiene", (not leaked) and env_ref_ok and guest_env_clean,
             "no credential value in config/args/env/output/files/logs")
        if leaked or not (env_ref_ok and guest_env_clean):
            print("STOP credential hygiene breach", flush=True)
            return 1

        # Socket/dir modes.
        mode_a = oct(stat.S_IMODE(os.stat(sock_a).st_mode))
        mode_b = oct(stat.S_IMODE(os.stat(sock_b).st_mode))
        dir_mode = oct(stat.S_IMODE(os.stat(run_dir).st_mode))
        note("microvm-modes", (mode_a, mode_b, dir_mode) == ("0o600", "0o600", "0o700"),
             f"sock-a={mode_a} sock-b={mode_b} dir={dir_mode}")
    finally:
        cleanup()

    failed = [n for n, ok, _ in results if not ok]
    print(f"RESULT: {'PASS' if not failed else 'FAIL'} {len(results) - len(failed)}/{len(results)}", flush=True)
    return 0 if not failed else 1


def bchr():
    return bytes([10])


if __name__ == "__main__":
    sys.exit(main())
