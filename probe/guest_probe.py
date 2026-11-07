#!/usr/bin/env python3
"""Guest probe: ordinary API request via host-injected proxy auth.

Carries no credential, reads no secret, builds no proxy auth header.
Args are only the API destination and the inner path -- no credentials.
The host runtime (msb proxy plus username plus password-env) builds the
authenticated CONNECT to the broker; this guest only opens a plain TCP
connection and sends a plain GET. By design no credential value ever
enters guest memory.
"""
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
path = sys.argv[3]

try:
    s = socket.create_connection((host, port), timeout=8)
except Exception:
    print("INNER none len=0", flush=True)
    sys.exit(0)
s.settimeout(8)
s.sendall(f"GET {path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".encode())
resp = b""
try:
    while True:
        ch = s.recv(4096)
        if not ch:
            break
        resp += ch
        if len(resp) > 131072:
            break
except Exception:
    pass
try:
    s.close()
except Exception:
    pass
inner = resp.split(b"\r\n")[0].decode("iso-8859-1", errors="replace") if resp else ""
print(f"INNER {inner} len={len(resp)}", flush=True)
