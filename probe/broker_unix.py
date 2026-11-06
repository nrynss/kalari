"""Broker: CONNECT auth, then forward inner HTTP to Unix socket obs.

Transport bounds: every client read has a deadline and both the CONNECT
block and the inner request block are capped at HEADER_CAP bytes. Bytes
already buffered after the CONNECT delimiter are preserved as the start
of the inner request. An empty or incomplete tunnel closes with no
observation and no inner reply: nothing is forwarded, nothing is written,
and no 200 is sent. Oversize blocks are refused with 400, also with no
observation. Error logs never carry request bytes or credentials.
"""
import sys, socket, threading, base64, os

READ_TIMEOUT = 10.0
HEADER_CAP = 16384
BODY_CAP = 65536

port = int(sys.argv[sys.argv.index("--port") + 1])
user = sys.argv[sys.argv.index("--user") + 1]
pwenv = sys.argv[sys.argv.index("--pwenv") + 1]
allowed = sys.argv[sys.argv.index("--allow") + 1]
sock_path = sys.argv[sys.argv.index("--sock") + 1]
pw = os.environ.get(pwenv, "")
if not pw:
    print("missing pw", flush=True)
    sys.exit(2)
exp = "Basic " + base64.b64encode(f"{user}:{pw}".encode()).decode()
del pw
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(20)
print(f"broker-unix listening on {port} -> {sock_path}", flush=True)


def recv_headers(c, initial=b""):
    """Read until end-of-headers. Returns (head, rest), None on
    empty/incomplete/expired tunnel, False on oversize block."""
    data = initial
    if len(data) > HEADER_CAP:
        return False
    try:
        while b"\r\n\r\n" not in data:
            ch = c.recv(4096)
            if not ch:
                return None
            data += ch
            if len(data) > HEADER_CAP:
                return False
    except (socket.timeout, TimeoutError):
        return None
    idx = data.find(b"\r\n\r\n") + 4
    return (data[:idx], data[idx:])


def parse_headers(head):
    try:
        txt = head.decode("iso-8859-1")
    except Exception:
        return None, {}
    lines = txt.split("\r\n")
    req = lines[0] if lines else ""
    hdrs = {}
    for l in lines[1:]:
        if not l:
            break
        if ":" in l:
            k, v = l.split(":", 1)
            hdrs[k.strip().lower()] = v.strip()
    return req, hdrs


def content_length(hdrs):
    raw = hdrs.get("content-length", "")
    if not raw:
        return 0
    if not raw.isdigit():
        return -1
    n = int(raw)
    if n < 0 or n > BODY_CAP:
        return -1
    return n


def handle(c):
    try:
        c.settimeout(READ_TIMEOUT)
        got = recv_headers(c)
        if got is None:
            return  # empty/incomplete CONNECT: close, no observation
        if got is False:
            try:
                c.sendall(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            except Exception:
                pass
            return
        head, rest = got
        req, hdrs = parse_headers(head)
        if not req.startswith("CONNECT "):
            c.sendall(b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        dest = req.split()[1] if len(req.split()) > 1 else ""
        if hdrs.get("proxy-authorization", "") != exp:
            c.sendall(b"HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"probe\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        if dest != allowed:
            c.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        c.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        # Inner request starts with bytes already buffered after CONNECT.
        got = recv_headers(c, initial=rest)
        if got is None:
            return  # empty/incomplete tunnel: close, no observation, no 200
        if got is False:
            try:
                c.sendall(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            except Exception:
                pass
            return
        inner_head, inner_rest = got
        _, inner_hdrs = parse_headers(inner_head)
        need = content_length(inner_hdrs)
        if need < 0:
            return  # bad framing: close, no observation
        body = inner_rest
        try:
            while len(body) < need:
                ch = c.recv(4096)
                if not ch:
                    return  # truncated body: close, no observation
                body += ch
                if len(body) > BODY_CAP:
                    return
        except (socket.timeout, TimeoutError):
            return
        framed = inner_head + body[:need]
        # Forward exactly one framed request to the Unix socket observer.
        u = socket.socket(socket.AF_UNIX)
        try:
            u.settimeout(READ_TIMEOUT)
            u.connect(sock_path)
            u.sendall(framed)
            resp = b""
            while True:
                try:
                    ch = u.recv(4096)
                except (socket.timeout, TimeoutError):
                    break
                if not ch:
                    break
                resp += ch
                if len(resp) > BODY_CAP + HEADER_CAP:
                    break
        finally:
            u.close()
        c.sendall(resp if resp else b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
    except Exception:
        print("broker: transport error", flush=True)
    finally:
        try:
            c.close()
        except Exception:
            pass


while True:
    cc, _ = srv.accept()
    threading.Thread(target=handle, args=(cc,), daemon=True).start()
