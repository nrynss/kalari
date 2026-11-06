#!/usr/bin/env python3
"""Owner process for one broker+observer pair.

The owner starts the observer and the broker as its own children and then
waits. Each child is created with PR_SET_PDEATHSIG=SIGTERM (via preexec),
so the kernel delivers SIGTERM to the child if this owner dies for any
reason, including SIGKILL. That is the explicit ownership link: no
finally-block in a controller and no process-group kill is what reaps the
children; the kernel does it when the parent goes away.

Args (all explicit, no defaults that could collide):
  --broker PATH  observer and broker scripts live in probe/
  --obs PATH
  --port INT     host loopback TCP port for this broker
  --user NAME    broker user
  --pwenv NAME   host env var holding the password (value never printed)
  --allow DEST   CONNECT destination the broker permits
  --sock PATH    private Unix socket path for this run
  --trace PATH   private trace file for this run
  --ready PATH   file the owner creates once both children accept
  --pids PATH    file the owner writes with {"broker": pid, "obs": pid}
  --logdir DIR   directory for child stdout logs (private per-run dir)

The socket and trace live in a private per-run directory (mode 700)
created by the controller. This process never prints the password or the
Basic value.
"""
import argparse
import ctypes
import os
import signal
import socket
import subprocess
import sys
import time

PR_SET_PDEATHSIG = 1


def _die_with_parent():
    # Runs in the forked child before exec. Ask the kernel to send
    # SIGTERM to this child when its parent (the owner) dies, even on
    # owner SIGKILL. Keeps no reference to any secret.
    try:
        libc = ctypes.CDLL("libc.so.6", use_errno=True)
        libc.prctl(PR_SET_PDEATHSIG, signal.SIGTERM)
    except Exception:
        # If prctl is unavailable the ownership link is unproven; fail
        # loudly instead of running without it.
        os._exit(42)


def _wait_tcp(port, timeout=10.0):
    end = time.time() + timeout
    while time.time() < end:
        try:
            s = socket.create_connection(("127.0.0.1", port), timeout=1)
            s.close()
            return True
        except OSError:
            time.sleep(0.1)
    return False


def _wait_unix(path, timeout=10.0):
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--broker", required=True)
    ap.add_argument("--obs", required=True)
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--user", required=True)
    ap.add_argument("--pwenv", required=True)
    ap.add_argument("--allow", required=True)
    ap.add_argument("--sock", required=True)
    ap.add_argument("--trace", required=True)
    ap.add_argument("--ready", required=True)
    ap.add_argument("--pids", required=True)
    ap.add_argument("--logdir", required=True)
    a = ap.parse_args()

    for f in (a.sock,):
        # The observer recreates its socket; remove only our own path.
        try:
            if os.path.exists(f):
                os.remove(f)
        except OSError:
            pass
    # Trace starts empty for this run.
    open(a.trace, "w").close()
    os.makedirs(a.logdir, exist_ok=True)
    obs_log = open(os.path.join(a.logdir, "log-obs.txt"), "w")
    broker_log = open(os.path.join(a.logdir, "log-broker.txt"), "w")

    obs = subprocess.Popen(
        [sys.executable, a.obs, "--sock", a.sock, "--trace", a.trace],
        stdout=obs_log, stderr=subprocess.STDOUT, preexec_fn=_die_with_parent)
    broker = subprocess.Popen(
        [sys.executable, a.broker, "--port", str(a.port), "--user", a.user,
         "--pwenv", a.pwenv, "--allow", a.allow, "--sock", a.sock],
        stdout=broker_log, stderr=subprocess.STDOUT, preexec_fn=_die_with_parent)
    try:
        with open(a.pids, "w") as f:
            f.write(f"broker={broker.pid} obs={obs.pid}\n")
        ok = _wait_unix(a.sock) and _wait_tcp(a.port)
        if not ok:
            # Startup failed: reap only our own children, then exit nonzero.
            for p in (broker, obs):
                try:
                    if p.poll() is None:
                        p.terminate()
                except Exception:
                    pass
            for p in (broker, obs):
                try:
                    p.wait(timeout=5)
                except Exception:
                    pass
            return 2
        # Signal readiness after both listeners accept. No secrets here.
        with open(a.ready, "w") as f:
            f.write(f"port={a.port} sock={a.sock}\n")
        # Wait as the owner: exit when either child exits. A controller
        # SIGKILL of this process must still terminate the children via
        # the kernel PDEATHSIG link, which this wait does not provide.
        while True:
            rc_b = broker.poll()
            rc_o = obs.poll()
            if rc_b is not None or rc_o is not None:
                return 0 if (rc_b, rc_o) == (None, None) else 3
            time.sleep(0.2)
    finally:
        # Normal (non-SIGKILL) termination path only. SIGKILL never runs
        # this: the children still die via PDEATHSIG, which is what the
        # owner_death test proves.
        for p in (broker, obs):
            try:
                if p.poll() is None:
                    p.terminate()
            except Exception:
                pass


if __name__ == "__main__":
    sys.exit(main())
