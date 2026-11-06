#!/usr/bin/env python3
"""Guest probe: CONNECT through the host broker, then one GET.

Reads the Proxy-Authorization value from stdin (one line, may be empty for
missing-auth). Never prints it, never stores it. Args carry only the
broker host/port, the CONNECT destination, and the inner path — no
credentials. Prints only status lines and byte lengths.
"""
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
dest = sys.argv[3]
path = sys.argv[4]

try:
    auth = sys.stdin.readline().strip()
except Exception:
    auth = ""

s = socket.create_connection((host, port), timeout=8)
s.settimeout(8)
req = f"CONNECT {dest} HTTP/1.1\r\nHost: {dest}\r\n"
if auth:
    req += f"Proxy-Authorization: {auth}\r\n"
req += "\r\n"
s.sendall(req.encode())
data = b""
try:
    while b"\r\n\r\n" not in data:
        ch = s.recv(4096)
        if not ch:
            break
        data += ch
        if len(data) > 65536:
            break
except Exception:
    pass
first = data.split(b"\r\n")[0].decode("iso-8859-1", errors="replace") if data else ""
print(f"CONNECT {first}", flush=True)
if "200 Connection Established" not in first:
    try:
        s.close()
    except Exception:
        pass
    print("INNER none", flush=True)
    sys.exit(0)
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
