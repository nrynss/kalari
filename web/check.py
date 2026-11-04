#!/usr/bin/env python3
"""Verify the Chaaya pages and the fixture evidence store.

The app is plain ES modules. This check is Python standard library only. It
starts the fixture server on loopback, reads the served pages, and parses the
committed rendered snapshots. The snapshots are produced by the same view code
the browser runs. The manifest pins the view code and the fixture evidence, so
a stale snapshot fails here instead of passing silently.

    ./web/check.sh
"""

from __future__ import annotations

import hashlib
import html
import json
import re
import select
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
WEB = REPO / "web"
FIXTURE = WEB / "fixture"
RENDERED = FIXTURE / "rendered"
MANIFEST = RENDERED / "manifest.json"

NUMBER_RE = re.compile(r"(?<![A-Za-z0-9])[0-9][0-9,.]*(?![A-Za-z0-9])")
IPV4_RE = re.compile(r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])")
URL_RE = re.compile(r"https?://[^\s\"'<>]+", re.IGNORECASE)
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
PROTOCOL_RELATIVE_RE = re.compile(r"(?:href|src)\s*=\s*[\"']//|url\(\s*//", re.IGNORECASE)
SECRET_RES = [
    re.compile(r"(?i)api[_-]?key"),
    re.compile(r"(?i)bearer\s"),
    re.compile(r"BEGIN [A-Z ]*PRIVATE KEY"),
    re.compile(r"ssh-(?:rsa|ed25519)"),
    re.compile(r"(?i)vultr[_-]?inference[_-]?api[_-]?key"),
]


class Failure(Exception):
    pass


def check(condition: bool, message: str) -> None:
    if not condition:
        raise Failure(message)


def say(message: str) -> None:
    print(f"  {message}")


class Server:
    def __init__(self, *args: str) -> None:
        self.args = args
        self.proc: subprocess.Popen[str] | None = None
        self.base = ""

    def __enter__(self) -> "Server":
        self.proc = subprocess.Popen(
            [sys.executable, str(FIXTURE / "server.py"), "--port", "0", *self.args],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        assert self.proc.stdout is not None
        ready, _, _ = select.select([self.proc.stdout], [], [], 5.0)
        line = self.proc.stdout.readline().strip() if ready else ""
        if not line.startswith("http://"):
            self.__exit__(None, None, None)
            raise Failure("the fixture server did not print a loopback address")
        self.base = line
        check(self.base.startswith("http://127.0.0.1:"), f"fixture server is not loopback: {self.base}")
        say(f"fixture server on {self.base}")
        return self

    def __exit__(self, *_exc) -> None:
        if self.proc is None:
            return
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=5)
        self.proc = None


def request(base: str, path: str, method: str = "GET", data: bytes | None = None):
    url = base.rstrip("/") + path
    req = urllib.request.Request(url, method=method, data=data)
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            return response.status, response.read(), response.headers.get_content_type()
    except urllib.error.HTTPError as error:
        return error.code, error.read(), error.headers.get_content_type()


def get_text(base: str, path: str) -> str:
    status, body, content_type = request(base, path)
    check(status == 200, f"GET {path} answered {status}, expected 200")
    check(
        "text" in (content_type or "") or "javascript" in (content_type or ""),
        f"GET {path} has an unexpected content type: {content_type}",
    )
    return body.decode("utf-8")


def get_json(base: str, path: str):
    status, body, content_type = request(base, path)
    check(status == 200, f"GET {path} answered {status}, expected 200")
    check("json" in (content_type or ""), f"GET {path} is not JSON: {content_type}")
    try:
        return json.loads(body)
    except json.JSONDecodeError as error:
        raise Failure(f"GET {path} did not return valid JSON: {error}") from error


def run_id_from_href(href: str) -> str | None:
    parts = urllib.parse.urlsplit(href or "")
    if not parts.path.endswith("run.html"):
        return None
    values = urllib.parse.parse_qs(parts.query).get("id")
    if not values or not values[0]:
        return None
    return values[0]


class JudgesParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.stack: list[tuple[str, dict[str, str]]] = []
        self.numbers: list[tuple[str, str, str | None]] = []
        self.run_links: list[tuple[str | None, str]] = []

    def handle_starttag(self, tag: str, attrs) -> None:
        attributes = {key: value for key, value in attrs}
        self.stack.append((tag, attributes))
        if tag == "a":
            href = attributes.get("href", "")
            classes = set((attributes.get("class") or "").split())
            data_id = attributes.get("data-run-link")
            if "run-link" in classes or data_id or run_id_from_href(href):
                self.run_links.append((run_id_from_href(href) or data_id, href))

    def handle_startendtag(self, tag: str, attrs) -> None:
        self.handle_starttag(tag, attrs)
        self.handle_endtag(tag)

    def handle_endtag(self, tag: str) -> None:
        for index in range(len(self.stack) - 1, -1, -1):
            if self.stack[index][0] == tag:
                del self.stack[index:]
                return

    def handle_data(self, data: str) -> None:
        if any(tag in ("script", "style", "noscript", "template") for tag, _ in self.stack):
            return
        for match in NUMBER_RE.finditer(data):
            anchor = next((attributes for tag, attributes in reversed(self.stack) if tag == "a"), None)
            if anchor is None:
                self.numbers.append((match.group(0), data.strip()[:120], None))
            else:
                self.numbers.append(
                    (match.group(0), data.strip()[:120], run_id_from_href(anchor.get("href", "")))
                )


def text_of(fragment: str) -> str:
    class TextParser(HTMLParser):
        def __init__(self) -> None:
            super().__init__(convert_charrefs=True)
            self.parts: list[str] = []

        def handle_data(self, data: str) -> None:
            if data.strip():
                self.parts.append(data)

    parser = TextParser()
    parser.feed(fragment)
    return " ".join(parser.parts)


def assert_numbers_link_to_runs(judges_html: str, run_ids: set[str], benchmark_run_ids: set[str]) -> None:
    parser = JudgesParser()
    parser.feed(judges_html)
    check(parser.numbers, "the judges page displays no numbers at all")
    for number, context, run_id in parser.numbers:
        check(
            run_id is not None,
            f"the number {number!r} is outside a run link (near {context!r})",
        )
        check(
            run_id in run_ids,
            f"the number {number!r} links to run {run_id!r}, which is not in /api/runs",
        )
    for run_id, href in parser.run_links:
        check(run_id is not None, f"a run link has no id: {href!r}")
        check(run_id in run_ids, f"a run link points to {run_id!r}, which is not in /api/runs")
    linked = {run_id for run_id, _ in parser.run_links}
    missing_benchmark = benchmark_run_ids - linked
    check(
        not missing_benchmark,
        "the judges page does not link every benchmark run. Missing: "
        + ", ".join(sorted(missing_benchmark)),
    )
    missing_runs = run_ids - linked
    check(
        not missing_runs,
        "the judges page does not link every run. Missing: " + ", ".join(sorted(missing_runs)),
    )
    say(f"{len(parser.numbers)} displayed numbers, all inside run links")
    say(f"{len(linked)} distinct runs linked. Every run in the store is present")


class OpinionParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.stack: list[tuple[str, dict[str, str]]] = []
        self.probabilities: list[tuple[str, str]] = []
        self.opinion_blocks = 0

    def handle_starttag(self, tag: str, attrs) -> None:
        attributes = {key: value for key, value in attrs}
        self.stack.append((tag, attributes))
        if "data-opinion" in attributes:
            self.opinion_blocks += 1
        if "data-probability" in attributes:
            labels = [
                ancestor.get("data-opinion-label", "")
                for _, ancestor in self.stack
                if "data-opinion-label" in ancestor
            ]
            self.probabilities.append((attributes.get("data-probability", ""), " | ".join(labels)))

    def handle_endtag(self, tag: str) -> None:
        for index in range(len(self.stack) - 1, -1, -1):
            if self.stack[index][0] == tag:
                del self.stack[index:]
                return


def assert_clef_labels(session_html: str) -> None:
    parser = OpinionParser()
    parser.feed(session_html)
    check(parser.probabilities, "the page shows no Clef probabilities")
    check(parser.opinion_blocks > 0, "the page has no opinion block")
    for label, ancestor in parser.probabilities:
        check(ancestor, f"probability {label!r} is outside a labelled opinion block")
        check(
            "model's opinion" in ancestor.lower(),
            f"probability {label!r} is not labelled a model's opinion: {ancestor!r}",
        )
    visible = text_of(session_html).lower()
    check("model's opinion" in visible, "the page does not show the model's opinion label")
    check("not a measurement" in visible, "the page does not say the opinion is not a measurement")
    check("not a verdict" in visible, "the page does not say the opinion is not a verdict")
    say(
        f"{len(parser.probabilities)} probabilities inside {parser.opinion_blocks} " +
        ("labelled opinion block" if parser.opinion_blocks == 1 else "labelled opinion blocks")
    )


def assert_no_external_urls(base: str) -> None:
    assets = [
        "/",
        "/session.html",
        "/run.html",
        "/app.css",
        "/favicon.svg",
        "/app/judges.mjs",
        "/app/session.mjs",
        "/app/run.mjs",
        "/app/api.mjs",
        "/app/boot.mjs",
        "/app/views.mjs",
        "/app/format.mjs",
        "/app/labels.mjs",
        "/rendered/judges.html",
        "/rendered/judges-empty.html",
        "/rendered/judges-no-store.html",
        "/rendered/session.html",
        "/rendered/run.html",
        "/rendered/run-illustrative.html",
    ]
    for asset in assets:
        status, body, content_type = request(base, asset)
        check(status == 200, f"GET {asset} answered {status}")
        text = body.decode("utf-8", errors="replace")
        for url in URL_RE.findall(text):
            if url.lower().startswith("http://www.w3.org/"):
                continue
            raise Failure(f"external URL {url!r} in served asset {asset}")
        check(
            not PROTOCOL_RELATIVE_RE.search(text),
            f"protocol-relative URL in served asset {asset}",
        )
    say(f"no external URLs in {len(assets)} served pages and assets")


def assert_manifest() -> None:
    check(MANIFEST.is_file(), "web/fixture/rendered/manifest.json is missing")
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    check(manifest.get("schema") == "kalari.web.rendered.v1", "unexpected rendered manifest schema")
    for name, relative in manifest.get("pages", {}).items():
        check((REPO / relative).is_file(), f"rendered page {name} is missing: {relative}")
    for key, entry in manifest.get("sha256", {}).items():
        path = REPO / entry["path"]
        check(path.is_file(), f"manifest source is missing: {entry['path']}")
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        check(
            digest == entry["sha256"],
            f"{entry['path']} changed since the rendered snapshots were made. "
            "run `node web/fixture/render.mjs`",
        )
    say(f"{len(manifest.get('pages', {}))} rendered page hashes and {len(manifest.get('sha256', {}))} source hashes verified")


def assert_private_data_is_absent() -> None:
    text = (FIXTURE / "evidence.jsonl").read_text(encoding="utf-8")
    check(not IPV4_RE.findall(text), "the fixture evidence store contains an IP address")
    check(not EMAIL_RE.findall(text), "the fixture evidence store contains an email address")
    for pattern in SECRET_RES:
        check(not pattern.search(text), f"the fixture evidence store matches a secret pattern: {pattern.pattern}")
    check("http://" not in text and "https://" not in text, "the fixture evidence store contains a URL")
    say("the fixture evidence store has no IP address, email, key pattern or URL")


def assert_api_contract(base: str) -> None:
    sessions = get_json(base, "/api/sessions")
    runs = get_json(base, "/api/runs")
    lessons = get_json(base, "/api/lessons")
    benchmark = get_json(base, "/api/benchmark")
    check(isinstance(sessions, list) and all(isinstance(item, str) for item in sessions), "/api/sessions is not a string array")
    check(isinstance(runs, list) and all(isinstance(item, str) for item in runs), "/api/runs is not a string array")
    check(isinstance(lessons, list), "/api/lessons is not an array")
    check(isinstance(benchmark, list), "/api/benchmark is not an array")
    check(sessions and runs and lessons and benchmark, "the fixture store is unexpectedly empty")
    for record in lessons + benchmark:
        check(isinstance(record, dict), "an evidence record is not an object")
        for key in ("kind", "session_id", "run_id", "change_kinds", "payload"):
            check(key in record, f"an evidence record is missing {key}")
        check(isinstance(record["change_kinds"], list), "change_kinds is not an array")
    for record in benchmark:
        payload = record["payload"]
        check(isinstance(payload, dict), "a benchmark payload is not an object")
        check(payload.get("schema") == "kalari.benchmark.v1", "a benchmark payload has the wrong schema")
        check(record["run_id"] in runs, f"benchmark run {record['run_id']} is not in /api/runs")
    session_records = get_json(base, "/api/sessions/payouts-upgrade")
    check(isinstance(session_records, list) and session_records, "the walkthrough session has no records")
    check(any(record.get("kind") == "session" for record in session_records), "the walkthrough session has no metadata record")
    run_records = get_json(base, "/api/runs/pilot-c3-payouts-r5")
    check(isinstance(run_records, list) and run_records, "the capped run has no records")
    check(any(record.get("kind") == "benchmark" for record in run_records), "the capped run has no benchmark record")

    status, _, _ = request(base, "/api/runs/does-not-exist")
    check(status == 404, f"a missing run answered {status}, expected 404")
    status, _, _ = request(base, "/api/sessions/")
    check(status == 400, f"an empty session id answered {status}, expected 400")
    status, _, _ = request(base, "/api/runs", method="POST")
    check(status == 404, f"POST /api/runs answered {status}, expected 404")
    status, _, _ = request(base, "/api/runs", method="POST", data=b"x" * 4096)
    check(status == 400, f"a 4096-byte body answered {status}, expected 400")
    status, _, _ = request(base, "/api/runs", method="POST", data=b"x" * 4097)
    check(status == 413, f"a 4097-byte body answered {status}, expected 413")
    say(
        f"{len(benchmark)} benchmark records, {len(sessions)} sessions, {len(runs)} runs. "
        "The 400, 404 and 413 responses match the API."
    )


def assert_live_entry_points(base: str) -> None:
    judges = get_text(base, "/")
    session = get_text(base, "/session.html?id=payouts-upgrade")
    run = get_text(base, "/run.html?id=pilot-c3-payouts-r5")
    check('src="app/judges.mjs"' in judges, "the judges page does not load app/judges.mjs")
    check('src="app/session.mjs"' in session, "the session page does not load app/session.mjs")
    check('src="app/run.mjs"' in run, "the run page does not load app/run.mjs")
    check("fixture-banner" in judges, "the live shell has no fixture banner")
    check("fixture-banner" in session and "fixture-banner" in run, "a live shell has no fixture banner")
    check('data-fixture="true"' in judges, "the fixture server did not mark the page as fixture mode")

    api = get_text(base, "/app/api.mjs")
    for route in ("api/benchmark", "api/runs", "api/sessions/", "api/lessons"):
        check(route in api, f"the app API module does not fetch {route}")
    check("URLSearchParams" in get_text(base, "/app/session.mjs"), "the session entry does not read the id query")
    check("URLSearchParams" in get_text(base, "/app/run.mjs"), "the run entry does not read the id query")
    views = get_text(base, "/app/views.mjs")
    check("not yet published" in views, "the live view has no not-yet-published state")
    check("data-opinion-label" in views, "the live view has no Clef opinion label")
    say("the live shells, entry modules and API routes are present")


def assert_not_published(base_no_benchmark: str) -> None:
    benchmark = get_json(base_no_benchmark, "/api/benchmark")
    check(benchmark == [], "/api/benchmark is not empty on the no-benchmark server")
    page = get_text(base_no_benchmark, "/rendered/judges-empty.html")
    text = text_of(page).lower()
    check("not yet published" in text, "the empty benchmark state does not say not yet published")
    check("benchmark" in text, "the empty benchmark state does not explain what is missing")
    check("every figure will link to the run" in text, "the empty state does not explain what will appear")
    say("an empty /api/benchmark renders the not-yet-published state")


def assert_absent_store(base_empty: str) -> None:
    for route in ("/api/sessions", "/api/runs", "/api/lessons", "/api/benchmark"):
        value = get_json(base_empty, route)
        check(value == [], f"{route} on an absent store answered {value!r}, expected []")
    page = get_text(base_empty, "/rendered/judges-no-store.html")
    text = text_of(page).lower()
    check("not yet published" in text, "the absent-store page has no empty state")
    check("not in the current evidence store" in text, "the absent-store page claims a session it does not have")
    say("an absent store returns empty arrays on every list route")


def main() -> int:
    print("web check")
    assert_manifest()
    assert_private_data_is_absent()
    with Server() as server:
        assert_live_entry_points(server.base)
        assert_api_contract(server.base)
        judges_html = get_text(server.base, "/rendered/judges.html")
        session_html = get_text(server.base, "/rendered/session.html")
        illustrative_run_html = get_text(server.base, "/rendered/run-illustrative.html")
        get_text(server.base, "/rendered/run.html")
        runs = set(get_json(server.base, "/api/runs"))
        benchmark = get_json(server.base, "/api/benchmark")
        benchmark_run_ids = {
            record["run_id"]
            for record in benchmark
            if record.get("kind") == "benchmark" and isinstance(record.get("run_id"), str)
        }
        assert_numbers_link_to_runs(judges_html, runs, benchmark_run_ids)
        assert_clef_labels(session_html)
        assert_clef_labels(illustrative_run_html)
        assert_no_external_urls(server.base)
    with Server("--no-benchmark") as server:
        assert_not_published(server.base)
    with Server("--store", str(FIXTURE / "this-store-does-not-exist.jsonl")) as server:
        assert_absent_store(server.base)
    print("web check passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Failure as error:
        print(f"web check failed: {error}", file=sys.stderr)
        raise SystemExit(1)
