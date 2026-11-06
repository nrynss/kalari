#!/usr/bin/env python3
"""Host-only Unix-socket adapter for the existing payouts handler.

Reuses bench/apis/payouts/server.py without modifying it: imports the
module, points its TRACE at a private per-run file, pins trace_client to
loopback (never trusts guest identity headers), and serves the same
Handler over a Unix socket (mode 600) in a private per-run dir. The
broker is the only guest entry; there is no TCP listener here. Auth
headers from the tunnel are never echoed into responses or the trace
(the handler never emits them; this adapter never logs request bytes).

Usage: payouts_unix_adapter.py --sock PATH --trace PATH [--behaviours B1,B2,B4,B5]
"""
import argparse
import importlib.util
import os
import socketserver
import sys


def load_server():
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, "..", "bench", "apis", "payouts", "server.py")
    path = os.path.normpath(path)
    spec = importlib.util.spec_from_file_location("payouts_server", path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["payouts_server"] = mod
    spec.loader.exec_module(mod)
    return mod


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sock", required=True)
    ap.add_argument("--trace", required=True)
    ap.add_argument("--behaviours", default=None,
                    help="comma-separated subset of B1,B2,B4,B5; omit for all")
    a = ap.parse_args()
    server = load_server()
    # Private trace: exclusive create, mode 600 (server.py uses O_EXCL|0o600).
    fd = os.open(a.trace, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    server.TRACE = os.fdopen(fd, "w", encoding="utf-8")
    # Fixed loopback identity. Never derived from guest headers.
    server.Handler.trace_client = "127.0.0.1"
    if a.behaviours is None:
        server.Handler.b1 = server.Handler.b2 = server.Handler.b4 = server.Handler.b5 = True
    else:
        want = {t.strip() for t in a.behaviours.split(",") if t.strip()}
        for tok in want:
            if tok not in ("B1", "B2", "B4", "B5"):
                print(f"unknown behaviour: {tok}", flush=True)
                return 2
        server.Handler.b1 = "B1" in want
        server.Handler.b2 = "B2" in want
        server.Handler.b4 = "B4" in want
        server.Handler.b5 = "B5" in want
    server.Handler.v1_enabled = False

    if os.path.exists(a.sock):
        os.remove(a.sock)

    class UnixHandler(server.Handler):
        def address_string(self):
            # Never trust guest-supplied identity headers; the observer sees
            # the loopback proxy, not a caller claim.
            return "127.0.0.1"

        def setup(self):
            super().setup()
            # AF_UNIX has no peer IP; present the fixed loopback identity so
            # the exclusive-client check passes only for this host path.
            try:
                self.client_address = ("127.0.0.1", 0)
            except Exception:
                pass

        def log_message(self, *args):
            pass

    class UnixServer(socketserver.ThreadingUnixStreamServer):
        daemon_threads = True
        request_queue_size = 20

    # Allow immediate reuse after a test kill.
    UnixServer.allow_reuse_address = True
    with UnixServer(a.sock, UnixHandler) as srv:
        os.chmod(a.sock, 0o600)
        print(f"payouts-unix listening on {a.sock}", flush=True)
        try:
            srv.serve_forever()
        finally:
            try:
                if os.path.exists(a.sock):
                    os.remove(a.sock)
            except Exception:
                pass


if __name__ == "__main__":
    sys.exit(main())
