#!/usr/bin/env python3
"""Kalari evidence API for the Vultr demo deployment.

Serves the read-only routes of Kalari/Http.lean over the shared evidence
store, on loopback only, for Caddy to reverse-proxy at /api. It serves no
static files and never writes to the store.

    python3 kalari-api.py --store /var/lib/kalari/evidence/.kalari/evidence.jsonl \
        --host 127.0.0.1 --port 18001

GET routes follow Kalari/Http.lean. This deployment shim also accepts HEAD
on those routes and returns the same headers without a response body. GET on /api/sessions, /api/runs,
/api/lessons, /api/benchmark, /api/sessions/<id> and /api/runs/<id> returns
JSON; any nonempty request body is 400; a body over 4096 bytes is 413; a
method other than GET or HEAD, an unknown resource, or an unknown id is 404; a
malformed target or id is 400. Like Evidence.decode, a final line without its
newline is not a committed record and is skipped, as is any line that is not
a JSON object.

Options:
    --store PATH   evidence JSONL file (created empty on first read if absent's
                   directory exists; an absent file answers [] on every route)
    --port N       port to bind (default: 18001)
    --host ADDRESS loopback address (default: 127.0.0.1)
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

MAX_BODY = 4096
ID_RE = re.compile(r"^[A-Za-z0-9._-]+$")


def read_records(store: Path) -> list[dict]:
    """Reload every committed record. Mirrors Evidence.decode: only lines
    terminated by a newline are committed; anything else is skipped."""
    try:
        raw = store.read_bytes()
    except FileNotFoundError:
        return []
    except OSError as error:
        print(f"kalari-api: cannot read {store}: {error}", file=sys.stderr)
        return []
    records: list[dict] = []
    for line_no, line in enumerate(raw.split(b"\n")[:-1], 1):
        if not line.strip():
            continue
        try:
            record = json.loads(line.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            print(f"kalari-api: invalid evidence line {line_no}, skipped", file=sys.stderr)
            continue
        if not isinstance(record, dict):
            print(f"kalari-api: evidence line {line_no} is not an object, skipped", file=sys.stderr)
            continue
        records.append(record)
    return records


def ids(records: list[dict], key: str) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for record in records:
        value = record.get(key)
        if isinstance(value, str) and value and value not in seen:
            seen.add(value)
            result.append(value)
    return result


class Handler(BaseHTTPRequestHandler):
    server_version = "KalariApi/1"
    sys_version = ""

    def log_message(self, fmt: str, *args) -> None:
        print(f"kalari-api: {self.address_string()} {fmt % args}", file=sys.stderr)

    def do_GET(self) -> None:
        self.respond("GET")

    def do_HEAD(self) -> None:
        self.respond("HEAD")

    def do_POST(self) -> None:
        self.respond("POST")

    def do_PUT(self) -> None:
        self.respond("PUT")

    def do_DELETE(self) -> None:
        self.respond("DELETE")

    def respond(self, method: str) -> None:
        target = self.path
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length > MAX_BODY:
            self.send_json(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"error": "body over 4096 bytes"})
            return
        if length:
            self.rfile.read(length)
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "request body is not accepted"})
            return
        if "?" in target or "#" in target or not target.startswith("/"):
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid request target"})
            return
        if method not in ("GET", "HEAD"):
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
            return
        records = read_records(self.server.state_store)  # type: ignore[attr-defined]
        parts = target.split("/")
        if parts == ["", "api", "sessions"]:
            self.send_json(HTTPStatus.OK, ids(records, "session_id"))
            return
        if parts == ["", "api", "runs"]:
            self.send_json(HTTPStatus.OK, ids(records, "run_id"))
            return
        if parts == ["", "api", "lessons"]:
            self.send_json(HTTPStatus.OK, [r for r in records if r.get("kind") == "lesson"])
            return
        if parts == ["", "api", "benchmark"]:
            self.send_json(HTTPStatus.OK, [r for r in records if r.get("kind") == "benchmark"])
            return
        if len(parts) == 4 and parts[1] == "api" and parts[2] in ("sessions", "runs"):
            key = "session_id" if parts[2] == "sessions" else "run_id"
            value = parts[3]
            if not value or not ID_RE.match(value):
                label = "session" if key == "session_id" else "run"
                self.send_json(HTTPStatus.BAD_REQUEST, {"error": f"invalid {label} id"})
                return
            found = [r for r in records if r.get(key) == value]
            if not found:
                self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
                return
            self.send_json(HTTPStatus.OK, found)
            return
        self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})

    def send_json(self, status: HTTPStatus, value) -> None:
        body = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--store", type=Path, required=True)
    parser.add_argument("--port", type=int, default=18001)
    parser.add_argument("--host", default="127.0.0.1")
    args = parser.parse_args()
    if args.host not in ("127.0.0.1", "::1", "localhost"):
        parser.error("the evidence API binds loopback only")
    server = Server((args.host, args.port), Handler)
    server.state_store = args.store.resolve()  # type: ignore[attr-defined]
    host, port = server.server_address[:2]
    print(f"kalari-api: http://{host}:{port}/ serving {server.state_store}", flush=True)  # type: ignore[attr-defined]
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
