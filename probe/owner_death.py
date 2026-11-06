#!/usr/bin/env python3
"""True owner-death test with SIGKILL.

Two owner processes each own one broker+observer pair in a private
per-run directory with unique ports, users, env names, sockets, and
traces. The controller kills owner A with SIGKILL while its children run,
then verifies:

  - broker A listener closes (TCP refused),
  - observer A exits and its socket file is removed,
  - the trace stops (byte-identical, no new events),
  - a direct request through broker A fails closed,
  - owner B and its pair keep working (new event lands on trace B only).

The ownership link is explicit: each child is created with
PR_SET_PDEATHSIG=SIGTERM, so the kernel terminates the children when the
owner dies, even on SIGKILL. A broker-only kill would leave the observer
behind and is not accepted here. Controller finally-block cleanup only
reaps the PIDs this test started and only removes the two private dirs;
it is not the ownership proof — the SIGKILL in the middle is.

Sanitized output: creation args show env names (never values), responses
show status lines, traces show counts, cleanup names only test resources.
Passwords live in host env only. Exit 0 on pass, 1 on fail.
"""
import base64
import os
import secrets
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
OWNER = os.path.join(HERE, "owner.py")
BROKER = os.path.join(HERE, "broker_unix.py")
OBS = os.path.join(HERE, "obs_unix.py")
ALLOW = "127.0.0.1:18080"
TIMEOUT = 5.0

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


def wait_path(path, timeout=10.0):
    end = time.time() + timeout
    while time.time() < end:
        if os.path.exists(path):
            return True
        time.sleep(0.1)
    return False


def basic(user, pw):
    return "Basic " + base64.b64encode(f"{user}:{pw}".encode()).decode()


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


def trace_bytes(path):
    if not os.path.exists(path):
        return b""
    with open(path, "rb") as f:
        return f.read()


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, PermissionError):
        return False


def main():
    base = tempfile.mkdtemp(prefix="kalari-owner-death-")
    os.chmod(base, 0o700)
    dir_a = os.path.join(base, "run-a")
    dir_b = os.path.join(base, "run-b")
    os.mkdir(dir_a, 0o700)
    os.mkdir(dir_b, 0o700)

    pw_a = secrets.token_hex(16)
    pw_b = secrets.token_hex(16)
    os.environ["KALARI_OWNER_PW_A"] = pw_a
    os.environ["KALARI_OWNER_PW_B"] = pw_b
    secrets_set = {pw_a, pw_b}

    port_a = free_port()
    port_b = free_port()
    sock_a = os.path.join(dir_a, "obs-a.sock")
    sock_b = os.path.join(dir_b, "obs-b.sock")
    trace_a = os.path.join(dir_a, "trace-a.log")
    trace_b = os.path.join(dir_b, "trace-b.log")
    ready_a = os.path.join(dir_a, "ready")
    ready_b = os.path.join(dir_b, "ready")
    pids_a = os.path.join(dir_a, "child-pids")
    pids_b = os.path.join(dir_b, "child-pids")

    owners = {}  # name -> Popen
    child_pids = {}  # name -> (broker_pid, obs_pid)

    def spawn_owner(name, run_dir, port, user, pwenv, sock, trace, ready, pids_file):
        log = open(os.path.join(run_dir, "log-owner.txt"), "w")
        argv = [sys.executable, OWNER, "--broker", BROKER, "--obs", OBS,
                "--port", str(port), "--user", user, "--pwenv", pwenv,
                "--allow", ALLOW, "--sock", sock, "--trace", trace,
                "--ready", ready, "--pids", pids_file, "--logdir", run_dir]
        # Sanitized: argv holds the env NAME, never the value.
        shown = [a if a not in secrets_set else "[REDACTED]" for a in argv]
        print(f"ARGS {name}: {shown}", flush=True)
        p = subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT)
        owners[name] = (p, log)
        return p

    def cleanup_test_resources():
        # Target only this test's resources: the two owners (children die
        # via PDEATHSIG), then the two private dirs. No patterns, no /tmp
        # sweeps, no pkill.
        cleaned = []
        for name in ("owner-a", "owner-b"):
            entry = owners.get(name)
            if entry is None:
                continue
            p, log = entry
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
        # Orphaned children (if PDEATHSIG ever failed) are reaped by PID.
        for name in ("run-a", "run-b"):
            pids_file = pids_a if name == "run-a" else pids_b
            try:
                if os.path.exists(pids_file):
                    for line in open(pids_file).read().replace("=", " ").split():
                        pass
            except Exception:
                pass
        for pid in list(child_pids.values()):
            for one in pid:
                try:
                    if pid_alive(one):
                        os.kill(one, signal.SIGKILL)
                except Exception:
                    pass
        for var in ("KALARI_OWNER_PW_A", "KALARI_OWNER_PW_B"):
            os.environ.pop(var, None)
        removed = False
        try:
            shutil.rmtree(base, ignore_errors=True)
            removed = not os.path.exists(base)
        except Exception:
            pass
        print(f"CLEANUP {' '.join(cleaned)} dir-removed={removed}".rstrip(), flush=True)
        return removed

    try:
        spawn_owner("owner-a", dir_a, port_a, "owner-a", "KALARI_OWNER_PW_A",
                    sock_a, trace_a, ready_a, pids_a)
        spawn_owner("owner-b", dir_b, port_b, "owner-b", "KALARI_OWNER_PW_B",
                    sock_b, trace_b, ready_b, pids_b)
        ok = wait_path(ready_a) and wait_path(ready_b)
        note("owner-ready", ok, "both owners report broker+observer accept")
        if not ok:
            return 1

        def read_pids(path):
            out = {}
            for tok in open(path).read().replace("\n", " ").split():
                if "=" in tok:
                    k, v = tok.split("=", 1)
                    out[k] = int(v)
            return out.get("broker"), out.get("obs")

        broker_a, obs_a = read_pids(pids_a)
        broker_b, obs_b = read_pids(pids_b)
        child_pids["run-a"] = (broker_a, obs_a)
        child_pids["run-b"] = (broker_b, obs_b)
        print(f"OWNER owner-a: pid={owners['owner-a'][0].pid} broker={broker_a} obs={obs_a} port={port_a}", flush=True)
        print(f"OWNER owner-b: pid={owners['owner-b'][0].pid} broker={broker_b} obs={obs_b} port={port_b}", flush=True)

        # Both pairs serve once.
        def roundtrip(port, user, pw, path):
            s = socket.create_connection(("127.0.0.1", port), timeout=TIMEOUT)
            s.settimeout(TIMEOUT)
            s.sendall(f"CONNECT {ALLOW} HTTP/1.1\r\nHost: {ALLOW}\r\nProxy-Authorization: {basic(user, pw)}\r\n\r\n".encode())
            reply = recv_until(s, b"\r\n\r\n")
            if status_line(reply) != "HTTP/1.1 200 Connection Established":
                s.close()
                return False, ""
            s.sendall(f"GET {path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".encode())
            resp = read_all(s)
            s.close()
            return status_line(resp) == "HTTP/1.1 200 OK", status_line(resp)

        ok_a, st_a = roundtrip(port_a, "owner-a", pw_a, "/a1")
        ok_b, st_b = roundtrip(port_b, "owner-b", pw_b, "/b1")
        print(f"RESP pre-a: {st_a} pre-b: {st_b}", flush=True)
        time.sleep(1)
        la0 = trace_bytes(trace_a)
        lb0 = trace_bytes(trace_b)
        note("owner-both-serve", ok_a and ok_b and la0.count(b"\n") == 1 and lb0.count(b"\n") == 1,
             f"trace-a={la0.count(chr(10).encode())} trace-b={lb0.count(chr(10).encode())}")

        # SIGKILL owner A while its children run. This never runs cleanup.
        owner_a_proc, _ = owners["owner-a"]
        owner_a_pid = owner_a_proc.pid
        assert pid_alive(broker_a) and pid_alive(obs_a), "children must run before SIGKILL"
        os.kill(owner_a_pid, signal.SIGKILL)
        owner_a_proc.wait(timeout=10)
        killed = owner_a_proc.poll() == -signal.SIGKILL
        print(f"OWNER owner-a SIGKILL: reaped={killed} exit={owner_a_proc.poll()}", flush=True)

        # Children must go away via the kernel PDEATHSIG link.
        end = time.time() + 10
        while time.time() < end and (pid_alive(broker_a) or pid_alive(obs_a)):
            time.sleep(0.1)
        broker_gone = not pid_alive(broker_a)
        obs_gone = not pid_alive(obs_a)
        # Broker listener must close.
        try:
            s = socket.create_connection(("127.0.0.1", port_a), timeout=TIMEOUT)
            s.close()
            refused_a = False
        except OSError:
            refused_a = True
        # Socket file must be removed by the exiting observer.
        end = time.time() + 10
        while time.time() < end and os.path.exists(sock_a):
            time.sleep(0.1)
        sock_gone = not os.path.exists(sock_a)
        # Unix socket must refuse.
        try:
            s = socket.socket(socket.AF_UNIX)
            s.settimeout(2)
            s.connect(sock_a)
            s.close()
            unix_refused = False
        except OSError:
            unix_refused = True
        time.sleep(1)
        la1 = trace_bytes(trace_a)
        trace_stopped = la1 == la0
        print(f"RESP owner-a-death: broker-gone={broker_gone} obs-gone={obs_gone} "
              f"tcp-refused={refused_a} unix-refused={unix_refused} sock-removed={sock_gone} "
              f"trace-stable={trace_stopped}", flush=True)
        note("owner-death", killed and broker_gone and obs_gone and refused_a
             and unix_refused and sock_gone and trace_stopped,
             f"owner SIGKILL reaps pair, listener closed, socket removed, trace stable")

        # A direct request through the dead broker fails closed, adds nothing.
        try:
            s = socket.create_connection(("127.0.0.1", port_a), timeout=TIMEOUT)
            s.settimeout(TIMEOUT)
            s.sendall(b"CONNECT 127.0.0.1:18080 HTTP/1.1\r\nHost: x\r\n\r\n")
            tail = recv_until(s, b"\r\n\r\n")
            s.close()
            direct_status = status_line(tail) if tail else "<refused>"
        except OSError:
            direct_status = "<refused>"
        print(f"RESP dead-broker-direct: {direct_status}", flush=True)
        time.sleep(0.5)
        direct_ok = trace_bytes(trace_a) == la0 and direct_status != "HTTP/1.1 200 OK"
        note("owner-dead-closed", direct_ok, f"direct={direct_status} trace-stable={trace_bytes(trace_a) == la0}")

        # Owner B keeps working: new event lands on trace B only.
        ok_b2, st_b2 = roundtrip(port_b, "owner-b", pw_b, "/b2")
        print(f"RESP post-b: {st_b2}", flush=True)
        time.sleep(1)
        lb1 = trace_bytes(trace_b)
        la2 = trace_bytes(trace_a)
        alive = ok_b2 and lb1.count(b"\n") == lb0.count(b"\n") + 1 and la2 == la0
        print(f"TRACE trace-a: {la2.count(chr(10).encode())} trace-b: {lb1.count(chr(10).encode())}", flush=True)
        note("owner-other-keeps-working", alive, "broker-b serves, traces stay separate")

        # Socket/dir modes and log hygiene (sanitized).
        mode_a_dir = oct(stat.S_IMODE(os.stat(dir_a).st_mode))
        logs = ""
        for fn in ("log-obs.txt", "log-broker.txt", "log-owner.txt"):
            for d in (dir_a, dir_b):
                p = os.path.join(d, fn)
                if os.path.exists(p):
                    logs += open(p).read()
        noleak = not any(s in logs for s in secrets_set) and "Basic " not in logs
        print(f"TRACE modes: dir-a={mode_a_dir} sock-b-exists={os.path.exists(sock_b)}", flush=True)
        note("owner-hygiene", noleak, "no password or Basic value in child logs")
    finally:
        cleanup_test_resources()

    failed = [n for n, ok, _ in results if not ok]
    print(f"RESULT: {'PASS' if not failed else 'FAIL'} {len(results) - len(failed)}/{len(results)}", flush=True)
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
