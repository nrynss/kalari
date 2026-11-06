"""Broker: CONNECT auth, then forward inner HTTP to Unix socket obs.

Transport bounds: every client read has a deadline and both the CONNECT
block and the inner request block are capped at HEADER_CAP bytes. Bytes
already buffered after the CONNECT delimiter are preserved as the start
of the inner request. An empty or incomplete tunnel closes with no
observation and no inner reply: nothing is forwarded, nothing is written,
and no 200 is sent. Oversize blocks are refused with 400, also with no
observation. Framing refusals (Transfer-Encoding present, duplicate or
invalid Content-Length, length above the body cap, malformed request or
header lines, unsupported framing) are refused with 400 before any
forward, also with no observation. Error logs never carry request bytes
or credentials. This is a probe transport, not a general proxy: only one
framed request per tunnel is ever forwarded.
"""
import sys, socket, threading, base64, os, re

READ_TIMEOUT = 10.0
HEADER_CAP = 16384
BODY_CAP = 65536

_METHOD_RE = re.compile(r"^[A-Z]+$")
_VERSION_RE = re.compile(r"^HTTP/\d(\.\d)?$")
_TOKEN_RE = re.compile(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$")

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
    """Strict parse of one header block.

    Returns (request_line, headers, raw_list, malformed). raw_list holds
    (lower_name, stripped_value) in arrival order for framing checks, so
    duplicate Content-Length (even identical) and any Transfer-Encoding
    are visible. malformed is True when the request line or any header
    line does not match the probe trace format.
    """
    try:
        txt = head.decode("iso-8859-1")
    except Exception:
        return None, {}, [], True
    lines = txt.split("\r\n")
    req = lines[0] if lines else ""
    parts = req.split(" ")
    malformed = False
    if len(parts) != 3 or not _METHOD_RE.match(parts[0]) or not parts[1] \
            or " " in parts[1] or not _VERSION_RE.match(parts[2]):
        malformed = True
    hdrs = {}
    raw = []
    for l in lines[1:]:
        if l == "":
            break
        if ":" not in l:
            malformed = True
            continue
        k, v = l.split(":", 1)
        # Field name must be a token with no surrounding whitespace.
        if not k or k != k.strip() or not _TOKEN_RE.match(k.strip()):
            malformed = True
            continue
        name = k.strip().lower()
        val = v.strip(" \t")
        raw.append((name, val))
        # Keep last value for legacy lookup; framing uses raw counts.
        hdrs[name] = val
    # A leading-whitespace line is never valid in this transport.
    for l in lines[1:]:
        if l == "":
            break
        if l[:1] in (" ", "\t"):
            malformed = True
            break
    return req, hdrs, raw, malformed


def framing_error(raw):
    """Return a reason string when framing is unsupported, else None.

    Rejects every Transfer-Encoding header, duplicate Content-Length
    (including identical duplicates), empty or non-digit lengths, comma
    lists, and lengths above BODY_CAP.
    """
    if any(n == "transfer-encoding" for n, _ in raw):
        return "transfer-encoding"
    cls = [v for n, v in raw if n == "content-length"]
    if len(cls) > 1:
        return "duplicate content-length"
    if len(cls) == 1:
        v = cls[0]
        if not v:
            return "empty content-length"
        if "," in v:
            return "content-length list"
        if not v.isdigit():
            return "invalid content-length"
        try:
            n = int(v)
        except Exception:
            return "invalid content-length"
        if n < 0 or n > BODY_CAP:
            return "content-length range"
    return None


def content_length(hdrs, raw):
    err = framing_error(raw)
    if err is not None:
        return -1
    vals = [v for n, v in raw if n == "content-length"]
    if not vals:
        return 0
    # framing_error already validated the single value.
    return int(vals[0])


def refuse(c):
    """Refuse one block with 400 before any observation."""
    try:
        c.sendall(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    except Exception:
        pass


def handle(c):
    try:
        c.settimeout(READ_TIMEOUT)
        got = recv_headers(c)
        if got is None:
            return  # empty/incomplete CONNECT: close, no observation
        if got is False:
            refuse(c)
            return
        head, rest = got
        req, hdrs, raw, malformed = parse_headers(head)
        if malformed or framing_error(raw) is not None:
            refuse(c)
            return
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
            refuse(c)
            return
        inner_head, inner_rest = got
        _, inner_hdrs, inner_raw, inner_malformed = parse_headers(inner_head)
        if inner_malformed or framing_error(inner_raw) is not None:
            refuse(c)
            return
        need = content_length(inner_hdrs, inner_raw)
        if need < 0:
            refuse(c)
            return  # bad framing: close, no observation, no 200
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
