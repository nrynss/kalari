#!/usr/bin/env python3
"""Serve web/site/ and an evidence API from a local fixture store.

    python3 web/fixture/server.py --port 0

The API routes, status codes and JSON array shapes follow Kalari/Http.lean. The
server binds loopback only. It injects a visible fixture banner into every HTML
page it serves, including the rendered snapshots, so a screenshot from this
server cannot pass for a published result. The fixture files live outside the
published static root.

Options:
    --store PATH       evidence JSONL file (default: web/fixture/evidence.jsonl)
    --port N           port, 0 picks a free one (default: 0)
    --host ADDRESS     loopback address (default: 127.0.0.1)
    --no-benchmark     answer GET /api/benchmark with an empty array
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import re
import sys
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlsplit

HERE = Path(__file__).resolve().parent
SITE = HERE.parent / "site"
MAX_BODY = 4096
ID_RE = re.compile(r"^[A-Za-z0-9._-]+$")
HTML_RE = re.compile(r"<html\b", re.IGNORECASE)
BODY_RE = re.compile(r"(<body\b[^>]*>)", re.IGNORECASE)
BANNER = (
    '<div class="fixture-banner" role="note">'
    "<strong>Fixture mode.</strong> This server serves this page from a local evidence "
    "store, not the published API. A screenshot of this page is not a published result."
    "</div>"
)


class FixtureState:
    def __init__(self, store: Path, no_benchmark: bool) -> None:
        self.root = SITE
        self.store = store
        self.no_benchmark = no_benchmark

    def records(self) -> list[dict]:
        if not self.store.exists():
            return []
        records: list[dict] = []
        try:
            text = self.store.read_text(encoding="utf-8")
        except OSError as error:
            print(f"fixture: cannot read {self.store}: {error}", file=sys.stderr)
            return []
        for line_no, line in enumerate(text.splitlines(), 1):
            if not line.strip():
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                print(f"fixture: invalid evidence line {line_no}, skipped", file=sys.stderr)
                continue
            if not isinstance(record, dict):
                print(f"fixture: evidence line {line_no} is not an object, skipped", file=sys.stderr)
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


def by(records: list[dict], key: str, value: str) -> list[dict]:
    return [record for record in records if record.get(key) == value]


def json_bytes(value) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    server_version = "KalariFixture/1"
    sys_version = ""

    @property
    def state(self) -> FixtureState:
        return self.server.state  # type: ignore[attr-defined]

    def log_message(self, fmt: str, *args) -> None:
        print(f"fixture: {self.address_string()} {fmt % args}", file=sys.stderr)

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
        length_header = self.headers.get("Content-Length")
        try:
            length = int(length_header) if length_header else 0
        except ValueError:
            length = 0
        if length > MAX_BODY:
            self.send_json(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"error": "body over 4096 bytes"})
            return
        if length:
            self.rfile.read(length)
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "request body is not accepted"})
            return
        if target.startswith("/api"):
            self.api(method, target)
        elif method in ("GET", "HEAD"):
            self.static(target, method == "HEAD")
        else:
            self.send_error(HTTPStatus.NOT_FOUND)

    def api(self, method: str, target: str) -> None:
        if "?" in target or "#" in target or not target.startswith("/"):
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid request target"})
            return
        if method != "GET":
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
            return
        path = unquote(urlsplit(target).path)
        parts = path.split("/")
        records = self.state.records()
        if parts == ["", "api", "sessions"]:
            self.send_json(HTTPStatus.OK, ids(records, "session_id"))
            return
        if parts == ["", "api", "runs"]:
            self.send_json(HTTPStatus.OK, ids(records, "run_id"))
            return
        if parts == ["", "api", "lessons"]:
            self.send_json(HTTPStatus.OK, [record for record in records if record.get("kind") == "lesson"])
            return
        if parts == ["", "api", "benchmark"]:
            if self.state.no_benchmark:
                self.send_json(HTTPStatus.OK, [])
            else:
                self.send_json(HTTPStatus.OK, [record for record in records if record.get("kind") == "benchmark"])
            return
        if len(parts) == 4 and parts[1] == "api" and parts[2] in ("sessions", "runs"):
            key = "session_id" if parts[2] == "sessions" else "run_id"
            value = parts[3]
            if not value or not ID_RE.match(value):
                self.send_json(HTTPStatus.BAD_REQUEST, {"error": f"invalid {parts[2][:-1]} id"})
                return
            found = by(records, key, value)
            if not found:
                self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
                return
            self.send_json(HTTPStatus.OK, found)
            return
        self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})

    def static(self, target: str, head_only: bool) -> None:
        path = unquote(urlsplit(target).path)
        rendered = path.startswith("/rendered/")
        if rendered:
            base = HERE / "rendered"
            relative = path[len("/rendered/") :]
        else:
            base = self.state.root
            if path in ("", "/"):
                path = "/index.html"
            if path.endswith("/"):
                path = f"{path}index.html"
            relative = path.lstrip("/")
        candidate = (base / relative).resolve()
        root = base.resolve()
        if root not in candidate.parents and candidate != root:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        if not candidate.is_file():
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        suffix = candidate.suffix.lower()
        content_type = mimetypes.guess_type(candidate.name)[0] or "application/octet-stream"
        if suffix in (".html", ".htm"):
            content_type = "text/html; charset=utf-8"
        elif suffix in (".mjs", ".js"):
            content_type = "text/javascript; charset=utf-8"
        elif suffix == ".css":
            content_type = "text/css; charset=utf-8"
        elif suffix == ".svg":
            content_type = "image/svg+xml"
        elif suffix == ".json":
            content_type = "application/json; charset=utf-8"
        data = candidate.read_bytes()
        if suffix in (".html", ".htm"):
            text = data.decode("utf-8")
            if rendered:
                text = self.rendered_page(text)
            else:
                text = self.with_banner(text)
            data = text.encode("utf-8")
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        if not head_only:
            self.wfile.write(data)

    @staticmethod
    def with_banner(text: str) -> str:
        text = HTML_RE.sub('<html data-fixture="true"', text, count=1)
        if BODY_RE.search(text):
            return BODY_RE.sub(lambda match: match.group(1) + BANNER, text, count=1)
        return BANNER + text

    @staticmethod
    def rendered_page(fragment: str) -> str:
        return (
            '<!doctype html>\n<html lang="en" data-fixture="true">\n'
            '<head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width, initial-scale=1">'
            "<title>Rendered fixture</title>"
            '<link rel="stylesheet" href="/app.css"></head>\n'
            f"<body>{BANNER}<main class=\"app\">{fragment}</main></body>\n</html>\n"
        )

    def send_json(self, status: HTTPStatus, value) -> None:
        body = json_bytes(value)
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(body)


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--store", type=Path, default=HERE / "evidence.jsonl")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--no-benchmark", action="store_true")
    args = parser.parse_args()
    if args.host not in ("127.0.0.1", "::1", "localhost"):
        parser.error("the fixture server binds loopback only")
    if not SITE.is_dir():
        parser.error(f"static root is not a directory: {SITE}")
    store = args.store.resolve()
    server = Server((args.host, args.port), Handler)
    server.state = FixtureState(store, args.no_benchmark)  # type: ignore[attr-defined]
    host, port = server.server_address[:2]
    print(f"http://{host}:{port}/", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
