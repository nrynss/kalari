"""Broker: CONNECT auth, then forward inner HTTP to Unix socket obs.

Transport bounds: every client read has a per-read deadline
(READ_TIMEOUT) and the whole tunnel has a total cap (TOTAL_TIMEOUT)
measured from CONNECT accept to inner complete. Bytes already buffered
after the CONNECT delimiter are preserved as the start of the inner
request. An empty or incomplete tunnel closes with no observation and
no inner reply: nothing is forwarded, nothing is written, and no 200
is sent. Oversize blocks are refused with 400, also with no
observation. Framing refusals (Transfer-Encoding present, duplicate or
invalid Content-Length, length above the body cap, malformed request or
header lines, unsupported framing) are refused with 400 before any
forward, also with no observation. A slow drip that stays under the
per-read timeout but exceeds the total cap fails with an explicit
408 Request Timeout (before CONNECT establishment as the CONNECT
reply, after it as the inner reply), with no observation and no inner
200. Upstream responses are validated as complete before forwarding:
a response that exceeds RESP_CAP, times out, closes early, or is
malformed is never forwarded partially; the client gets an explicit
502 Bad Gateway instead. Total expiry before upstream contact fails
with 408; once the framed request is handed to upstream, any failure
including total expiry during the upstream read fails with 502, never
a partial. A client drip that races body-complete against the
pre-contact deadline check reports 408 (no observation, no forward);
the leftover send/handoff micro-window after that check still reports
502 with no observation and no partial. Error logs never carry request
bytes or credentials. This is a probe transport, not a general proxy:
only one framed request per tunnel is ever forwarded. Loopback only.
"""

import sys, socket, threading, base64, os, re, time

READ_TIMEOUT = 10.0
TOTAL_TIMEOUT = 30.0
HEADER_CAP = 16384
BODY_CAP = 65536
RESP_CAP = BODY_CAP + HEADER_CAP


def _opt_float(name, default):
    if name in sys.argv:
        try:
            return float(sys.argv[sys.argv.index(name) + 1])
        except Exception:
            return default
    return default


READ_TIMEOUT = _opt_float("--read-timeout", READ_TIMEOUT)
TOTAL_TIMEOUT = _opt_float("--total-timeout", TOTAL_TIMEOUT)

_METHOD_RE = re.compile(r"^[A-Z]+$")
_VERSION_RE = re.compile(r"^HTTP/\d(\.\d)?$")
_TOKEN_RE = re.compile(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$")

# Sentinel for total-deadline expiry. Distinct from None (empty/
# incomplete/per-read silent close) and False (oversize 400).
_TOTAL = object()

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


def _remaining(deadline):
    return deadline - time.monotonic()


def recv_headers(c, initial=b"", deadline=None):
    """Read until end-of-headers.

    Returns (head, rest) on success, None on empty/incomplete/per-read
    expiry (silent close), False on oversize block (400), _TOTAL on
    total-deadline expiry (explicit 408).
    """
    data = initial
    if len(data) > HEADER_CAP:
        return False
    if b"\r\n\r\n" in data:
        idx = data.find(b"\r\n\r\n") + 4
        return (data[:idx], data[idx:])
    if deadline is None:
        deadline = time.monotonic() + TOTAL_TIMEOUT
    try:
        while b"\r\n\r\n" not in data:
            rem = _remaining(deadline)
            if rem <= 0:
                return _TOTAL
            try:
                c.settimeout(min(READ_TIMEOUT, rem))
                ch = c.recv(4096)
            except (socket.timeout, TimeoutError):
                if _remaining(deadline) <= 0:
                    return _TOTAL
                return None
            if not ch:
                return None
            data += ch
            if len(data) > HEADER_CAP:
                return False
    except (socket.timeout, TimeoutError):
        if _remaining(deadline) <= 0:
            return _TOTAL
        return None
    idx = data.find(b"\r\n\r\n") + 4
    return (data[:idx], data[idx:])


def recv_body(c, initial, need, deadline):
    """Read exactly need body bytes.

    Returns bytes on success, None on truncated/per-read expiry
    (silent close), False on oversize (silent close, legacy), _TOTAL
    on total-deadline expiry (explicit 408).
    """
    body = initial
    if len(body) >= need:
        return body[:need]
    if len(body) > BODY_CAP:
        return False
    try:
        while len(body) < need:
            rem = _remaining(deadline)
            if rem <= 0:
                return _TOTAL
            try:
                c.settimeout(min(READ_TIMEOUT, rem))
                ch = c.recv(4096)
            except (socket.timeout, TimeoutError):
                if _remaining(deadline) <= 0:
                    return _TOTAL
                return None
            if not ch:
                return None
            body += ch
            if len(body) > BODY_CAP:
                return False
    except (socket.timeout, TimeoutError):
        if _remaining(deadline) <= 0:
            return _TOTAL
        return None
    return body[:need]


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


def parse_response(head):
    """Strict parse of one upstream response header block.

    Validates a status line of the form ``HTTP/x 200 Reason`` and the
    same header field rules as client requests. Returns
    (status_line, headers, raw_list, malformed).
    """
    try:
        txt = head.decode("iso-8859-1")
    except Exception:
        return None, {}, [], True
    lines = txt.split("\r\n")
    status = lines[0] if lines else ""
    parts = status.split(" ", 2)
    malformed = False
    if len(parts) != 3 or not _VERSION_RE.match(parts[0]) \
            or len(parts[1]) != 3 or not parts[1].isdigit() or not parts[2]:
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
        if not k or k != k.strip() or not _TOKEN_RE.match(k.strip()):
            malformed = True
            continue
        name = k.strip().lower()
        val = v.strip(" \t")
        raw.append((name, val))
        hdrs[name] = val
    for l in lines[1:]:
        if l == "":
            break
        if l[:1] in (" ", "\t"):
            malformed = True
            break
    return status, hdrs, raw, malformed


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


def timeout_reply(c):
    """Explicit total-deadline failure: 408, no observation, no inner 200."""
    try:
        c.sendall(b"HTTP/1.1 408 Request Timeout\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    except Exception:
        pass


def upstream_failure(c):
    """Explicit upstream failure: 502, never a silent partial."""
    try:
        c.sendall(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    except Exception:
        pass


def recv_upstream(u, deadline):
    """Read one complete upstream response or return None.

    Never returns a partial: oversize, timeout, early close, malformed
    or bad framing all yield None so the caller sends 502 instead of
    forwarding a silent truncation.
    """
    data = b""
    try:
        while b"\r\n\r\n" not in data:
            rem = _remaining(deadline)
            if rem <= 0:
                return None
            try:
                u.settimeout(min(READ_TIMEOUT, rem))
                ch = u.recv(4096)
            except (socket.timeout, TimeoutError):
                return None
            if not ch:
                return None
            data += ch
            if len(data) > HEADER_CAP:
                return None
        idx = data.find(b"\r\n\r\n") + 4
        head, rest = data[:idx], data[idx:]
        if len(head) > HEADER_CAP:
            return None
        _, hdrs, raw, malformed = parse_response(head)
        if malformed or framing_error(raw) is not None:
            return None
        need = content_length(hdrs, raw)
        if need < 0:
            return None
        if len(head) + need > RESP_CAP:
            return None
        has_cl = any(n == "content-length" for n, _ in raw)
        if has_cl:
            body = rest
            while len(body) < need:
                rem = _remaining(deadline)
                if rem <= 0:
                    return None
                try:
                    u.settimeout(min(READ_TIMEOUT, rem))
                    ch = u.recv(4096)
                except (socket.timeout, TimeoutError):
                    return None
                if not ch:
                    return None
                body += ch
                if len(head) + len(body) > RESP_CAP:
                    return None
            if len(body) < need:
                return None
            return head + body[:need]
        # No Content-Length: read until close within the total cap.
        body = rest
        while True:
            rem = _remaining(deadline)
            if rem <= 0:
                return None
            try:
                u.settimeout(min(READ_TIMEOUT, rem))
                ch = u.recv(4096)
            except (socket.timeout, TimeoutError):
                return None
            if not ch:
                break
            body += ch
            if len(head) + len(body) > RESP_CAP:
                return None
        return head + body
    except (socket.timeout, TimeoutError):
        return None
    except Exception:
        return None


def handle(c):
    start = time.monotonic()
    deadline = start + TOTAL_TIMEOUT
    try:
        got = recv_headers(c, deadline=deadline)
        if got is _TOTAL:
            timeout_reply(c)
            return  # total cap hit before CONNECT: explicit 408, no observation
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
        got = recv_headers(c, initial=rest, deadline=deadline)
        if got is _TOTAL:
            timeout_reply(c)
            return  # slow drip: explicit 408, no observation, no inner 200
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
        body = recv_body(c, inner_rest, need, deadline)
        if body is _TOTAL:
            timeout_reply(c)
            return  # slow body drip: explicit 408, no observation
        if body is None or body is False:
            return  # truncated body / per-read expiry / oversize: close, no observation
        framed = inner_head + body
        # Forward exactly one framed request to the Unix socket observer.
        u = socket.socket(socket.AF_UNIX)
        try:
            rem = _remaining(deadline)
            if rem <= 0:
                # Total expired after a complete body but before any
                # upstream contact: still the client's drip, so 408, not
                # 502. Anything after handoff (send/recv, including total
                # expiry there) is 502 with no partial by design.
                timeout_reply(c)
                return
            u.settimeout(min(READ_TIMEOUT, rem))
            try:
                u.connect(sock_path)
            except Exception:
                upstream_failure(c)
                return
            try:
                u.settimeout(min(READ_TIMEOUT, max(0.001, _remaining(deadline))))
                u.sendall(framed)
            except Exception:
                upstream_failure(c)
                return
            resp = recv_upstream(u, deadline)
        finally:
            try:
                u.close()
            except Exception:
                pass
        if resp is None:
            upstream_failure(c)
            return  # truncated/oversize/timed-out upstream: explicit 502, never partial
        try:
            c.sendall(resp)
        except Exception:
            pass
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
